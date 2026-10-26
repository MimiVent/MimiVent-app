# MimiVent Android App

MimiVent 的 Android 蓝牙控制端。App 通过 BLE 连接 ESP32-C3，不需要打开设备热点，也不需要 HTTPS 网页。

## 当前功能

- 扫描并连接广播名为 `MimiVent`、提供 MimiVent GATT 服务的设备。
- App 启动时自动扫描；短暂切到后台会保留 BLE 连接，超过 30 秒宽限期后断开，回到前台时重新扫描。
- 使用网站同款猫咪图标作为 App 图标和页面标识。
- 查看风机、PIR、运行阶段、剩余时间、固件版本和当前时序。
- 顶部显示 App 版本、构建号和连接设备上报的固件版本；页面使用深色渐变背景。
- 在正式运行与 DEV 联调环境之间切换。App 会记住上次选择；每次连接后将 App 环境与设备实际环境分别展示。
- 环境不一致时，控制和设置保持锁定。可以选择“切换设备环境”（确认后立即停止旧流程并进入 App 当前选择环境的自动感应），或“App 跟随设备”（只改变 App 选择，不发送设备切换指令）。
- 控制自动感应、限时临时排风、临时暂停、限时强制排风和持续关闭。
- 修改并保存五项时序，或将当前环境恢复为固件默认值。
- 从右上角菜单或时间设置页打开设备诊断；查看 App、扫描、连接和设备接口事件，复制或清空日志。
- 对覆盖正在运行的任务、切换环境和持续关闭提供确认。

## App 页面

连接设备后，主界面底部有两个页面入口：

- **控制**：查看设备、PIR、运行阶段和本轮时长；选择自动感应、临时排风、临时暂停、强制排风或持续关闭。强制排风限时运行并忽略 PIR。快捷操作支持横向滑动。
- **时间设置**：切换正式/DEV 环境，调整启动冷静期、离开确认、自动排风、临时排风和临时暂停时长；可保存或恢复当前环境的默认值。
- 时间设置页底部提供设备诊断入口；未连接设备时也可以从右上角菜单打开诊断页。

未连接设备时，主界面显示连接入口和扫描状态；连接成功后即可使用控制和设置。内容在窄屏和短屏上可滚动，在平板、折叠屏和桌面窗口上限制最大内容宽度；设备连接弹窗有最大高度并可滚动。

覆盖正在执行的任务时，App 会先确认再取消旧流程；重新点击当前相同的限时操作会从现在起重新计时，不会排队。临时排风遵循 PIR 优先规则；强制排风会忽略 PIR，并按当前临时排风时长自动停止。持续关闭需要确认，开启后需手动恢复自动感应。

## 环境要求

- MimiVent 固件已烧录并启用 BLE 控制。
- Flutter SDK：`custom_3.22.0_harmony`（Flutter 3.22.1-0.0.pre.28 / Dart 3.4.0）。此版本可继续复用你现有的鸿蒙 Flutter 环境。
- Android SDK、Android Studio 与已安装的 Android 设备或模拟器。
- Android 构建使用 JDK 11。当前 Gradle Wrapper 为 7.6.3，Android Gradle Plugin 为 7.3.0，Kotlin Gradle Plugin 为 1.7.10。
- 首次构建前接受 Android SDK licenses：

```bash
flutter doctor --android-licenses
```

## 开发和运行

```bash
flutter pub get
flutter run
```

在 Android 手机上允许“附近设备 / 蓝牙”权限。Android 11 及以下还需允许定位权限，这是旧版 Android 扫描 BLE 所需的系统权限；App 不会读取或上传位置。

启动后 App 会自动开始 12 秒 BLE 扫描。扫描面板显示发现数量；发现一台设备时展示单设备连接卡片，多台时可从列表选择。扫描结束后可重新扫描。短暂切到后台会保留连接 30 秒；超过宽限期后断开，返回前台会重新扫描。

App 环境选择保存在手机本地。设备重启会按固件规则回到“正式运行”，如果手机上次选择的是 DEV，重新连接时会明确提示环境不同；此时先选择切换设备或让 App 跟随设备，再进行控制。

设备日志保存在本机，最多保留最近 300 条；诊断页可复制全部日志或清空。设备状态轮询默认只记录状态变化和每 30 秒一次摘要，避免每秒重复写入；控制命令、扫描连接过程和通信异常保留 BLE 请求/响应明细。需要排查轮询分包时，可在诊断页开启状态原始抓取，支持手动结束并会在 5 分钟后自动关闭。日志会过滤设备地址；Wi‑Fi 凭证不会通过 BLE 控制协议传输，也不会记录。日志持久化最多每 5 秒写入一次，清空和退出时立即刷新。

