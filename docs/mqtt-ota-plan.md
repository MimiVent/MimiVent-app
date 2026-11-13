# MimiVent MQTT OTA 实施方案

状态：设计稿，尚未实现。范围：沿用当前 `.mvota` / `.mvdelta` 包和设备 OTA 管理逻辑，新增 NAS MQTT 传输入口；首版只在同一家庭 NAS 与设备连接正常时工作。

## 目标与边界

用户在 App 的固件升级页选择“NAS MQTT 升级”后，App 将已检查的 OTA 包交给 NAS Gateway；Gateway 通过经过设备绑定授权的 MQTT OTA 主题传输。设备校验包、签名、目标设备与分区、写入 OTA 分区并回报进度。App 展示进度，校验通过后仍要求用户明确确认安装，重启后核验运行版本与固件身份。

现有 BLE OTA 继续保留，作为 NAS 不可用时的升级方式。首版不做公网/云端升级，也不经 MQTT 控制主题传固件，不让 Gateway 生成或签署固件包。固件包签名私钥只留在发布者构建机。

## 当前可复用部分

- App 已解析并验证 OTA v2 `.mvota` / `.mvdelta` 容器，并维护 taskId、摘要、断点、校验、安装和重启后核验。
- 固件 `OtaManager` 已负责包头、RSA-PSS 签名、SHA-256、4 KiB 包块、断点检查点、解压/差分写入、完整性验证和安装意图。
- BLE 适配层目前以最多 512 字节一块接收数据，控制命令与数据队列分离；OTA Manager 的 `processMessage` 仍直接绑定 BLE 消息/连接所有权与状态通知。
- Gateway 已有绑定授权、MQTT 会话、设备主题路由与 HTTPS App 接口，可扩展同一套 TLS 身份校验和请求限流。

关键改造是把 OTA Manager 的“开始/收数据/查询/暂停/校验/安装/放弃/状态”从 BLE 专属连接句柄中抽成传输无关接口，然后由 BLE Adapter 与 MQTT Adapter 各自调用；OTA 包解析、签名与分区写入不得复制两份。

## 通道设计

为每台设备增加独立主题，均不 retain：

- `mimivent/v1/{deviceId}/ota/control`：START、QUERY、PAUSE、VERIFY、INSTALL、ABANDON。
- `mimivent/v1/{deviceId}/ota/data`：分块二进制数据。
- `mimivent/v1/{deviceId}/ota/status`：设备状态、累计偏移、窗口与错误码。

固件仅在已绑定 MQTT 身份有效、设备未处于 OTA 写入/安装、请求参数合法时接受 START。每个传输 task 绑定 `deviceId + tokenId + taskId + packageSha256`。每个数据块携带 taskId、offset、payloadLength、CRC32 与数据；Gateway 验证 topic 与消息尺寸，固件验证 task、连续偏移、块长、CRC 和总包长。MQTT QoS 1 允许重复投递，因此设备按偏移幂等处理：已确认的完全重复块回复当前偏移；乱序块返回 expectedOffset；冲突内容中止任务。绝不因 QoS 1 推断“只到一次”。

数据采用小窗口、单个有界 in-flight 窗口，首版窗口 1，单块建议 512 字节（沿用 BLE 适配器目前的上限作为保守起点）。收到设备累计偏移确认后才发送下一块。实测 RAM、MQTT outbox 和丢包恢复后再评估增大窗口；不把整份固件装入 RAM。4 KiB 是 `.mvota` 内压缩块大小，不是 MQTT 单条消息大小。

Gateway 提供 OTA 专用 HTTPS API：创建任务并上传包、查询任务状态、暂停/继续、确认安装和放弃。接口使用 App 已有绑定 bearer、证书固定指纹、任务 ID 与包摘要校验；Gateway 将临时包存入配置的数据卷，设置最大包尺寸、磁盘配额、原子写入与任务 TTL。App 不直接连接 Broker，也不把 MQTT 密码写入 OTA 包或日志。Gateway 校验 App 声明的长度与摘要后才启动传输；设备端签名校验仍是最终信任根。

## OTA 期间的连接与状态

现状 `wifiMqttSuspendForOta()` 会销毁 MQTT 客户端，而 `wifiMqttUpdate()` 在 OTA active 时持续退出。需要改成 OTA 状态机：普通控制/统计查询暂停，OTA 专用数据/状态保持连接；OTA 结束、暂停或失败后恢复普通主题处理。OTA MQTT 不得和 BLE OTA 同时拥有写入权，也不得为了 OTA 关闭 BLE 安全校验或签名检查。设备仍周期性报告 ONLINE/OTA_UPLOADING/OTA_PAUSED/OTA_VERIFIED 等明确状态，NAS/App 将上传中断与设备离线区分。

