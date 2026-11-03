# MimiVent App 架构说明

当前 App 以一个共享的 `MimiVentController` 协调 BLE 会话、WiFi HTTPS 会话、设备快照、控制操作与设置草稿。设备 API 通过 `DeviceRepository` 注入，BLE 具体实现由 `BleDeviceRepository` 适配。BLE 插件只在 `MimiVentBleManager` 中使用；WiFi HTTPS 由 `WifiReadTransport` 封装；页面不直接操作 GATT 或 TLS。

## 目录职责

```text
lib/
├── main.dart                              # runApp 入口
├── app/
│   ├── app_identity.dart                  # 产品名称与副标题
│   ├── mimivent_app.dart                  # 应用装配、生命周期与控制器
│   └── theme/mimivent_theme.dart          # 语义颜色、主题扩展、动效时长
├── api/mimivent_api.dart                  # 固件 API 到 BLE 请求的映射
├── ble/
│   ├── ble_protocol.dart                  # 请求编码、分包响应解析
│   ├── ble_disconnect_gate.dart           # 过滤连接前回放的初始断开状态
│   └── mimivent_ble_manager.dart          # 扫描、GATT、权限、请求队列
├── core/
│   ├── diagnostics/app_diagnostics_log.dart # 有界本地诊断日志与隐私过滤
│   ├── formatting/duration_formatter.dart # 时长选项与显示
│   └── layout/app_layout.dart             # 短屏、大字号等响应式断点
├── data/
│   ├── background_ble_lifecycle.dart      # 后台宽限期与会话恢复
│   ├── device_connection_manager.dart     # WiFi/BLE 实际通道与顶部状态
│   ├── mimivent_controller.dart           # App 级设备状态和操作协调
│   ├── device_repository.dart             # 控制器使用的设备 API 契约
│   ├── ble_device_repository.dart         # 固件 API 的 BLE Repository 适配器
│   ├── settings_draft.dart                # 已保存配置与编辑草稿隔离
│   └── models.dart                        # 设备状态与时序模型
├── features/
│   ├── diagnostics/                       # 本地诊断日志页面
│   ├── control/                           # 控制意图、操作规则和状态 Presenter
│   ├── connection/                        # 通道徽标与连接 UI 呈现状态
│   ├── wifi_control/                      # WiFi 绑定、HTTPS 传输、主页通道
│   ├── wifi_provisioning/                 # BLE 配网与手机侧网络选择
│   └── dashboard/presentation/            # 连接、控制和时序设置 UI
└── shared/
    ├── presentation/mimi_vent_dialogs.dart # 统一确认弹窗
    ├── presentation/modal_coordinator.dart # 页面弹窗单飞协调
    └── widgets/device_animations.dart     # 风机、蓝牙搜索和 Logo 动画
```

Dashboard presentation 采用 part 文件把一组紧密耦合的 State 辅助方法分开。它们仍属于同一个 library，因此可复用页面内部状态，不需要将内部状态字段改成 public。连接、操作/配置、主体区块、状态卡片分别放在独立文件中。

新增功能时的修改步骤、验证命令和目录责任见 [development-guide.md](development-guide.md)。README 是开发入口，本文聚焦模块协作与状态流；设备操作语义以 [behavior-contract.md](behavior-contract.md) 为准。

## 状态流

1. `MimiVentApp` 创建唯一 `MimiVentController`，并连接 Flutter App 生命周期。
2. 启动先探测本机 WiFi 绑定；成功则 `activateWifi` 进入主页 WiFi 控制，失败则延迟 6 秒再探测一次，仍未恢复才进入 BLE 扫描。
3. `DeviceConnectionManager` 根据实际可用通道显示 `WiFi 控制`/`蓝牙控制`/`设备未连接`；BLE 断开回到 WiFi，WiFi 断开进入重试。
4. `BackgroundBleLifecycle` 处理后台 10 分钟宽限期；在宽限期内回前台保留 BLE，超时后释放连接，回前台重新扫描。
5. `MimiVentBleManager` 唯一拥有扫描订阅、设备连接、GATT 特征和 BLE 命令队列。
6. `MimiVentApi` 以 BLE 请求承载固件 `/api/*` 路径、环境和模式参数。
5. Controller 读取设备快照，绑定当前 BLE 会话、连接尝试与 App 环境。会话或环境变更后，过期响应不会继续触发后续读取，也不会覆盖当前 UI。
6. `SettingsDraft` 把服务端已保存配置与本地待保存编辑隔离；状态轮询不覆盖编辑草稿。
7. Dashboard 只展示快照、配置草稿和动作入口。控制入口使用 `ControlOperation`，返回 `OperationSucceeded` / `OperationRejected`；设备确认成功后才显示成功提示。
8. BLE 原始状态由 `ConnectionPresentation` 统一映射；确认类弹窗经 `ModalCoordinator` 防止并发弹出或确认串台。
9. BLE 请求入队时固定设备、命令通道和连接序号；轮到已过期请求时直接拒绝，不会把旧命令转发给快速重连后的设备。断开会结束挂起响应，控制器销毁后忽略异步通知。
10. FlutterBluePlus 连接状态流可能在订阅时先回放缓存的初始状态。`BleDisconnectGate` 忽略连接建立前的 `disconnected`，只在当前设备已建立连接后处理断连，避免初始回放清空 GATT 通道。
11. `AppDiagnosticsLog` 由 `MimiVentApp` 创建并注入 BLE、API 和控制器；诊断页在本机保留最近 300 条；另以 JSON Lines 写文件，按日期及 1 MiB 切片，最多保留 10 个分片。状态轮询默认只记录语义变化和每 30 秒一次摘要，诊断页可临时开启最多 5 分钟的状态原始抓取；控制命令和通信异常保留协议文本、通知分包十六进制、解析响应和耗时。日志持久化最多每 5 秒写入一次，清空和退出时立即刷新。连接地址会脱敏；WiFi 密码仅经过独立安全配网通道且不写日志；token 不得写日志。
12. 设备状态和时序配置模型对必需字段、数据类型、固件枚举、环境名称及固件允许的时长选项做校验。响应缺字段或非法时会报错并保留为读取失败，不会静默回退到 `0`、`false` 或正式环境；固件版本字段仍兼容缺失的旧响应。

设备端状态是 PIR 与风机实际行为的事实来源。App 不复制固件的 PIR 排风状态机。

## 设计约束

- 控制写请求保持串行；这保证 BLE 协议顺序，不代表用户操作要排队等待计时结束。
- 相同的限时操作允许替换当前任务并重新计时；覆盖不同任务时先让用户确认。
- 正式与 DEV 是设备侧独立时序配置。App 选择环境和固件当前环境必须明确比对，未同步时禁止发送控制命令。
- WiFi 请求集中在 `WifiReadTransport`（沿用早期命名，当前支持读写）；页面不直接调用 TLS，写请求通过请求 ID 对账。
- 新状态/协议转换优先放在 `data/models.dart`、API 层或 Presenter，避免把固件 wire 字符串判断散落到多个 Widget。
- 新设备命令通过 `DeviceRepository` 与 BLE 适配器扩展；页面不直接依赖 `MimiVentApi` 或 BLE 插件。
- 新控制入口先加入 `ControlOperation`，并为冷静期、同类重置和可打断规则添加纯单元测试。
