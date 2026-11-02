import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show ScanResult;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/app_identity.dart';
import '../../../ble/mimivent_ble_manager.dart';
import '../../../core/diagnostics/app_diagnostics_log.dart';
import '../../../core/formatting/duration_formatter.dart';
import '../../../core/layout/app_layout.dart';
import '../../../data/mimivent_controller.dart';
import '../../../data/models.dart';
import '../../control/device_status_presenter.dart';
import '../../../app/theme/mimivent_theme.dart';
import '../../../shared/presentation/mimi_vent_dialogs.dart';
import '../../../shared/presentation/modal_coordinator.dart';
import '../../../shared/widgets/device_animations.dart';
import '../../../shared/widgets/ble_signal_indicator.dart';
import '../../connection/connection_presentation.dart';
import '../../../data/device_connection_manager.dart';
import '../../connection/connection_status_badge.dart';
import '../../control/control_operation.dart';
import '../../diagnostics/diagnostics_page.dart';
import '../../statistics/presentation/statistics_page.dart';
import '../../firmware_update/firmware_update_page.dart';
import '../../wifi_provisioning/wifi_provisioning_page.dart';
import '../../../shared/widgets/version_compatibility_notice.dart';

part 'dashboard_connection.part.dart';
part 'dashboard_actions.part.dart';
part 'dashboard_sections.part.dart';
part 'dashboard_status_cards.part.dart';

