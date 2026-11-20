import 'dart:async';
import 'dart:math';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_identity.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../ble/mimivent_ble_manager.dart';
import '../data/background_ble_lifecycle.dart';
import '../data/device_connection_manager.dart';
import '../data/mimivent_controller.dart';
import '../features/dashboard/presentation/dashboard_page.dart';
import '../features/local_network/wifi_binding_store.dart';
import '../features/local_network/nas_gateway_models.dart';
import '../features/local_network/nas_gateway_startup_probe.dart';
import '../features/local_network/wifi_binding_and_nas_page.dart';
import '../features/wifi_provisioning/wifi_provisioning_page.dart';
import 'theme/mimivent_theme.dart';

class MimiVentApp extends StatefulWidget {
  const MimiVentApp({super.key});

  @override
  State<MimiVentApp> createState() => _MimiVentAppState();
}

class _MimiVentAppState extends State<MimiVentApp> with WidgetsBindingObserver {
  bool _globalLoading = true;
  String _globalLoadingLabel = '正在连接设备…';

  void _setGlobalLoading(bool active, {String? label}) {
    if (!mounted) return;
    if (_globalLoading == active &&
        (label == null || _globalLoadingLabel == label)) {
      return;
    }
    setState(() {
      _globalLoading = active;
      if (label != null) _globalLoadingLabel = label;
    });
  }