BLE 与 MQTT 的 OTA 所有权由固件唯一仲裁。当前 checkpoint 的 taskId、稳定设备 ID、包摘要、包偏移是断点恢复依据；新增 `transport` 仅用于 UI/诊断，不参与签名身份。另一传输连接时只能查询同一任务或被明确拒绝；不得并行写 Flash。重新连接后必须先 QUERY，比较 taskId、包摘要、版本和设备偏移，再从设备确认的偏移续传。Firmware 过期但包身份相同可续传，包身份变化不能接续旧 checkpoint。

安装仍分两阶段：全包摘要和签名通过后进入 VERIFIED；App 向用户展示目标版本/设备/包摘要并二次确认，才发 INSTALL。安装意图持久化后设备重启。Gateway 记录任务至设备重新上线并回报运行版本、固件 SHA 与目标一致；超时则显示“安装结果待核验”，不自动重发 INSTALL。

## 分阶段实施

1. **P0 协议与资源核算**：冻结 topic、消息 envelope、权限、最大块与窗口、最大包、超时、重试、状态迁移和错误码；检查 ESP32 heap/outbox、MQTT 入站缓冲、NAS 磁盘占用与双 OTA 分区容量。
2. **P1 固件 OTA 核心解耦**：将 OTA Manager 的 BLE 连接句柄依赖改为 transport callbacks/owner abstraction；输入字节仍进入同一 package parser 与 checkpoint。新增 MQTT OTA adapter 和 OTA 专用接收队列；状态机保留 BLE 路径原行为。
3. **P2 设备 MQTT 协议**：实现 START/QUERY/data/ACK/PAUSE/VERIFY/INSTALL/ABANDON，严格校验绑定 token、task、摘要、offset、大小、CRC 和QoS重复。先做 host/native 测试与固件编译，不安装到用户设备。
4. **P3 NAS Gateway**：增加 OTA HTTP API、包暂存卷、逐块发布与窗口、状态订阅、重连续传、过期清理、并发/磁盘上限及审计日志（日志只记录 ID、偏移、状态，不记录包内容或凭据）。部署旧 Gateway 时应保持向后兼容；OTA API 不可用时 App 清楚提示需更新 NAS 服务。
5. **P4 App**：升级页可选择 BLE 或 NAS MQTT；复用文件检查、delta 不匹配回退完整包、任务快照、速度/剩余时间、暂停/继续、安装确认、放弃和重启核验 UI。任务状态持久化使用同一个 taskId 和 package SHA，不因切换传输创建第二个升级任务。NAS MQTT 模式明确显示当前通道。
6. **P5 联调与灰度**：先用测试设备验证小包/完整包/差分包、错误签名、错误设备、断网、NAS 重启、App 后台、重复块、错序块、BLE/MQTT 抢占、暂停续传、安装后启动确认与 rollback；再完整包长时间传输；最后才开放正式固件升级入口。

## 必须通过的验收

- 签名错误、包摘要错误、设备 ID/分区不匹配均在写入或安装前失败，运行分区不改变。
- 传输每个字节最多在 RAM 中保留有界窗口；大包不导致整包内存分配。
- 丢 ACK、QoS 重复、乱序、App 退出、NAS 重启、WiFi 短断后，查询到同一 taskId 与摘要并从 checkpoint 恢复，不跳块、不重复写错位置。
- BLE 与 MQTT 同时发起时只有一个 owner 写 Flash；另一个得到 BUSY/OWNER_CONFLICT，不破坏 checkpoint。
- MQTT 升级期间普通控制和统计有明确忙状态；OTA 状态/确认仍可用。设备断电、Broker 断开与 Gateway 停止的提示可区分。
- 点击安装前不切换 boot partition；安装请求结果未知时不重复提交；重启后按实际运行分区核验 SHA、版本和 taskId。
- NAS 容量不足、临时目录权限错误、上传超限、过期任务、Gateway 更新中断均快速失败并清理未引用临时文件。
- BLE OTA 全套现有验收继续通过，老 App/老 Gateway 下 MQTT OTA 功能隐藏或给出版本要求，不影响 BLE OTA。

## 版本与发布顺序

1. 先发布含 MQTT OTA 接口但默认关闭的 Gateway。
2. 发布兼容该协议的新 App；原 BLE OTA 仍可用。
3. 发布带 MQTT OTA adapter 的固件并在测试设备灰度验证。
4. 通过中断、断电和启动回滚验收后，再开放 App 中的正式 MQTT OTA 入口。

固件发布包仍使用当前签名构建流程；不通过 NAS 替代签名或绕过 App 的目标固件/分区/schema 兼容检查。
