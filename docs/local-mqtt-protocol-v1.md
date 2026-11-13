# MimiVent 本地 MQTT 接入协议 v1

> **历史协议，已被新优化方案取代。** 本文保留旧版实施记录，其中设备 HTTPS 回退、队列预算等不代表当前目标。后续实现和验收以[蓝牙、MQTT 与 NAS 优化方案 v1.4](ble-mqtt-nas-optimization-v1.md)为准；迁移时不得直接照搬旧回退行为。

## 目标与边界

本阶段在局域网内由 App 调用 NAS 网关 HTTP API，网关再通过 NAS Mosquitto Broker 向 ESP32 下发控制命令，ESP32 回传状态与执行结果。App 不直接持有 MQTT 凭据。现有 BLE 配网、绑定流程、HTTPS 读取和直连 Wi-Fi 控制继续保留；网关不可用时由 App 回退到设备 HTTPS/BLE 直连。

固件仍独立执行 PIR、风机状态机、定时任务和安全保护。MQTT 只转发控制请求，不承担实时闭环；Broker 断连、NAS 关机或 App 退出均不得停止设备本地自动运行。

第一阶段仅支持家中局域网地址和明文 MQTT TCP 1883，Broker 端口只供 NAS 网关和 ESP32 使用，不得配置路由器公网转发。NAS 网关提供 App 使用的 HTTP API。远程访问、TLS、云端桥接及 NAS 故障时的自动云端切换属于后续阶段。

## Topic

设备 ID 使用固件现有的 32 位小写十六进制 `deviceId`。

| Topic | 发布者 | 订阅者 | Retain | 内容 |
| --- | --- | --- | --- | --- |
| `mimivent/v1/{deviceId}/state` | ESP32 | NAS 网关 | 是 | 最新状态快照 |
| `mimivent/v1/{deviceId}/availability` | ESP32 遗嘱/连接回调 | NAS 网关 | 是 | `online` 或 `offline` |
| `mimivent/v1/{deviceId}/command` | NAS 网关 | ESP32 | 否 | 控制请求 |
| `mimivent/v1/{deviceId}/ack` | ESP32 | NAS 网关 | 否 | 请求接受/拒绝结果 |

命令和确认采用 QoS 1；状态与在线状态采用 QoS 1。客户端使用干净会话，不在 Broker 保存离线控制命令。命令不设置 retained。

## 消息结构

### MQTT 控制消息 v2（必须同时更新网关与固件）

App 到 NAS 的 HTTPS API 仍是 version 1；MQTT 控制及 ACK 改用 version 2，topic 路径保持不变。旧版固件会拒绝 version 2，避免把预检当成实际控制。网关先发布 `phase: "prepare"`，字段包含 requestId、tokenId、token、path、body，设备验证 token 后返回 `status: "ready"`，body 为 `{ issuedAtMs, challenge }`。

`challenge` 是设备随机会话密钥对请求 ID、token、path、body 和设备计时签发的 HMAC-SHA256。网关只接受请求开始后 1 秒内到达的 ready，再以 `phase: "execute"` 原样携带凭据。固件在接收、获取命令锁后及获取业务锁后校验设备计时，签发超过 1 秒则拒绝，重启或 MQTT 重连会使旧凭据失效，无需依赖系统校时。

网关 ACK 总等待窗口限定 2500–3000ms。预检未完成时返回 503 / commandPublished:false；执行消息发出后结果未知返回 504 / commandPublished:true。App 会持久保留原请求 ID，后续控制点击仅查询原结果，直到确认成功/拒绝，或用户核对设备状态并明确结束确认。

固件当前接受的命令格式（网关把 App 的设备路径与表单原样转发）：

```json
{
  "version": 2,
  "phase": "execute",
  "issuedAtMs": 123456,
  "challenge": "设备 ready 回复中的 64 位十六进制签名",
  "requestId": "UUID",
  "tokenId": "当前 App 的 WiFi 绑定 token ID（网关关联用）",
  "token": "当前 App 的 WiFi 绑定 bearer token，由 NAS 网关从 HTTPS Authorization 头转发",
  "path": "/api/timed",
  "body": "profile=production&mode=on&replace=1"
}
```

`path` 第一版仅支持 `/api/auto`、`/api/timed`、`/api/test-fan`、`/api/lockoff`，`body` 是现有 HTTP 表单编码，最大 256 字节。固件仍按现有 `ControlApi` 规则校验参数；不能由传输层绕过设备端保护。

确认示例：

```json
{
  "version": 2,
  "requestId": "UUID",
  "status": "applied",
  "httpStatus": 200,
  "body": { "ok": true }
}
```

确认中的 `body` 是设备 `ControlApi` 返回的 JSON 对象。重复请求不会再次执行，返回重复结果。状态 JSON 目前沿用现有 `/api/status` 字段；App 只能把收到的 `ack` 当作请求结果，设备后续状态快照是实际状态的依据。

## App 到 NAS 网关 API