  late final MimiVentController controller;
  late final AppDiagnosticsLog diagnostics;
  late final BackgroundBleLifecycle _bleLifecycle;
  void Function(FlutterErrorDetails details)? _previousFlutterErrorHandler;
  bool Function(Object error, StackTrace stackTrace)?
      _previousPlatformErrorHandler;
  NasGatewaySnapshot? _nasSnapshot;
  bool _useNasMqtt = false;
  bool _nasMqttControllerActive = false;
  bool _nasActivationInFlight = false;
  bool _manualBle = false;
  bool _switchingToNasMqtt = false;
  bool _bluetoothSwitchFinalizing = false;
  bool _bluetoothSwitchCompleted = false;
  Future<void>? _bluetoothSwitchCompletion;
  final ValueNotifier<(int, String)?> _channelSwitchNotice =
      ValueNotifier(null);
  int _channelSwitchNoticeId = 0;
  bool _appForeground = true;
  bool _blePreScanInFlight = false;
  Timer? _blePreScanTimer;
  DateTime? _busyFallbackAt;
  Timer? _nasRetryTimer;
  int _nasRetryAttempts = 0;
  bool _nasRetryInFlight = false;
  late final DeviceConnectionManager connection;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    diagnostics = AppDiagnosticsLog();
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      diagnostics.error(
        'Flutter 未捕获异常',
        details.exceptionAsString(),
        stackTrace: details.stack,
      );
      final previous = _previousFlutterErrorHandler;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    _previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      diagnostics.error('Dart 未捕获异常', error.toString(), stackTrace: stackTrace);
      return _previousPlatformErrorHandler?.call(error, stackTrace) ?? false;
    };
    controller = MimiVentController(diagnostics: diagnostics);
    connection = DeviceConnectionManager();
    controller.addListener(_syncConnection);
    _syncConnection();
    _bleLifecycle = BackgroundBleLifecycle(
      closeSession: controller.closeBluetoothSession,
      resumeSession: _resumeApp,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initializeApp());
    });
  }

  void _stopNasRetry() {
    _nasRetryTimer?.cancel();
    _nasRetryTimer = null;
    _nasRetryAttempts = 0;
  }

  void _startNasRetry() {
    if (_manualBle || controller.nasMqttBusy) return;
    _stopNasRetry();
    _scheduleNasRetry();
  }

  bool get _shouldPreScanBle =>
      mounted &&
      _appForeground &&
      _nasMqttControllerActive &&
      !_manualBle &&
      !controller.ble.isConnected &&
      !controller.ble.isScanning;

  void _syncBlePreScan({bool immediate = false}) {
    if (!_shouldPreScanBle) {
      _blePreScanTimer?.cancel();
      _blePreScanTimer = null;
      unawaited(controller.ble.stopPreScan());
      return;
    }
    if (_blePreScanTimer != null || _blePreScanInFlight) return;
    _blePreScanTimer = Timer(
      immediate ? Duration.zero : const Duration(seconds: 30),
      () async {
        _blePreScanTimer = null;
        if (!_shouldPreScanBle || _blePreScanInFlight) return;
        _blePreScanInFlight = true;
        try {
          await controller.ble.preScan();
        } finally {
          _blePreScanInFlight = false;
          if (_shouldPreScanBle) _syncBlePreScan();
        }
      },
    );
  }

  Future<void> _stopBlePreScan() async {
    _blePreScanTimer?.cancel();
    _blePreScanTimer = null;
    await controller.ble.stopPreScan();
  }

  void _scheduleNasRetry() {
    final jitter = 4500 + Random().nextInt(2500);
    _nasRetryTimer = Timer(Duration(milliseconds: jitter), () {
      unawaited(_tryWifiReconnect());
      if (_nasRetryTimer != null && !_manualBle) {
        _scheduleNasRetry();
      }
    });
  }

  Future<void> _tryWifiReconnect() async {
    if (!mounted || _nasRetryInFlight || _manualBle || controller.nasMqttBusy)
      return;
    if (_nasRetryAttempts >= 12) {
      _stopNasRetry();
      return;
    }
    _nasRetryAttempts++;
    _nasRetryInFlight = true;
    try {
      final snapshot = await probeNasGatewayStartup();
      if (snapshot == null || !mounted || _manualBle) return;
      await controller.activateNasMqtt(snapshot.binding);
      if (!mounted || _manualBle) return;
      _stopNasRetry();
      setState(() {
        _nasSnapshot = snapshot;
        _useNasMqtt = true;
        _nasMqttControllerActive = true;
      });
      _syncBlePreScan(immediate: true);
      connection.update(nasMqtt: true, preferBle: false);
      final nav = _navigatorKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.popUntil((route) => route.isFirst);
      }
      diagnostics.info('NAS MQTT 重连', 'NAS 网关状态同步已恢复，切回 NAS MQTT 控制');
    } catch (error) {
      diagnostics.warning('NAS MQTT 重连', '重试 ${_nasRetryAttempts} 失败：$error');
    } finally {
      _nasRetryInFlight = false;
    }
  }

  void _syncConnection() {
    _syncBlePreScan();
    final ble = controller.ble.isConnected;
    if (!controller.nasMqttBusy) _busyFallbackAt = null;
    // 先处理已经完全就绪的 BLE 切换，再处理 MQTT busy/掉线分支；否则 busy
    // 分支会提前 return，导致 BLE 已可用却没有结束切换或显示成功提示。
    if (_manualBle &&
        !_bluetoothSwitchCompleted &&
        !_switchingToNasMqtt &&
        controller.bluetoothControlReady) {
      unawaited(_finishBluetoothSwitch());
      return;
    }
    if (controller.nasMqttBusy) {
      if (mounted) {
        setState(() {
          _useNasMqtt = false;
          _nasMqttControllerActive = false;
        });
      }
      if (!_manualBle) _bluetoothSwitchCompleted = false;
      _manualBle = true;
      _syncBlePreScan();
      connection.update(
          nasMqtt: false, ble: ble, connecting: false, preferBle: true);
      final now = DateTime.now();
      if (!ble &&
          (_busyFallbackAt == null ||
              now.difference(_busyFallbackAt!) > const Duration(seconds: 15))) {
        _busyFallbackAt = now;
        unawaited(_connectBluetooth());
      }
      return;
    }
    // 切换采用 make-before-break：BLE 传输连上还不够，必须完成设备状态、
    // 设置和兼容性初始化后，才能释放 NAS MQTT 控制通道。
    if (_manualBle && !_switchingToNasMqtt && controller.nasMqttActive) {
      if (controller.bluetoothControlReady) {
        unawaited(_finishBluetoothSwitch());
      } else {
        connection.update(
          nasMqtt: true,
          ble: ble,
          connecting: controller.bluetoothBootstrapInProgress ||
              controller.ble.connectionStatus == BleConnectionStatus.connecting,
          preferBle: true,
        );
      }
      return;
    }
    if (ble && _manualBle) {
      if (controller.bluetoothControlReady) {
        connection.update(
          nasMqtt: false,
          ble: true,
          connecting: false,
          preferBle: true,
        );
      } else {
        connection.update(
          ble: true,
          connecting: true,
          preferBle: true,
        );
      }
      return;
    }
    connection.update(
      ble: ble,
      connecting:
          controller.ble.connectionStatus == BleConnectionStatus.connecting,
    );
    if (controller.nasMqttActive) {
      connection.update(nasMqtt: true, preferBle: false);
    } else if (controller.nasMqttLost && _nasMqttControllerActive) {
      setState(() {
        _useNasMqtt = false;
        _nasMqttControllerActive = false;
      });
      _syncBlePreScan();
      connection.update(nasMqtt: false, ble: false, preferBle: false);
      _startNasRetry();
    }
    if (!ble &&
        _nasSnapshot != null &&
        !_useNasMqtt &&
        !_nasActivationInFlight &&
        !_manualBle &&
        !controller.nasMqttLost &&
        !controller.nasMqttBusy &&
        mounted) {
      _nasActivationInFlight = true;
      final binding = _nasSnapshot!.binding;
      unawaited(controller.activateNasMqtt(binding).then((_) {
        if (mounted && controller.nasMqttActive) {
          setState(() {
            _useNasMqtt = true;
            _nasMqttControllerActive = true;
          });
          _syncBlePreScan(immediate: true);
          connection.update(nasMqtt: true, preferBle: false);
        }
      }).catchError((Object error) {
        if (mounted) {
          setState(() {
            _useNasMqtt = false;
            _nasMqttControllerActive = false;
          });
          connection.update(nasMqtt: false, ble: controller.ble.isConnected);
        }
        diagnostics.warning('NAS MQTT 自动恢复', '会话未就绪，保持当前通道：$error');
      }).whenComplete(() => _nasActivationInFlight = false));
    }
  }

  Future<void> _initializeApp() async {
    try {
      await diagnostics.initialize();
    } catch (_) {
      _setGlobalLoading(false);
      return;
    }
    diagnostics.info(
      '应用',
      'MimiVent App 已启动；诊断文件=${diagnostics.fileLogDirectoryPath ?? '不可用'}；'
          '单文件上限 1 MiB，最多保留 10 个分片',
    );
    if (!mounted) return;
    try {
      // 有本地 WiFi 绑定时先走只读通道，避免启动即申请蓝牙权限/强制扫描。
      final snapshot = await probeNasGatewayStartup();
      if (!mounted) return;
      if (snapshot != null) {
        var active = false;
        try {
          await controller.activateNasMqtt(snapshot.binding);
          active = true;
        } catch (error) {
          diagnostics.warning('NAS MQTT 控制', '启动 NAS MQTT 控制失败：$error');
        }
        if (!mounted) return;
        if (active) {
          setState(() {
            _nasSnapshot = snapshot;
            _useNasMqtt = true;
            _nasMqttControllerActive = true;
          });
          _syncBlePreScan(immediate: true);
          _manualBle = false;
          _stopNasRetry();
          connection.update(nasMqtt: true, connecting: false, preferBle: false);
          _setGlobalLoading(false);
        } else {
          setState(() {
            _nasSnapshot = null;
            _useNasMqtt = false;
            _nasMqttControllerActive = false;
          });
          connection.update(nasMqtt: false, connecting: false);
          _startNasRetry();
          _setGlobalLoading(false);
          await _connectBluetooth();
        }
        diagnostics.info('应用启动',
            active ? '已有 WiFi 设备绑定，进入 NAS MQTT 控制' : 'NAS MQTT 不可用，进入只读页面');
        return;
      }
      connection.update(nasMqtt: false);
      _startNasRetry();
      // 给刚重启的设备 WiFi 一个 6 秒窗口，避免一启动就弹蓝牙扫描/权限。
      await Future<void>.delayed(const Duration(seconds: 6));
      if (!mounted || _nasMqttControllerActive || _manualBle) return;
      final late = await probeNasGatewayStartup();
      if (late != null && mounted && !_manualBle) {
        await controller.activateNasMqtt(late.binding);
        if (!mounted || _manualBle) return;
        _stopNasRetry();
        setState(() {
          _nasSnapshot = late;
          _useNasMqtt = true;
          _nasMqttControllerActive = true;
        });
        _syncBlePreScan(immediate: true);
        connection.update(nasMqtt: true, preferBle: false);
        _setGlobalLoading(false);
        diagnostics.info('应用启动', '延迟探测到设备 WiFi，未进入蓝牙扫描');
        return;
      }
      _setGlobalLoading(false);
      await _connectBluetooth();
    } catch (error) {
      _setGlobalLoading(false);
      diagnostics.error('应用初始化', error.toString());
    }
  }

  Future<void> _resumeApp() async {
    if (_nasSnapshot != null) {
      final snapshot = await probeNasGatewayStartup();
      if (!mounted) return;
      if (snapshot != null) {
        setState(() => _nasSnapshot = snapshot);
        connection.update(nasMqtt: true);
      } else {
        connection.update(nasMqtt: false);
      }
      return;
    }
    await controller.openApp();
  }

  /// 取消启动时的自动重连：收起遮罩、中止本次尝试，并**立即切到离线视图**。
  /// 只停连接是不够的——缓存要等后台 openApp() 跑完才加载，
  /// 用户会看到一个空页面等几十秒，误以为离线数据丢了。
  Future<void> _cancelGlobalConnect() async {
    _setGlobalLoading(false);
    try {
      await controller.ble.stopScan();
      await controller.ble.disconnect();
    } catch (error) {
      diagnostics.info('连接取消', '取消自动连接时出错：$error');
    }
    await controller.enterOfflineViewing();
    connection.update(nasMqtt: _nasSnapshot != null, connecting: false);
  }

  /// 后台连接：只收起遮罩，连接流程继续跑，用户可以立即操作界面。
  void _sendConnectToBackground() {
    _setGlobalLoading(false);
    diagnostics.info('连接后台', '用户选择后台连接，继续在后台尝试');
  }

  void _showChannelSwitchToast(String message) {
    _channelSwitchNotice.value = (++_channelSwitchNoticeId, message);
  }

  Future<void> _openNasMqttSetup() async {
    // 设置页可能重绑设备并更换 token；旧快照不能用于返回后的 MQTT 切换。
    _nasSnapshot = null;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    final switchToMqtt = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => WifiBindingAndNasPage(
          ble: controller.ble,
          initialBinding: controller.activeBinding,
          onSwitchToNasMqtt: _switchToNasMqtt,
          onOpenWifiProvisioning: () {
            final currentNavigator = _navigatorKey.currentState;
            if (currentNavigator == null) return;
            unawaited(currentNavigator
                .push<bool>(MaterialPageRoute(
              builder: (_) => WifiProvisioningPage(ble: controller.ble),
            ))
                .then((shouldSwitch) {
              if (shouldSwitch == true && currentNavigator.canPop()) {
                currentNavigator.pop(true);
              }
            }));
          },
        ),
      ),
    );
    if (switchToMqtt == true && mounted) await _switchToNasMqtt();
  }

  Future<void> _showNasMqttNotice(
    String message, {
    bool offerSetup = false,
  }) async {
    // 切换入口会先显示全局等待遮罩；先收起遮罩，确保弹窗按钮可点击。
    _setGlobalLoading(false);
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final openSetup = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('NAS MQTT 尚不可用'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('继续使用蓝牙'),
              ),
              if (offerSetup)
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('去设备网络与 NAS 控制'),
                )
              else
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('知道了'),
                ),
            ],
          ),
        ) ??
        false;
    if (openSetup && mounted) await _openNasMqttSetup();
  }

  bool _hasFreshNasState(NasGatewaySnapshot snapshot) =>
      snapshot.status['stale'] == false &&
      snapshot.status['stateFreshness'] == 'fresh';

  Future<void> _switchToNasMqtt() async {
    // NAS 控制切换属于通道切换，不能跳到 WiFi 配网/网关管理页。
    // 每次读取最新绑定并做只读探测；失败时保留当前蓝牙控制。
    _switchingToNasMqtt = true;
    controller.clearError();
    _setGlobalLoading(true, label: '正在切换 NAS MQTT…');
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      var waitingForLease = false;
      while (mounted) {
        Object? probeError;
        // 每次手动切换都从安全存储读取最新绑定。扫码/重新授权会轮换 token，
        // 主页缓存可能仍指向旧 token，不能拿它作为切换依据。
        final snapshot = await probeNasGatewayStartup(
            onError: (error) => probeError = error);
        if (snapshot == null) {
          var hasActiveBinding = false;
          try {
            hasActiveBinding = (await WifiBindingStore().load())
                .any((binding) => binding.state == 'active');
          } catch (_) {}
          final failure = probeError;
          final busy =
              failure is NasGatewayException && failure.code == 'WIFI_IN_USE';
          if (busy && hasActiveBinding && DateTime.now().isBefore(deadline)) {
            if (!waitingForLease) {
              waitingForLease = true;
              _setGlobalLoading(true, label: '等待另一台手机释放 NAS MQTT 控制权…');
            }
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          if (failure != null) {
            diagnostics.warning('NAS MQTT 切换', '网关状态探测失败：$failure');
          }
          if (failure is NasGatewayException) {
            final code = failure.code;
            if (code == 'WIFI_IN_USE') {
              await _showNasMqttNotice('NAS MQTT 控制权正被另一台手机占用，请释放控制权或稍后重试。');
            } else if (code == 'OTA_BUSY') {
              await _showNasMqttNotice('设备正在升级，升级完成后再切换 NAS MQTT 控制。');
            } else if (failure.message.contains('Connection refused') ||
                failure.message.contains('SocketException')) {
              await _showNasMqttNotice(
                'NAS 网关或设备 MQTT 当前不可达。本次仍保持蓝牙控制；可检查设备网络、MQTT 账号和 NAS 网关配置。',
                offerSetup: true,
              );
            } else {
              await _showNasMqttNotice(
                '${failure.message}。本次仍保持蓝牙控制，可检查或重新配置 NAS MQTT。',
                offerSetup: true,
              );
            }
            return;
          }
          if (!hasActiveBinding) {
            // 新安装或本机凭据被清除时，切换入口直接带用户进入扫码/绑定流程，
            // 避免只弹一条提示后仍停留在无法使用的 MQTT 控制状态。
            _setGlobalLoading(false);
            await _showNasMqttNotice(
              '此 App 尚无可用的设备绑定或 NAS 配置。本次仍保持蓝牙控制；扫码导入 NAS 配置后，按页面提示完成设备绑定和 MQTT 设置。',
              offerSetup: true,
            );
            return;
          }
          await _showNasMqttNotice(
            'NAS 未返回设备的实时 MQTT 状态。本次仍保持蓝牙控制；请检查设备 WiFi、Broker 账号和 NAS 网关。',
            offerSetup: true,
          );
          return;
        }
        if (!_hasFreshNasState(snapshot)) {
          await _showNasMqttNotice(
            'NAS 返回的是缓存或过期状态，无法确认设备当前在线。本次仍保持蓝牙控制；请检查设备 MQTT 配置和连接。',
            offerSetup: true,
          );
          return;
        }
        try {
          await controller.activateNasMqtt(snapshot.binding);
        } on NasGatewayException catch (error) {
          if (error.code == 'WIFI_IN_USE' &&
              DateTime.now().isBefore(deadline)) {
            if (!waitingForLease) {
              waitingForLease = true;
              _setGlobalLoading(true, label: '等待另一台手机释放 NAS MQTT 控制权…');
            }
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          if (error.code == 'WIFI_IN_USE') {
            await _showNasMqttNotice('NAS MQTT 控制权正被另一台手机占用，请释放控制权或稍后重试。');
          } else if (error.code == 'OTA_BUSY') {
            await _showNasMqttNotice('设备正在升级，升级完成后再切换 NAS MQTT 控制。');
          } else {
            await _showNasMqttNotice(
              '${error.message}。本次仍保持蓝牙控制，可检查或重新配置 NAS MQTT。',
              offerSetup: true,
            );
          }
          return;
        } catch (error) {
          await _showNasMqttNotice(
            'NAS MQTT 初始化失败：$error。本次仍保持蓝牙控制，可检查或重新配置 NAS MQTT。',
            offerSetup: true,
          );
          return;
        }
        _manualBle = false;
        _bluetoothSwitchCompleted = false;
        _stopNasRetry();
        if (!mounted) return;
        setState(() {
          _nasSnapshot = snapshot;
          _useNasMqtt = true;
          _nasMqttControllerActive = true;
        });
        _syncBlePreScan(immediate: true);
        connection.update(nasMqtt: true, preferBle: false);
        final nav = _navigatorKey.currentState;
        if (nav != null && nav.canPop()) {
          nav.popUntil((route) => route.isFirst);
        }
        _showChannelSwitchToast('已切换到 NAS MQTT 控制');
        diagnostics.info('NAS MQTT 切换', '已从蓝牙切回 NAS MQTT 控制');
        return;
      }
    } catch (error) {
      diagnostics.warning('NAS MQTT 切换', '切回 NAS MQTT 失败：$error');
      if (mounted) {
        await _showNasMqttNotice(
          'NAS MQTT 初始化失败：$error。本次仍保持蓝牙控制，可检查或重新配置 NAS MQTT。',
          offerSetup: true,
        );
      }
    } finally {
      _switchingToNasMqtt = false;
      _setGlobalLoading(false);
    }
  }

  Future<void> _connectBluetooth() async {
    _manualBle = true;
    _bluetoothSwitchCompleted = false;
    var waitingForSelection = false;
    try {
      await _stopBlePreScan();
      _setGlobalLoading(true, label: '正在连接蓝牙…');
      _stopNasRetry();
      connection.update(
        nasMqtt: controller.nasMqttActive,
        ble: controller.ble.isConnected,
        connecting: true,
        preferBle: true,
      );
      // 扫描/连接弹窗自己负责进度；先收起全局遮罩，避免两个 Loading 叠加，
      // 也避免关闭扫描弹窗后遮罩仍拦截点击。
      _setGlobalLoading(false);
      await controller.openApp(scanIfNeeded: false);
      final candidates = controller.ble.freshScanResults();
      if (candidates.length == 1) {
        diagnostics.info(
          '蓝牙快速连接',
          '预扫描只发现一台近期设备，跳过设备选择面板',
        );
        try {
          await controller.connect(candidates.single.device);
        } catch (error) {
          diagnostics.warning('蓝牙快速连接', '直连失败，回退到手动扫描：$error');
          if (mounted) {
            await controller.scan();
            waitingForSelection = true;
          }
        }
      } else {
        diagnostics.info(
          '蓝牙快速连接',
          candidates.isEmpty
              ? '没有近期扫描结果，开始常规扫描'
              : '发现 ${candidates.length} 台设备，保留常规设备选择流程',
        );
        if (mounted) {
          await controller.scan();
          waitingForSelection = true;
        }
      }
    } catch (error) {
      diagnostics.error('连接蓝牙', error.toString());
    } finally {
      _setGlobalLoading(false);
      if (_manualBle && !controller.bluetoothControlReady) {
        if (waitingForSelection) {
          // scan() 只启动扫描便会返回；保持切换意图，直到用户选设备或关闭面板。
          connection.update(
            nasMqtt: controller.nasMqttActive,
            ble: controller.ble.isConnected,
            connecting: controller.bluetoothBootstrapInProgress,
            preferBle: true,
          );
        } else {
          _cancelBluetoothSwitch();
        }
      } else if (_manualBle && controller.bluetoothControlReady) {
        // 防止 BLE 初始化完成通知与页面切换状态通知交错时漏掉最终收尾。
        unawaited(_finishBluetoothSwitch());
      }
    }
  }

  void _cancelBluetoothSwitch() {
    if (!_manualBle || controller.bluetoothControlReady) return;
    _manualBle = false;
    _bluetoothSwitchCompleted = false;
    if (controller.nasMqttActive) {
      if (mounted) {
        setState(() {
          _useNasMqtt = true;
          _nasMqttControllerActive = true;
        });
      }
      connection.update(
          nasMqtt: true, ble: false, connecting: false, preferBle: false);
      _syncBlePreScan(immediate: true);
    } else {
      connection.update(
        ble: controller.ble.isConnected,
        connecting: controller.bluetoothBootstrapInProgress,
      );
    }
  }

  Future<void> _finishBluetoothSwitch() {
    final pending = _bluetoothSwitchCompletion;
    if (pending != null) return pending;
    if (_bluetoothSwitchFinalizing ||
        _bluetoothSwitchCompleted ||
        !_manualBle ||
        !controller.bluetoothControlReady) {
      return Future<void>.value();
    }
    _bluetoothSwitchFinalizing = true;
    final future = _finishBluetoothSwitchUnlocked();
    _bluetoothSwitchCompletion = future;
    return future.whenComplete(() {
      if (identical(_bluetoothSwitchCompletion, future)) {
        _bluetoothSwitchCompletion = null;
      }
      _bluetoothSwitchFinalizing = false;
    });
  }

  Future<void> _finishBluetoothSwitchUnlocked() async {
    try {
      if (!mounted || !_manualBle || !controller.bluetoothControlReady) return;
      // BLE 已完成控制初始化，缓存映射与 MQTT 租约释放在后台收尾，
      // 不让非必要 NAS 往返延迟切换完成提示。
      unawaited(controller.prepareBluetoothStatisticsCacheScope());
      unawaited(controller.releaseNasMqttLease());
      controller.deactivateNasMqtt();
      _bluetoothSwitchCompleted = true;
      setState(() {
        _useNasMqtt = false;
        _nasMqttControllerActive = false;
      });
      _syncBlePreScan();
      connection.update(
        nasMqtt: false,
        ble: true,
        connecting: false,
        preferBle: true,
      );
      _showChannelSwitchToast('已切换到蓝牙控制');
      diagnostics.info('蓝牙切换', 'BLE 控制初始化完成后切断 NAS MQTT');
    } catch (error) {
      diagnostics.warning('蓝牙切换', '通道收尾失败：$error');
      rethrow;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.setAppForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _appForeground = false;
      unawaited(_stopBlePreScan());
      diagnostics.info('应用生命周期', 'App 进入后台，开始蓝牙宽限期');
      _bleLifecycle.onBackground();
    } else if (state == AppLifecycleState.resumed) {
      _appForeground = true;
      _syncBlePreScan(immediate: true);
      diagnostics.info('应用生命周期', 'App 回到前台');
      unawaited(_bleLifecycle.onForeground());
    } else if (state == AppLifecycleState.detached) {
      diagnostics.info('应用生命周期', 'App 正在关闭，释放 NAS MQTT 控制租约和蓝牙会话');
      unawaited(controller.releaseNasMqttLease());
      unawaited(_bleLifecycle.closeImmediately());
    }
  }

  @override
  void dispose() {
    _stopNasRetry();
    _blePreScanTimer?.cancel();
    _blePreScanTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    FlutterError.onError = _previousFlutterErrorHandler;
    PlatformDispatcher.instance.onError = _previousPlatformErrorHandler;
    _bleLifecycle.dispose();
    // 尽力在进程退出前释放 NAS MQTT 控制租约；强制杀进程时仍依赖固件 TTL 兜底。
    unawaited(controller.releaseNasMqttLease());
    controller.removeListener(_syncConnection);
    controller.dispose();
    diagnostics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: AppIdentity.productName,
        debugShowCheckedModeBanner: false,
        theme: buildMimiVentTheme()
            .copyWith(scaffoldBackgroundColor: Colors.transparent),
        // 日期滚轮需要中文年月日；缺 delegate 时会退回英文月份。
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        locale: const Locale('zh', 'CN'),
        navigatorKey: _navigatorKey,
        home: DashboardPage(
          controller: controller,
          diagnostics: diagnostics,
          connection: connection,
          channelSwitchNotice: _channelSwitchNotice,
          onConnectBluetooth: _connectBluetooth,
          onBluetoothConnectCancelled: _cancelBluetoothSwitch,
          onBluetoothConnected: _finishBluetoothSwitch,
          onSwitchToNasMqtt: _switchToNasMqtt,
          globalLoadingLabel: _globalLoading ? _globalLoadingLabel : null,
          onCancelGlobalLoading: _cancelGlobalConnect,
          onBackgroundConnect: _sendConnectToBackground,
        ),
      );
}
