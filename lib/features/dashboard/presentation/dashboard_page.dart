import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show ScanResult;
import 'package:package_info_plus/package_info_plus.dart';

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
import '../../control/control_operation.dart';
import '../../diagnostics/diagnostics_page.dart';
import '../../statistics/presentation/statistics_page.dart';

part 'dashboard_connection.part.dart';
part 'dashboard_actions.part.dart';
part 'dashboard_sections.part.dart';
part 'dashboard_status_cards.part.dart';

enum _TopBarMenuAction { diagnostics, closeApp }

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    required this.controller,
    required this.diagnostics,
    super.key,
  });

  final MimiVentController controller;
  final AppDiagnosticsLog diagnostics;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final ModalCoordinator _modalCoordinator = ModalCoordinator();
  MimiVentController get c => widget.controller;
  int _selectedTab = 0;
  int get _activeTab => _selectedTab < 3 ? _selectedTab : 0;
  double _headerCollapse = 0;
  bool _scanSheetOpen = false;
  bool _scanSheetDismissedDuringScan = false;
  bool _connectionRevealActive = false;
  bool _deviceConnectActionBusy = false;
  bool _reconnectInProgress = false;
  String _appVersion = '读取中';
  String _appBuildNumber = '';

  @override
  void initState() {
    super.initState();
    c.addListener(_syncDeviceUi);
    _syncDeviceUi();
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
                        if (c.lastError != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                            child: _connectionErrorBanner(),
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
            bottomNavigationBar: c.connected ? _bottomBar() : null,
          );
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _connectionRevealActive ? 3.2 : 0),
            duration: _connectionRevealActive
                ? const Duration(milliseconds: 180)
                : const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
            child: page,
            builder: (context, blur, child) => ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: child,
            ),
          );
        },
      );

  Widget _topBar(double collapse) {
    final online = c.connected;
    final isRunning = c.status?.fan ?? false;
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
              case _TopBarMenuAction.closeApp:
                _disconnectAndExit();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _TopBarMenuAction.diagnostics,
              child: Row(children: [
                Icon(Icons.receipt_long_outlined,
                    color: MimiVentColors.mint, size: 19),
                SizedBox(width: 11),
                Text('设备诊断'),
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
                      color:
                          online ? MimiVentColors.mint : MimiVentColors.amber,
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

  Widget _disconnectedPanel() => Container(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1C3930), Color(0xFF142720), Color(0xFF11201D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: MimiVentColors.mint.withOpacity(.14)),
          boxShadow: _displayCardShadows(MimiVentColors.mint),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(.08)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset('assets/images/mimivent_logo.png',
                        fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${AppIdentity.productName} · App v$_appVersion',
                          style: const TextStyle(
                              fontSize: 11,
                              color: MimiVentColors.mint,
                              fontWeight: FontWeight.w700,
                              letterSpacing: .2)),
                      const SizedBox(height: 5),
                      const Text('连接你的设备',
                          style: TextStyle(
                              fontSize: 24,
                              height: 1.1,
                              fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                Icon(Icons.bluetooth_searching,
                    size: 25, color: MimiVentColors.mint.withOpacity(.9)),
              ],
            ),
            const SizedBox(height: 18),
            const Text('首次使用请授权附近设备/蓝牙权限，并打开手机蓝牙。连接后即可查看传感器状态、控制风机和设置排风时间。',
                style: TextStyle(color: MimiVentColors.muted, height: 1.55)),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _featureChip(Icons.tune_rounded, '时间配置'),
                _featureChip(Icons.science_outlined, '风机测试'),
              ],
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                onPressed: _scanAndConnect,
                icon: c.ble.isScanning
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF10211B),
                        ),
                      )
                    : const Icon(Icons.bluetooth),
                label: Text(c.ble.isScanning
                    ? '发现 ${c.ble.scanResults.length} 个设备'
                    : '扫描并连接 ${AppIdentity.productName}'),
                style: FilledButton.styleFrom(
                  backgroundColor: MimiVentColors.mint,
                  foregroundColor: const Color(0xFF10211B),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                  textStyle: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: MimiVentColors.muted.withOpacity(.8)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.ble.isScanning
                        ? '正在扫描附近设备。请确认 ${AppIdentity.productName} 已通电，并且没有被其他手机或网页占用。'
                        : '扫描结束后可再次搜索。刚断开连接时，设备可能需要片刻恢复广播。',
                    style: const TextStyle(
                        color: Color(0xFF8FA39A), fontSize: 11, height: 1.45),
                  ),
                ),
              ],
            ),
            if (c.ble.lastError != null && c.lastError == null) ...[
              const SizedBox(height: 10),
              Text(c.ble.lastError!,
                  style:
                      const TextStyle(color: MimiVentColors.red, fontSize: 12)),
            ],
          ],
        ),
      );

  Widget _featureChip(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.045),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white.withOpacity(.07)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: MimiVentColors.mint),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  color: MimiVentColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}