App 调用 `POST /api/v1/devices/{deviceId}/control`，使用现有 WiFi 绑定 bearer token 作为 HTTPS `Authorization`。TLS 证书必须匹配 App 保存的 SHA-256 指纹。请求 JSON 包含 `version`、`requestId`、`tokenId`、设备原有 HTTP `path` 和表单 `body`。网关把 bearer token 放入 MQTT 命令 `token` 字段，固件仍通过绑定表中的 token 哈希验证权限。

网关等待设备 `ack` 后以 HTTP 200 响应：`{ "requestId": "UUID", "httpStatus": 200, "body": { "ok": true } }`。网关在发送 MQTT 前发现 Broker 不可用时，返回 HTTP 503 并带 `commandPublished: false`；App 可安全地以同一个 `requestId` 回退到设备 HTTPS。设备 ACK 等待超时返回 504 且 `commandPublished: true`，App 不自动回退，因为执行结果未知。网络断开/超时由 App 以同一个 requestId 回退；固件持久去重表保证不会再次执行。

## 安全与控制一致性

- NAS Broker 使用独立 MQTT 账号；仅 NAS 网关和固件在 NAS 配置目录 / ESP32 NVS 保存凭据，不写入源码或版本库。App 使用 NAS 网关 API 认证，不获取 Broker 凭据。
- 固件 ACL 只允许订阅对应设备的 `command`，并发布该设备的 `state`、`availability`、`ack`。网关账号只允许发布已配置设备的 `command` 并订阅相应设备的状态/确认主题。
- 每条命令必须有格式正确的 UUID `requestId`。ESP32 将近期请求写入与 HTTPS 共用的持久去重表；重复 ID 不会再次执行。
- 去重表容量为 32 条，每条记录至少保留 10 分钟；重启恢复的记录从本次启动重新计时。窗口内满表时以 429 `DEDUP_WINDOW_FULL` 拒绝新控制，禁止提前覆盖。过期记录可供新请求复用，所以不能承诺无限期去重，也不能在 10 分钟后自动重放旧请求。旧版 8 条持久记录兼容恢复。
- 新去重记录将原始表单正文的 SHA-256 摘要一起持久化，HTTPS/MQTT 共用相同检查：同 ID、同路径、同正文返回原去重结果，路径或正文不同返回 409 `REQUEST_ID_CONFLICT`。正文按实际 UTF-8 字节比较，不重排参数；禁止内嵌 NUL。旧版 8/32 条无摘要记录继续可查历史状态，但执行接口返回 `REQUEST_BODY_UNKNOWN`，不得推断成当前正文已执行。NAS 不将该错误缓存为拒绝，App 转而查询原结果。
- MQTT outbox 数据硬上限 4096 字节；状态/在线消息只使用 2048 字节预算，为 ACK 保留空间。所有消息均检查预算，SDK 入队失败不会降级为同步阻塞发送。BLE `wifi.mqtt.status` 提供 `outboxBytes`、`queueRejected`、`enqueueFailures` 诊断字段；ready 无法入队时不会进入执行，执行 ACK 无法入队时由请求结果查询恢复。
- App 在收到成功 ACK 或查询到 `applied` 后保留执行成功结果；随后设备直连读取失败时仅提示状态暂不可用，不重新发送控制，也不把成功结果改报成执行失败。
- 本地确认记录清理失败（包括抛异常或返回 false）不能覆盖执行成功；App 会保留进程内请求保护，并尝试恢复持久记录，后续点击仅处理原请求。App 先查询经过原始绑定凭据鉴权的 NAS 缓存，无可用结果时再查固件；固件历史结果查询不会获取或续期控制租约。
- MQTT 控制和 HTTPS 控制都调用同一 `ControlApi`，并沿用同一控制互斥锁。HTTPS 的单控制租约不能被 MQTT 绕开；接入实现必须在两种传输间建立一致的控制占用/释放规则后，才能开放 MQTT 写操作。
- 断线重连使用退避；重连后只接收新命令，不补发历史控制。设备断网时自动通风状态机继续正常运行。

## 实施顺序

1. 固件可选 MQTT transport 已实现：BLE 配置 NAS Broker 地址与凭据；发布状态和 LWT；命令携带绑定 bearer token，通过设备绑定校验、共用租约和去重表后调用 `ControlApi`。仍需在目标 NAS / Broker 上做联调。
2. NAS 网关（后续部署阶段）以 HTTP API 认证 App 请求，转发命令到 MQTT 并等待设备确认；不把 Broker 凭据交给 App。
3. App 增加 NAS 网关地址配置和安全 API 凭据存储；仅在网关可达时选择 NAS 控制；网关失败或超时回退到现有 HTTPS 直连，仍以设备响应和状态校验结果反馈成功/失败。
4. 编译和静态分析仅使用项目固定的工具链（App Flutter 3.22；固件 Arduino-ESP32 3.3.12）。必须测量 ESP32-C3 内部堆峰值、最大连续块、HTTPS 服务可用性，以及 Broker 断连时本地自动控制。
5. 远程桥接、数据库历史同步及 App→云→NAS 路径另立版本，不作为本协议 v1 的隐式行为。