构建 APK：

```bash
flutter build apk --release
```

生成文件：`build/app/outputs/flutter-apk/app-release.apk`。

当前 Release 变体使用 Debug 签名，适合个人设备安装和验证。正式公开分发或应用商店上架前，需要配置长期保管的 Release keystore；私钥与密码不得提交到 Git。当前正式版本为 `0.2.0+2`；后续更新需递增构建号。

用 USB 数据线安装到 Android 真机：先在手机开启“开发者选项 / USB 调试”，连接电脑并在手机上允许此电脑调试，然后确认设备已授权：

```bash
adb devices -l
```

设备状态显示为 `device` 后，可直接把刚生成的 APK 安装或覆盖安装到手机：

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

也可以一步完成 release 编译并安装到 USB 真机（只连接一台 Android 设备时）：

```bash
flutter install --release --device-connection attached
```

也可以用 `flutter run -d <设备ID>` 编译并安装调试版。若 `adb devices -l` 没有列出手机，先更换支持数据传输的 USB 线并检查 USB 调试授权。

如果只需要安装到常见的 64 位 Android 手机，可生成体积更小的 ARM64 安装包：

```bash
flutter build apk --release --target-platform android-arm64
```

安装包同样位于 `build/app/outputs/flutter-apk/app-release.apk`。

## BLE 协议

BLE GATT UUID 与固件保持一致：

| 项目 | UUID |
|---|---|
| Service | `6f9b0001-7d5a-4c3b-9a21-2f6d4d494d49` |
| Command | `6f9b0002-7d5a-4c3b-9a21-2f6d4d494d49` |
| Response | `6f9b0003-7d5a-4c3b-9a21-2f6d4d494d49` |

请求按固件协议使用换行分隔：`method / path / profile / mode / stage / replace / switch / body`。响应是 `HTTP状态码\n响应体\n`，固件可能把响应拆成多个 BLE 通知；App 会按 UTF-8 字节重组后再解析，并串行发送请求。

Wi-Fi SSID 和密码不会通过 BLE 下发，避免把家庭网络凭证暴露在蓝牙控制通道。当前 App 只实现蓝牙控制；局域网 Wi-Fi 控制后续可以作为另一个传输适配器加入。

## 代码结构

- `lib/main.dart`：应用入口。
- `lib/app/`：应用装配、产品名称和 MimiVent 主题令牌。
- `lib/api/`：固件 API 路径、参数、响应和错误映射。
- `lib/features/dashboard/presentation/`：连接流程、控制/设置页面、状态卡片和用户操作，按职责拆成多个 part 文件，共享页面私有状态。
- `lib/features/control/`：控制操作类型、设备状态展示文案。
- `lib/features/connection/`：BLE 状态到连接页面状态的映射。
- `lib/shared/`：跨页面动画、确认弹窗和弹窗协调器。
- `lib/core/`：共用诊断日志、时长格式化和响应式布局断点。
- `lib/features/diagnostics/`：本地诊断日志查看、复制和清空界面。
- `lib/data/`：设备控制器、Repository 边界与 BLE 实现、设备/时序模型、App 前后台 BLE 生命周期。
- `lib/ble/`：BLE 插件适配、权限、GATT、扫描、连接、请求队列和协议分包。

页面通过 `MimiVentController` 读取设备快照并发起操作；页面不直接调用 BLE 插件。控制器在 BLE 会话变化后清理设备状态，并丢弃来自旧连接或旧环境的异步读取结果。

维护指南见 [docs/development-guide.md](docs/development-guide.md)；状态流和模块边界见 [docs/architecture.md](docs/architecture.md)，设备行为约定见 [docs/behavior-contract.md](docs/behavior-contract.md)，手工回归项目见 [docs/regression-checklist.md](docs/regression-checklist.md)。

## 检查

```bash
flutter analyze
flutter test
flutter build apk --debug
```

协议测试覆盖请求字段顺序、分片响应以及中文 UTF-8 字符跨包重组。若 `custom_3.22.0_harmony` 环境缺少 `flutter_tester`，请使用本机可运行测试的标准 Flutter SDK 执行 `flutter test`；不要为此修改项目依赖锁文件。

### 首次 APK 分发说明

当前 `android/app/build.gradle` 的 Release 变体仍使用 Debug 签名，适合个人设备安装和验证。正式公开分发或应用商店上架前，需要配置长期保管的 Release keystore；私钥与密码不得提交到 Git。当前正式版本为 `0.2.0+2`；后续更新需递增构建号。