enum _TopBarMenuAction {
  diagnostics,
  wifiProvisioning,
  firmwareUpdate,
  connectDevice,
  connectBluetooth,
  switchToWifi,
  offline,
  closeApp
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    required this.controller,
    required this.diagnostics,
    this.connection,
    this.onConnectBluetooth,
    this.onSwitchToWifi,
    this.globalLoadingLabel,
    super.key,
  });

  final MimiVentController controller;
  final AppDiagnosticsLog diagnostics;
  final DeviceConnectionManager? connection;
  final Future<void> Function()? onConnectBluetooth;
  final Future<void> Function()? onSwitchToWifi;
  final String? globalLoadingLabel;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final ModalCoordinator _modalCoordinator = ModalCoordinator();
  MimiVentController get c => widget.controller;
  bool get _deviceReady =>
      c.connected &&
      !c.offlineViewing &&
      !c.deviceOtaBusy &&
      c.appVersionCompatible &&
      c.status != null &&
      c.settings != null;
  int _selectedTab = 0;
  int get _activeTab => _selectedTab < 3 ? _selectedTab : 0;
  double _headerCollapse = 0;
  bool _scanSheetOpen = false;
  bool _scanSheetDismissedDuringScan = false;
  bool _connectionRevealActive = false;
  bool _deviceConnectActionBusy = false;
  String? _connectionActionError;
  bool _reconnectInProgress = false;
  bool _wifiPromptHandled = false;
  bool _wifiPromptShowing = false;
  String _appVersion = '读取中';
  String _appBuildNumber = '';

  @override
  void initState() {
    super.initState();
    c.addListener(_syncDeviceUi);
    // 路由依赖在首帧之后读取，避免 initState 中访问 ModalRoute 的继承状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncDeviceUi();
    });
    // 从安装包元数据读取 App 版本，避免页面版本和 pubspec.yaml 不一致。
    unawaited(_loadAppVersion());
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncDeviceUi);
      widget.controller.addListener(_syncDeviceUi);
      _syncDeviceUi();
    }
  }

  @override
  void dispose() {
    c.removeListener(_syncDeviceUi);
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return false;
    }
    // 顶栏只跟随当前主页面的纵向滚动；快捷操作横向滑动不改变标题动画。
    if (notification.metrics.axis != Axis.vertical || notification.depth != 0) {
      return false;
    }
    // 顶栏直接跟随滚动偏移连续收缩，并在前 72 px 内完成；不等卡片被
    // 遮挡后才切换，也不通过裁切文字制造半个字的中间态。
    final next = (notification.metrics.pixels / 72).clamp(0.0, 1.0);
    if ((next - _headerCollapse).abs() > .005 && mounted) {
      setState(() => _headerCollapse = next);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          final page = Scaffold(
            body: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: MimiVentColors.pageGradient,
              ),
              child: Stack(children: [
                const Positioned(
                  top: -130,
                  right: -100,
                  child: AmbientGlow(),
                ),
                SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: Column(children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                              18, 5, 18, 5 + (1 - _headerCollapse) * 4),
                          child: _topBar(_headerCollapse),
                        ),
                        if (c.offlineViewing || !c.connected)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                            child: _connectionStatusBanner(),
                          ),
                        if (c.lastError != null &&
                            c.connected &&
                            !c.offlineViewing)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                            child: _connectionErrorBanner(),
                          ),
                        if (c.wifiGattCacheStale)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(18, 4, 18, 0),
                            child: Card(
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: Text(
                                  '设备支持 WiFi 配网，但手机未发现新增蓝牙服务。请在系统蓝牙中取消 MimiVent 配对后重新连接；若仍未恢复，再清除系统蓝牙缓存。',
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _handleScrollNotification,
                            child: _tabBody(),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
            bottomNavigationBar: _bottomBar(),
          );
          final content = Stack(fit: StackFit.expand, children: [
            page,
            if (c.pendingWifiAction != null ||
                widget.globalLoadingLabel != null)
              Positioned.fill(
                child: Stack(children: [
                  const ModalBarrier(
                      dismissible: false, color: Color(0x99000000)),
                  Center(
                    child: Material(
                      color: MimiVentColors.surfaceRaised,
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 22),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.6,
                                  color: MimiVentColors.mint)),
                          const SizedBox(height: 14),
                          Text(
                              c.pendingWifiAction != null
                                  ? '正在执行：${c.pendingWifiAction}'
                                  : widget.globalLoadingLabel!,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
          ]);
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _connectionRevealActive ? 3.2 : 0),
            duration: _connectionRevealActive
                ? const Duration(milliseconds: 180)
                : const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
            child: content,
            builder: (context, blur, child) => ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: child,
            ),
          );
        },
      );

  Widget _topBar(double collapse) {
    final online = c.connected;
    final isRunning = !c.offlineViewing && (c.status?.fan ?? false);
    final logoSize = 42 - 14 * collapse;
    return SizedBox(
      height: 54 - 10 * collapse,
      child: Row(children: [
        RunningLogoGlow(
          isRunning: isRunning,
          size: logoSize,
          radius: 14 - 2 * collapse,
          glowEnabled: false,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      style: TextStyle(
                        color: isRunning ? MimiVentColors.amber : Colors.white,
                        fontSize: 22 - 6 * collapse,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4,
                      ),
                      child: const Text(AppIdentity.productName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SizeTransition(
                        axis: Axis.horizontal,
                        sizeFactor: animation,
                        child: child,
                      ),
                    ),
                    child: isRunning
                        ? Padding(
                            key: const ValueKey('running-badge'),
                            padding: const EdgeInsets.only(left: 7),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3 - collapse,
                              ),
                              decoration: BoxDecoration(
                                color: MimiVentColors.amber.withOpacity(.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color:
                                        MimiVentColors.amber.withOpacity(.3)),
                              ),
                              child: Text(
                                '运行中',
                                style: TextStyle(
                                  color: MimiVentColors.amber,
                                  fontSize: 10 - 1.5 * collapse,
                                  fontWeight: FontWeight.w700,
                                  height: 1,
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('idle-badge'),
                          ),
                  ),
                ],
              ),
              Text(
                AppIdentity.productSubtitle,
                style: TextStyle(
                  color: MimiVentColors.muted,
                  fontSize: 12 - 2 * collapse,
                  height: 1.05,
                ),
              ),
            ],
          ),
        ),
        if (widget.connection != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ConnectionStatusBadge(
              connection: widget.connection!,
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('连接状态'),
                  content: Text(widget.connection!.detail),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'))
                  ],
                ),
              ),
            ),
          ),
        PopupMenuButton<_TopBarMenuAction>(
          tooltip: '更多操作',
          position: PopupMenuPosition.under,
          color: MimiVentColors.surfaceRaised,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          constraints: const BoxConstraints(minWidth: 196),
          onSelected: (action) {
            switch (action) {
              case _TopBarMenuAction.diagnostics:
                _openDiagnostics();
              case _TopBarMenuAction.wifiProvisioning:
                _openWifiProvisioning();
              case _TopBarMenuAction.firmwareUpdate:
                _openFirmwareUpdate();
              case _TopBarMenuAction.connectDevice:
                _leaveOfflineAndConnect();
              case _TopBarMenuAction.connectBluetooth:
                widget.onConnectBluetooth?.call();
              case _TopBarMenuAction.switchToWifi:
                widget.onSwitchToWifi?.call();
              case _TopBarMenuAction.offline:
                _enterOfflineViewing();
              case _TopBarMenuAction.closeApp:
                _disconnectAndExit();
            }
          },
          itemBuilder: (context) => [
            if (widget.onSwitchToWifi != null &&
                (widget.connection?.channel == DeviceChannel.ble ||
                    !c.wifiActive))
              const PopupMenuItem(
                value: _TopBarMenuAction.switchToWifi,
                child: Row(children: [
                  Icon(Icons.wifi_rounded,
                      color: MimiVentColors.mint, size: 19),
                  SizedBox(width: 11),
                  Text('切换回 WiFi 控制'),
                ]),
              ),
            if (c.wifiActive && widget.onConnectBluetooth != null)
              const PopupMenuItem(
                value: _TopBarMenuAction.connectBluetooth,
                child: Row(children: [
                  Icon(Icons.bluetooth_rounded,
                      color: MimiVentColors.mint, size: 19),
                  SizedBox(width: 11),
                  Text('连接蓝牙（备用）'),
                ]),
              ),
            if (c.offlineViewing)
              const PopupMenuItem(
                value: _TopBarMenuAction.connectDevice,
                child: Row(children: [
                  Icon(Icons.bluetooth_rounded,
                      color: MimiVentColors.mint, size: 19),
                  SizedBox(width: 11),
                  Text('连接设备'),
                ]),
              )
            else
              const PopupMenuItem(
                value: _TopBarMenuAction.offline,
                child: Row(children: [
                  Icon(Icons.offline_bolt_outlined,
                      color: MimiVentColors.mint, size: 19),
                  SizedBox(width: 11),
                  Text('离线查看统计'),
                ]),
              ),
            const PopupMenuItem(
              value: _TopBarMenuAction.diagnostics,
              child: Row(children: [
                Icon(Icons.receipt_long_outlined,
                    color: MimiVentColors.mint, size: 19),
                SizedBox(width: 11),
                Text('设备诊断'),
              ]),
            ),
            if (c.connected &&
                c.status?.capabilities.contains('wifi.configure') == true &&
                c.ble.hasWifiProvisioningService)
              const PopupMenuItem(
                value: _TopBarMenuAction.wifiProvisioning,
                child: Row(children: [
                  Icon(Icons.wifi, color: MimiVentColors.mint, size: 19),
                  SizedBox(width: 11),
                  Text('WiFi 配网'),
                ]),
              ),
            PopupMenuItem(
              value: _TopBarMenuAction.firmwareUpdate,
              enabled: c.connected && !c.offlineViewing,
              child: Row(children: [
                Icon(Icons.system_update_alt_rounded,
                    color: c.connected
                        ? MimiVentColors.mint
                        : MimiVentColors.muted,
                    size: 19),
                const SizedBox(width: 11),
                const Text('固件升级'),
              ]),
            ),
            PopupMenuItem(
              value: _TopBarMenuAction.closeApp,
              enabled: !c.busy,
              child: Row(children: [
                Icon(Icons.power_settings_new_rounded,
                    color: c.busy ? MimiVentColors.muted : MimiVentColors.red,
                    size: 19),
                const SizedBox(width: 11),
                Text(c.connected ? '断开并关闭 App' : '关闭 App'),
              ]),
            ),
          ],
          child: Container(
            width: 44 - 6 * collapse,
            height: 44 - 6 * collapse,
            decoration: BoxDecoration(
              color: MimiVentColors.surfaceRaised.withOpacity(.9),
              borderRadius: BorderRadius.circular(14 - 2 * collapse),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(Icons.more_horiz_rounded,
                    size: 23 - 4 * collapse, color: Colors.white),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.offlineViewing
                          ? MimiVentColors.muted
                          : online
                              ? MimiVentColors.mint
                              : c.ble.isScanning ||
                                      c.ble.connectionStatus ==
                                          BleConnectionStatus.connecting
                                  ? MimiVentColors.amber
                                  : MimiVentColors.red,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF1A2D28)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
