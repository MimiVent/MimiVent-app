import 'dart:async';
import 'dart:math';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app_identity.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../ble/mimivent_ble_manager.dart';
import '../data/background_ble_lifecycle.dart';
import '../data/device_connection_manager.dart';
import '../data/mimivent_controller.dart';
import '../features/dashboard/presentation/dashboard_page.dart';
import '../features/wifi_control/wifi_control_page.dart';
import '../features/wifi_control/wifi_binding_store.dart';
import '../features/wifi_control/wifi_read_transport.dart';
import '../features/wifi_control/wifi_startup_probe.dart';
import 'theme/mimivent_theme.dart';
import '../shared/widgets/top_toast.dart';

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
  WifiStartupSnapshot? _wifiSnapshot;
  bool _useWifi = false;
  bool _wifiControllerActive = false;
  bool _manualBle = false;
  DateTime? _busyFallbackAt;
  Timer? _wifiRetryTimer;
  int _wifiRetryAttempts = 0;
  bool _wifiRetryInFlight = false;
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

  void _stopWifiRetry() {
    _wifiRetryTimer?.cancel();
    _wifiRetryTimer = null;
    _wifiRetryAttempts = 0;
  }

  void _startWifiRetry() {
    if (_manualBle || controller.wifiBusy) return;
    _stopWifiRetry();
    _scheduleWifiRetry();
  }

  void _scheduleWifiRetry() {
    final jitter = 4500 + Random().nextInt(2500);
    _wifiRetryTimer = Timer(Duration(milliseconds: jitter), () {
      unawaited(_tryWifiReconnect());
      if (_wifiRetryTimer != null && !_manualBle) {
        _scheduleWifiRetry();
      }
    });
  }

  Future<void> _tryWifiReconnect() async {
    if (!mounted || _wifiRetryInFlight || _manualBle || controller.wifiBusy)
      return;
    if (_wifiRetryAttempts >= 12) {
      _stopWifiRetry();
      return;
    }
    _wifiRetryAttempts++;
    _wifiRetryInFlight = true;
    try {
      final snapshot = await probeWifiStartup();
      if (snapshot == null || !mounted || _manualBle) return;
      await controller.activateWifi(snapshot.binding);
      if (!mounted || _manualBle) return;
      _stopWifiRetry();
      setState(() {
        _wifiSnapshot = snapshot;
        _useWifi = true;
        _wifiControllerActive = true;
      });
      connection.update(wifi: true, preferBle: false);
      final nav = _navigatorKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.popUntil((route) => route.isFirst);
      }
      diagnostics.info('WiFi 重连', '设备 WiFi 已恢复，切回 WiFi 控制');
    } catch (error) {
      diagnostics.warning('WiFi 重连', '重试 ${_wifiRetryAttempts} 失败：$error');
    } finally {
      _wifiRetryInFlight = false;
    }
  }

  void _syncConnection() {
    final ble = controller.ble.isConnected;
    if (!controller.wifiBusy) _busyFallbackAt = null;
    if (controller.wifiBusy) {
      if (mounted) {
        setState(() {
          _useWifi = false;
          _wifiControllerActive = false;
        });
      }
      _manualBle = true;
      connection.update(
          wifi: false, ble: ble, connecting: false, preferBle: true);
      final now = DateTime.now();
      if (!ble &&
          (_busyFallbackAt == null ||
              now.difference(_busyFallbackAt!) > const Duration(seconds: 15))) {
        _busyFallbackAt = now;
        unawaited(_connectBluetooth());
      }
      return;
    }
    // 用户从 WiFi 主动切到蓝牙：BLE 一旦连上就立即切换控制通道，
    // 不再要求再点一次“蓝牙控制”。
    if (ble && _manualBle) {
      if (controller.wifiActive) controller.deactivateWifi();
      if (mounted && (_useWifi || _wifiControllerActive)) {
        setState(() {
          _useWifi = false;
          _wifiControllerActive = false;
        });
      }
      connection.update(
        wifi: false,
        ble: true,
        connecting: false,
        preferBle: true,
      );
      return;
    }
    connection.update(
      ble: ble,
      connecting:
          controller.ble.connectionStatus == BleConnectionStatus.connecting,
    );
    if (controller.wifiActive) {
      connection.update(wifi: true, preferBle: false);
    } else if (controller.wifiLost && _wifiControllerActive) {
      setState(() {
        _useWifi = false;
        _wifiControllerActive = false;
      });
      connection.update(wifi: false, ble: false, preferBle: false);
      _startWifiRetry();
    }
    if (!ble &&
        _wifiSnapshot != null &&
        !_useWifi &&
        !_manualBle &&
        !controller.wifiLost &&
        !controller.wifiBusy &&
        mounted) {
      setState(() => _useWifi = true);
      connection.update(wifi: true, preferBle: false);
      final binding = _wifiSnapshot!.binding;
      unawaited(controller.activateWifi(binding).then((_) {
        if (mounted) setState(() => _wifiControllerActive = true);
      }).catchError((Object error) {
        if (mounted) setState(() => _wifiControllerActive = false);
      }));
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
      final snapshot = await probeWifiStartup();
      if (!mounted) return;
      if (snapshot != null) {
        var active = false;
        try {
          await controller.activateWifi(snapshot.binding);
          active = true;
        } catch (error) {
          diagnostics.warning('WiFi 控制', '启动 WiFi 控制失败：$error');
        }
        if (!mounted) return;
        setState(() {
          _wifiSnapshot = snapshot;
          _useWifi = true;
          _wifiControllerActive = active;
        });
        _manualBle = false;
        _stopWifiRetry();
        connection.update(wifi: true, connecting: false, preferBle: false);
        if (active) {
          _setGlobalLoading(false);
        } else {
          _setGlobalLoading(false);
          await _connectBluetooth();
        }
        diagnostics.info(
            '应用启动', active ? '已有 WiFi 绑定，进入 WiFi 控制' : 'WiFi 只读，进入降级页面');
        return;
      }
      connection.update(wifi: false);
      _startWifiRetry();
      // 给刚重启的设备 WiFi 一个 6 秒窗口，避免一启动就弹蓝牙扫描/权限。
      await Future<void>.delayed(const Duration(seconds: 6));
      if (!mounted || _wifiControllerActive || _manualBle) return;
      final late = await probeWifiStartup();
      if (late != null && mounted && !_manualBle) {
        await controller.activateWifi(late.binding);
        if (!mounted || _manualBle) return;
        _stopWifiRetry();
        setState(() {
          _wifiSnapshot = late;
          _useWifi = true;
          _wifiControllerActive = true;
        });
        connection.update(wifi: true, preferBle: false);
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
    if (_wifiSnapshot != null) {
      final snapshot = await probeWifiStartup();
      if (!mounted) return;
      if (snapshot != null) {
        setState(() => _wifiSnapshot = snapshot);
        connection.update(wifi: true);
      } else {
        connection.update(wifi: false);
      }
      return;
    }
    await controller.openApp();
  }

  void _showChannelMessage(String text) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    TopToast.show(context, text);
  }

  Future<void> _openWifiControl() async {
    if (!mounted) return;
    await _navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => WifiControlPage(ble: controller.ble),
    ));
  }

  Future<void> _switchToWifi() async {
    _setGlobalLoading(true, label: '正在切换 WiFi…');
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      var waitingForLease = false;
      while (mounted) {
        Object? probeError;
        final snapshot = _wifiSnapshot ??
            await probeWifiStartup(onError: (error) => probeError = error);
        if (snapshot == null) {
          var hasActiveBinding = false;
          try {
            hasActiveBinding = (await WifiBindingStore().load())
                .any((binding) => binding.state == 'active');
          } catch (_) {}
          final failure = probeError;
          final busy =
              failure is WifiReadException && failure.code == 'WIFI_IN_USE';
          if (busy && hasActiveBinding && DateTime.now().isBefore(deadline)) {
            if (!waitingForLease) {
              waitingForLease = true;
              _setGlobalLoading(true, label: '等待另一台手机释放 WiFi…');
            }
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          if (failure != null) {
            diagnostics.warning('WiFi 切换', '探测失败：$failure');
          }
          if (failure is WifiReadException) {
            final code = failure.code;
            if (code == 'BINDING_INVALID' || code == 'AUTH_REQUIRED') {
              _showChannelMessage('本机 WiFi 绑定已失效，请通过蓝牙重新绑定本机');
            } else if (code == 'PERMISSION_DENIED') {
              _showChannelMessage('设备拒绝了本机 WiFi 绑定，请通过蓝牙重新绑定');
            } else if (code == 'WIFI_IN_USE') {
              _showChannelMessage('WiFi 仍被另一台手机占用，请继续使用蓝牙或稍后重试');
            } else if (code == 'OTA_BUSY') {
              _showChannelMessage('设备正在升级，暂时不能切换 WiFi');
            } else {
              _showChannelMessage('WiFi 连接失败：${failure.message}');
            }
            return;
          }
          _showChannelMessage(hasActiveBinding
              ? 'WiFi 连接失败，请检查本机 WiFi 绑定或重新绑定'
              : '没有可用的 WiFi 绑定，请先通过蓝牙完成配网并绑定本机');
          return;
        }
        _manualBle = false;
        _stopWifiRetry();
        try {
          await controller.activateWifi(snapshot.binding);
        } on WifiReadException catch (error) {
          if (error.code == 'WIFI_IN_USE' &&
              DateTime.now().isBefore(deadline)) {
            if (!waitingForLease) {
              waitingForLease = true;
              _setGlobalLoading(true, label: '等待另一台手机释放 WiFi…');
            }
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          if (error.code == 'WIFI_IN_USE') {
            _showChannelMessage('WiFi 仍被另一台手机占用，请继续使用蓝牙或稍后重试');
            return;
          }
          if (error.code == 'BINDING_INVALID' ||
              error.code == 'AUTH_REQUIRED') {
            _showChannelMessage('本机 WiFi 绑定已失效，请通过蓝牙重新绑定本机');
            return;
          }
          if (error.code == 'PERMISSION_DENIED') {
            _showChannelMessage('设备拒绝了本机 WiFi 绑定，请通过蓝牙重新绑定');
            return;
          }
          if (error.code == 'OTA_BUSY') {
            _showChannelMessage('设备正在升级，暂时不能切换 WiFi');
            return;
          }
          _showChannelMessage('WiFi 连接失败：${error.message}');
          return;
        }
        if (!mounted) return;
        setState(() {
          _wifiSnapshot = snapshot;
          _useWifi = true;
          _wifiControllerActive = true;
        });
        connection.update(wifi: true, preferBle: false);
        final nav = _navigatorKey.currentState;
        if (nav != null && nav.canPop()) {
          nav.popUntil((route) => route.isFirst);
        }
        diagnostics.info('WiFi 切换', '已从蓝牙切回 WiFi 控制');
        return;
      }
    } catch (error) {
      diagnostics.warning('WiFi 切换', '切回 WiFi 失败：$error');
    } finally {
      _setGlobalLoading(false);
    }
  }

  Future<void> _connectBluetooth() async {
    _manualBle = true;
    _setGlobalLoading(true, label: '正在连接蓝牙…');
    _stopWifiRetry();
    await controller.releaseWifiLease();
    controller.deactivateWifi();
    setState(() {
      _useWifi = false;
      _wifiControllerActive = false;
    });
    connection.update(
        wifi: _wifiSnapshot != null, connecting: true, preferBle: true);
    // 扫描/连接弹窗自己负责进度；先收起全局遮罩，避免两个 Loading 叠加，
    // 也避免关闭扫描弹窗后遮罩仍拦截点击。
    _setGlobalLoading(false);
    try {
      await controller.openApp();
    } catch (error) {
      diagnostics.error('连接蓝牙', error.toString());
    } finally {
      _setGlobalLoading(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.setAppForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      diagnostics.info('应用生命周期', 'App 进入后台，开始蓝牙宽限期');
      _bleLifecycle.onBackground();
    } else if (state == AppLifecycleState.resumed) {
      diagnostics.info('应用生命周期', 'App 回到前台');
      unawaited(_bleLifecycle.onForeground());
    } else if (state == AppLifecycleState.detached) {
      diagnostics.info('应用生命周期', 'App 正在关闭，释放 WiFi 租约和蓝牙会话');
      unawaited(controller.releaseWifiLease());
      unawaited(_bleLifecycle.closeImmediately());
    }
  }

  @override
  void dispose() {
    _stopWifiRetry();
    WidgetsBinding.instance.removeObserver(this);
    FlutterError.onError = _previousFlutterErrorHandler;
    PlatformDispatcher.instance.onError = _previousPlatformErrorHandler;
    _bleLifecycle.dispose();
    // 尽力在进程退出前释放 WiFi 租约；强制杀进程时仍依赖固件 TTL 兜底。
    unawaited(controller.releaseWifiLease());
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
        navigatorKey: _navigatorKey,
        home: DashboardPage(
          controller: controller,
          diagnostics: diagnostics,
          connection: connection,
          onConnectBluetooth: _connectBluetooth,
          onSwitchToWifi: _switchToWifi,
          globalLoadingLabel: _globalLoading ? _globalLoadingLabel : null,
        ),
      );
}
