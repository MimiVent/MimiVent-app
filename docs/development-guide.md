# MimiVent App 开发维护指南

本文说明常见改动应落在哪一层，以及改动后要核对哪些边界。项目当前是 Android BLE/WiFi HTTPS 控制端，安全配网经 BLE 完成，OTA 仍只走 BLE；其他平台不属于当前交付。

## 日常修改流程

1. 先确认固件接口和现有行为约定，尤其是环境切换、PIR 优先级、限时操作和任务覆盖规则。
2. 修改对应职责文件，避免在页面里直接调用 BLE 插件或拼装固件协议。
3. 按下表补齐同一功能涉及的模型、状态映射、用户反馈和文档。
4. 运行格式化、静态分析；涉及状态或协议边界时运行相关测试，并在 Android 真机核对。
5. 仅在用户明确要求发版时修改版本号、构建发布包或处理签名。不要自动提交代码。

常用检查命令：

```bash
dart format lib
flutter analyze
flutter test
flutter build apk --debug
```

项目使用的 `custom_3.22.0_harmony` SDK 如果缺少 `flutter_tester`，测试命令可能无法启动；不要因此修改依赖锁文件。可在隔离测试副本中使用本机标准 Flutter SDK 运行测试，避免改写主项目锁文件，再回到项目 SDK 做静态分析和 Android 构建。完整环境与设备安装命令见 [README](../README.md)。

## 常见改动对应的位置

| 需求 | 主要位置 | 维护边界 |
|---|---|---|
| 改 App 名称或副标题 | `lib/app/app_identity.dart` | 统一修改产品名，避免页面各自硬编码。 |
| 改颜色、背景或主题令牌 | `lib/app/theme/mimivent_theme.dart` | 优先改语义令牌；组件按用途取色，不复制局部品牌色。 |
| 改页面布局、连接弹窗或按钮文案 | `lib/features/dashboard/presentation/` | UI 负责呈现和转发意图，不直接操作 GATT 或重做固件状态机。 |
| 改控制操作和覆盖规则 | `lib/features/control/control_operation.dart`、`lib/data/mimivent_controller.dart` | 维护冷静期、同类重置、环境匹配及覆盖确认的一致语义。 |
| 改固件 API 路径、参数或响应映射 | `lib/api/mimivent_api.dart` | 与固件 API 契约同步；命令协议变更需要同时更新固件和协议说明。 |
| 改 BLE 扫描、连接、权限、GATT 或分包 | `lib/ble/` | 插件调用集中在 BLE 适配层；检查扫描轮次、连接会话和旧请求失效。 |
| 改设备能力边界 | `lib/data/device_repository.dart`、`lib/data/ble_device_repository.dart` | 控制器依赖 Repository；不要让 Dashboard 依赖具体 BLE API。 |
| 增加设备状态或时序字段 | `lib/data/models.dart`、API 映射、时间设置 UI | 同步 JSON 读写、固件字段、默认值来源、设置草稿和相关回归检查。 |
| 改时长选项或格式 | `lib/core/formatting/duration_formatter.dart` | 所有时间选择与展示复用同一组选项和格式化规则。 |
| 改响应式断点 | `lib/core/layout/app_layout.dart` | 按窗口约束与字号缩放处理，不按具体手机型号写分支。 |
| 改共用动画或弹窗协调 | `lib/shared/` | 共用组件只保留通用视觉/交互，不承载设备业务策略。 |
| 增加诊断事件或日志展示 | `lib/core/diagnostics/app_diagnostics_log.dart`、`lib/features/diagnostics/` | 高频状态轮询默认记录状态变化及 30 秒摘要；必要时可短时开启原始状态抓取。不要记录 Wi‑Fi 凭证或未脱敏设备地址。诊断页上限为 300 条；文件按日期及 1 MiB 切片，最多 10 个，存储失败不能影响控制流程。 |

## 新增控制操作

控制流程必须继续由设备固件执行，App 不复制 PIR 与排风状态机。

1. 先确认固件已有对应 endpoint、参数和响应；未实现的固件能力不能只加一个按钮。
2. 在 `ControlOperation` 增加明确的操作类型，并检查冷静期规则、当前操作匹配和可中断策略。
3. 在 `DeviceRepository` 声明设备能力，在 `BleDeviceRepository` 适配到 `MimiVentApi`；API 层负责路径、查询参数和错误转换。
4. 在 Dashboard 处理前置条件、确认、执行结果和错误反馈；按钮状态必须来自设备快照，不自行假定命令已成功。
5. 更新 `docs/behavior-contract.md` 和 `docs/regression-checklist.md`，覆盖同类重置、异类覆盖、断连和环境不匹配等场景。

## 新增设置字段

时序由固件保存，App 只编辑草稿并提交。

1. 与固件确认字段名、单位、合法范围、DEV/正式默认值和重置行为。
2. 更新 `TimingSettings` 的构造、JSON 解析/序列化与 `copyWith`。
3. 更新 API 表单映射、设置页字段键/说明和时间选择器零值策略。
4. 确认轮询不会覆盖未保存草稿，保存/重置只作用于当前环境；补充模型和设置回归覆盖。
5. 同步行为文档及 README 中相关用户说明。

## 新增页面或传输方式

- 新页面放入相应 `lib/features/<feature>/`；主 Dashboard 目前用 `IndexedStack` 保留控制与设置页面状态。新增导航时同时维护当前 Tab、断连行为、滚动状态与底部导航。
- 一个 App 会话只保留一套 `MimiVentController` 和设备 Repository；不要在新页面内创建第二个 BLE 管理器或并行轮询。
- 新传输方式应实现 Repository 能力并明确平台生命周期、权限和错误语义。修改 WiFi 时须保持现有连接选择、租约、写请求去重及状态同步语义，网络实现集中在 `lib/features/wifi_control/`。
- 当前交付平台为 Android，设备通信已支持 BLE 与 WiFi HTTPS。新增其他平台前分别验证插件、原生权限、安全存储和真实设备链路。

## 命名、注释与版本

- 文件名使用 `snake_case`；类型使用 `PascalCase`；成员使用 `lowerCamelCase`。
- 注释默认中文。模块注释说明职责和边界；异步方法说明过期会话、失败处理或资源释放，避免逐行翻译代码。
- 统一使用 `dart format` 和项目 `flutter_lints`；不要为消除单个警告随意全局关闭 lint。
- App 版本位于 `pubspec.yaml` 的 `version`；界面 App 版本由 `package_info_plus` 读取。固件版本来自设备 `/api/status` 响应。两个版本来源独立。
- 更改 App 版本、固件版本、协议 UUID、持久化键或命令 wire 字段前，先明确兼容策略。版本号变更和 release 签名是单独的发版动作。
