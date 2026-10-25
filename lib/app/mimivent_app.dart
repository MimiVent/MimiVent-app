import 'dart:async';

import 'package:flutter/material.dart';

import 'app_identity.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../data/background_ble_lifecycle.dart';
import '../data/mimivent_controller.dart';
import '../features/dashboard/presentation/dashboard_page.dart';
import 'theme/mimivent_theme.dart';

class MimiVentApp extends StatefulWidget {
  const MimiVentApp({super.key});

  @override
  State<MimiVentApp> createState() => _MimiVentAppState();
}

class _MimiVentAppState extends State<MimiVentApp> with WidgetsBindingObserver {
  late final MimiVentController controller;
  late final AppDiagnosticsLog diagnostics;
  late final BackgroundBleLifecycle _bleLifecycle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    diagnostics = AppDiagnosticsLog();
    controller = MimiVentController(diagnostics: diagnostics);
    _bleLifecycle = BackgroundBleLifecycle(
      closeSession: controller.closeBluetoothSession,
      resumeSession: controller.openApp,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initializeApp());
    });
  }

  Future<void> _initializeApp() async {
    await diagnostics.initialize();
    diagnostics.info('应用', 'MimiVent App 已启动');
    if (!mounted) return;
    try {
      await controller.openApp();
    } catch (error) {
      diagnostics.error('应用初始化', error.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      diagnostics.info('应用生命周期', 'App 进入后台，开始蓝牙宽限期');
      _bleLifecycle.onBackground();
    } else if (state == AppLifecycleState.resumed) {
      diagnostics.info('应用生命周期', 'App 回到前台');
      unawaited(_bleLifecycle.onForeground());
    } else if (state == AppLifecycleState.detached) {
      diagnostics.info('应用生命周期', 'App 正在关闭，释放蓝牙会话');
      unawaited(_bleLifecycle.closeImmediately());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bleLifecycle.dispose();
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
        home: DashboardPage(controller: controller, diagnostics: diagnostics),
      );
}
