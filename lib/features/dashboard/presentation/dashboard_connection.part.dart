// These UI methods remain in the State library so they can share its lifecycle.
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'dashboard_page.dart';

extension _DashboardConnectionSection on _DashboardPageState {
  Future<void> _enterOfflineViewing() async {
    _scanSheetDismissedDuringScan = true;
    try {
      if (c.connected) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('切换到离线查看？'),
            content: const Text('切换后会断开当前蓝牙连接，只显示本机已缓存的统计数据。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('继续连接'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('断开并离线查看'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await c.enterOfflineViewing();
      if (!mounted) return;
      setState(() {
        _headerCollapse = 0;
      });
    } catch (error) {
      _toast('暂时无法打开离线统计：$error');
    }
  }

  Future<void> _leaveOfflineAndConnect() async {
    if (c.offlineViewing) await c.leaveOfflineViewing();
    if (!mounted) return;
    await _scanAndConnect();
  }

  Future<void> _openDiagnostics() async {
    final switchToMqtt = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DiagnosticsPage(log: widget.diagnostics, controller: c),
      ),
    );
    if (switchToMqtt == true) await widget.onSwitchToNasMqtt?.call();
  }

  Future<void> _openFirmwareUpdate() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FirmwareUpdatePage(ble: c.ble),
        ),
      );

  Future<void> _openWifiProvisioning() async {
    final switchToMqtt = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WifiProvisioningPage(ble: c.ble),
      ),
    );
    if (switchToMqtt == true) await widget.onSwitchToNasMqtt?.call();
  }

  Future<void> _openNasControlRecovery() async {
    final switchToMqtt = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WifiBindingAndNasPage(
          ble: c.ble,
          initialBinding: c.activeBinding,
          onSwitchToNasMqtt: widget.onSwitchToNasMqtt,
          onOpenWifiProvisioning: () {
            final navigator = Navigator.of(context);
            unawaited(navigator
                .push<bool>(MaterialPageRoute(
              builder: (_) => WifiProvisioningPage(ble: c.ble),
            ))
                .then((shouldSwitch) {
              if (shouldSwitch == true && mounted && navigator.canPop()) {
                navigator.pop(true);
              }
            }));
          },
        ),
      ),
    );
    if (switchToMqtt == true) await widget.onSwitchToNasMqtt?.call();
    await c.refreshPendingNasMqttRequest();
  }

  Future<void> _showReconnectChoices() async {
    if (c.busy || _reconnectInProgress) return;
    final reconnect = await _modalCoordinator.present<bool>(
      context,
      show: () => showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF182A26),
          title: const Text('蓝牙连接异常'),
          content: const Text('选择接下来要执行的操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              style: TextButton.styleFrom(foregroundColor: MimiVentColors.red),
              child: const Text('关闭 App'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: MimiVentColors.mint,
                foregroundColor: MimiVentColors.darkText,
              ),
              child: const Text('重新连接'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || reconnect == null) return;
    if (reconnect) {
      await _reconnectFromBanner();
    } else {
      await _closeAppAfterReconnectPrompt();
    }
  }

  Future<void> _closeAppAfterReconnectPrompt() async {
    try {
      if (c.connected || c.ble.isScanning) await c.closeBluetoothSession();
    } finally {
      if (mounted) await SystemNavigator.pop();
    }
  }

  Future<void> _reconnectFromBanner() async {
    if (c.busy || _reconnectInProgress || _scanSheetOpen) return;
    setState(() => _reconnectInProgress = true);
    try {
      // 先释放可能残留的 GATT/扫描状态，再开启新一轮扫描。
      await c.closeBluetoothSession();
      if (!mounted) return;
      c.clearError();
      setState(() => _reconnectInProgress = false);
      unawaited(_scanAndConnect());
    } catch (error) {
      if (!mounted) return;
      setState(() => _reconnectInProgress = false);
      _toast('无法重新连接：$error');
    }
  }

  void _syncDeviceUi() {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    if (c.offlineViewing) return;
    if (!_wifiPromptHandled &&
        !_wifiPromptShowing &&
        c.connected &&
        c.status?.capabilities.contains('wifi.configure') == true &&
        c.ble.hasWifiProvisioningService) {
      _wifiPromptHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent != false) {
          unawaited(_maybeShowWifiPrompt());
        }
      });
    }
    // App 启动时会自动开始扫描；检测到扫描状态后，首页自动打开搜索面板。
    if (!c.ble.isScanning) {
      // 一轮扫描结束后，后续新扫描可以再次自动打开搜索面板。
      _scanSheetDismissedDuringScan = false;
      return;
    }
    if (!_scanSheetOpen && !_scanSheetDismissedDuringScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent != false &&
            c.ble.isScanning &&
            !_scanSheetOpen &&
            !_scanSheetDismissedDuringScan) {
          unawaited(_scanAndConnect());
        }
      });
    }
  }

  Future<void> _maybeShowWifiPrompt() async {
    if (_wifiPromptShowing ||
        !c.connected ||
        !c.ble.hasWifiProvisioningService) {
      return;
    }
    final deviceId = c.ble.connectedDeviceId;
    if (deviceId == null) return;
    _wifiPromptShowing = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final key = 'mimivent.wifi.provision_prompt_dismissed.' + deviceId;
      if (preferences.getBool(key) == true || !mounted) return;
      final configure = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('配置 WiFi？'),
          content: const Text('配置并绑定后可通过局域网读取状态，控制和升级仍使用蓝牙。首次配网会弹出系统蓝牙配对确认。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('立即配置'),
            ),
          ],
        ),
      );
      if (!mounted || configure == null) return;
      await preferences.setBool(key, true);
      if (configure) await _openWifiProvisioning();
    } catch (error) {
      if (mounted) _toast('无法打开 WiFi 配网：' + error.toString());
    } finally {
      _wifiPromptShowing = false;
    }
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        _appBuildNumber = info.buildNumber;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _appVersion = '未知');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    try {
      TopToast.show(context, message);
    } catch (_) {
      // 异步连接失败可能晚于路由退场；提示不可用时不再触发二次异常。
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    String detail = '',
    String confirm = '确认',
    bool danger = false,
  }) =>
      MimiVentDialogs.confirm(
        context,
        title: title,
        message: message,
        detail: detail,
        confirmLabel: confirm,
        danger: danger,
        coordinator: _modalCoordinator,
      );

  Future<void> _scanAndConnect() async {
    if (_scanSheetOpen) return;
    _connectionActionError = null;
    // 显式进入扫描面板代表用户希望查看这一轮扫描结果。
    _scanSheetDismissedDuringScan = false;
    _scanSheetOpen = true;
    if (!c.ble.isScanning) unawaited(c.scan());
    if (!mounted) {
      _scanSheetOpen = false;
      return;
    }
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        builder: (context) => AnimatedBuilder(
          animation: c,
          builder: (context, _) => Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: AppLayout.connectionSheetHeightFactor(context),
              widthFactor: 1,
              child: Material(
                color: const Color(0xFF12211E),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: SizedBox.expand(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                          child: Column(
                            mainAxisSize: MainAxisSize.max,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Builder(builder: (context) {
                                final presentation = connectionPresentation(
                                  connected: c.ble.isConnected &&
                                      _connectionActionError == null,
                                  connecting: _deviceConnectActionBusy ||
                                      c.ble.connectionStatus ==
                                          BleConnectionStatus.connecting,
                                  scanning: c.ble.isScanning,
                                );
                                final isConnecting = presentation ==
                                    ConnectionPresentation.connecting;
                                final isConnected = presentation ==
                                    ConnectionPresentation.connected;
                                final connectionFailed =
                                    _connectionActionError != null &&
                                        !_deviceConnectActionBusy;
                                final foundCount = c.ble.scanResults.length;
                                final title = connectionFailed
                                    ? (c.ble.isConnected
                                        ? '设备已连接，但初始化失败'
                                        : '蓝牙连接已断开')
                                    : isConnecting
                                        ? '正在连接设备'
                                        : isConnected
                                            ? '${AppIdentity.productName} 已连接'
                                            : '搜索附近的 ${AppIdentity.productName}';
                                final subtitle = connectionFailed
                                    ? (c.ble.isConnected
                                        ? '${_connectionActionError!}。可以点击设备重试连接。'
                                        : '${_connectionActionError!}。请重新点击设备连接。')
                                    : isConnecting
                                        ? '正在连接 ${c.ble.connectedName}，请稍候…'
                                        : isConnected
                                            ? '连接成功，正在打开控制面板。'
                                            : foundCount == 1
                                                ? '已发现 1 台 ${AppIdentity.productName}，点击下方按钮开始连接。'
                                                : foundCount > 0
                                                    ? '扫描到 $foundCount 台设备，请选择您的设备。'
                                                    : c.ble.isScanning
                                                        ? '正在搜索附近设备…'
                                                        : '没有扫描到设备。请检查设备通电，或点击重新扫描。';
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 外层 padding 顶部为 0、右侧为 18，原先按钮贴顶显得偏上；
                                    // 补 12 的顶部间距后与右侧视觉平衡。
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: SizedBox(
                                        height: 34,
                                        child: Row(
                                          children: [
                                            const Spacer(),
                                            IconButton(
                                              tooltip: '关闭',
                                              onPressed: isConnecting
                                                  ? null
                                                  : () =>
                                                      Navigator.pop(context),
                                              icon: const Icon(
                                                  Icons.close_rounded,
                                                  size: 21),
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                      width: 34, height: 34),
                                              visualDensity:
                                                  VisualDensity.compact,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Center(
                                      child: Text(
                                        title,
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Center(
                                      child: Text(
                                        subtitle,
                                        style: const TextStyle(
                                            color: MimiVentColors.muted),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Center(
                                      child: BluetoothSearchPulse(
                                        active:
                                            c.ble.isScanning || isConnecting,
                                        connecting: isConnecting,
                                        connected: isConnected,
                                        size: AppLayout.connectionAnimationSize(
                                            context),
                                      ),
                                    ),
                                    if (isConnecting) ...[
                                      const SizedBox(height: 2),
                                      const LinearProgressIndicator(
                                        minHeight: 2,
                                        color: MimiVentColors.mint,
                                        backgroundColor: Color(0xFF29443B),
                                      ),
                                    ],
                                  ],
                                );
                              }),
                              const SizedBox(height: 4),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (c.ble.scanResults.isEmpty)
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(14),
                                          decoration: BoxDecoration(
                                              color: MimiVentColors.surface,
                                              borderRadius:
                                                  BorderRadius.circular(18)),
                                          child: Text(
                                            c.ble.lastError ??
                                                (c.ble.isScanning
                                                    ? '请保持 App 在前台，并让手机靠近 ${AppIdentity.productName}。'
                                                    : '请确认 ${AppIdentity.productName} 已通电、蓝牙未被其他手机占用，并靠近设备后重新扫描。'),
                                            style: TextStyle(
                                              color: c.ble.lastError == null
                                                  ? MimiVentColors.muted
                                                  : MimiVentColors.red,
                                              height: 1.45,
                                            ),
                                          ),
                                        )
                                      else if (c.ble.scanResults.length == 1)
                                        _singleDeviceCard(
                                          context,
                                          c.ble.scanResults.single,
                                          _deviceConnectActionBusy ||
                                              c.ble.connectionStatus ==
                                                  BleConnectionStatus
                                                      .connecting,
                                        )
                                      else ...[
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                              4, 0, 4, 6),
                                          child: Text(
                                            '扫描到 ${c.ble.scanResults.length} 台设备，选择要连接的设备',
                                            style: const TextStyle(
                                                color: MimiVentColors.muted,
                                                fontSize: 12),
                                          ),
                                        ),
                                        ...c.ble.scanResults.map((result) {
                                          final name = result.advertisementData
                                                  .advName.isNotEmpty
                                              ? result.advertisementData.advName
                                              : (result.device.platformName
                                                      .isNotEmpty
                                                  ? result.device.platformName
                                                  : AppIdentity.productName);
                                          return ListTile(
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 4),
                                            leading: const CircleAvatar(
                                              backgroundColor:
                                                  Color(0xFF29443B),
                                              child: FanRotorGlyph(
                                                  color: MimiVentColors.mint,
                                                  size: 22),
                                            ),
                                            title: Text(name),
                                            subtitle: BleSignalIndicator(
                                                rssi: result.rssi,
                                                fontSize: 11),
                                            trailing: const Text(
                                              '点击连接',
                                              style: TextStyle(
                                                  color: MimiVentColors.mint,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600),
                                            ),
                                            onTap: _deviceConnectActionBusy ||
                                                    c.ble.connectionStatus ==
                                                        BleConnectionStatus
                                                            .connecting
                                                ? null
                                                : () => _connectScanResult(
                                                    context, result),
                                          );
                                        }),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _deviceConnectActionBusy ||
                                          c.ble.isScanning ||
                                          c.ble.connectionStatus ==
                                              BleConnectionStatus.connecting
                                      ? null
                                      : () => c.scan(),
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: Text(c.ble.scanResults.isEmpty
                                      ? '重新扫描附近设备'
                                      : '重新扫描'),
                                ),
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: TextButton(
                                  key: const ValueKey(
                                      'connection-sheet-offline'),
                                  onPressed: _deviceConnectActionBusy ||
                                          c.ble.connectionStatus ==
                                              BleConnectionStatus.connecting
                                      ? null
                                      : () {
                                          Navigator.pop(context);
                                          unawaited(_enterOfflineViewing());
                                        },
                                  child: const Text('离线模式 · 查看缓存数据'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      _scanSheetOpen = false;
      // 用户关闭扫描面板或离开连接流程时，通知上层撤销待切换意图；
      // 控制器初始化已完成则说明连接成功，不应走取消分支。
      if (!c.bluetoothControlReady) {
        widget.onBluetoothConnectCancelled?.call();
      }
      // 点空白或关闭按钮只关闭界面，不会取消 BLE 扫描；记住用户的关闭操作，
      // 避免后续扫描结果通知再次把同一个弹窗自动打开。
      if (c.ble.isScanning) _scanSheetDismissedDuringScan = true;
    }
  }

  /// 单台设备时使用独立大卡片，避免把唯一选项呈现成普通列表行。
  Widget _singleDeviceCard(
    BuildContext modalContext,
    ScanResult result,
    bool isConnecting,
  ) {
    final advertisedName = result.advertisementData.advName.trim();
    final platformName = result.device.platformName.trim();
    final name = advertisedName.isNotEmpty
        ? advertisedName
        : platformName.isNotEmpty
            ? platformName
            : AppIdentity.productName;

    return MarqueeBorder(
      active: !isConnecting,
      radius: 22,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: MimiVentColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: MimiVentColors.mint.withOpacity(.18)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: MimiVentColors.mint.withOpacity(.12),
                    shape: BoxShape.circle,
                  ),
                  child:
                      const FanRotorGlyph(color: MimiVentColors.mint, size: 24),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      BleSignalIndicator(rssi: result.rssi),
                    ],
                  ),
                ),
                const Icon(Icons.bluetooth_rounded,
                    color: MimiVentColors.mint, size: 21),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isConnecting
                    ? null
                    : () => _connectScanResult(modalContext, result),
                style: FilledButton.styleFrom(
                  backgroundColor: MimiVentColors.mint,
                  foregroundColor: const Color(0xFF10201B),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isConnecting) ...[
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF10201B),
                        ),
                      ),
                      const SizedBox(width: 9),
                    ],
                    Text(isConnecting ? '连接中…' : '点击连接 $name'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connectScanResult(
    BuildContext modalContext,
    ScanResult result,
  ) async {
    final wasNasMqttActive = c.nasMqttActive;
    c.diagnostics?.info('蓝牙连接', '用户开始连接 ${result.device.remoteId.str}');
    try {
      if (mounted) {
        setState(() {
          _connectionRevealActive = true;
          _deviceConnectActionBusy = true;
          _connectionActionError = null;
        });
      }
      await c.connect(result.device);
      if (!c.bluetoothControlReady) {
        throw StateError(c.lastError ?? '设备连接已中断，请重新连接');
      }
      // 等待上层完成 make-before-break 收尾；之后再显示本地通道提示，
      // 避免 App 根层提示被连接弹窗的通用“已连接”提示覆盖。
      await widget.onBluetoothConnected?.call();
      c.diagnostics?.info('蓝牙连接', '控制器初始化完成，准备关闭搜索弹窗');
      if (!modalContext.mounted) return;
      final route = ModalRoute.of(modalContext);
      Navigator.pop(modalContext);
      // 等弹窗退场动画完成后再清除背景虚化，形成“弹窗退出、页面显清”的衔接。
      await route?.completed;
      if (mounted) {
        setState(() {
          _connectionRevealActive = false;
          _deviceConnectActionBusy = false;
        });
      }
      _toast(wasNasMqttActive
          ? '已切换到蓝牙控制'
          : (c.lastError ?? '${AppIdentity.productName} 已连接'));
    } catch (error, stackTrace) {
      c.diagnostics?.error('连接页面', error.toString(), stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _connectionRevealActive = false;
          _deviceConnectActionBusy = false;
          _connectionActionError = error
              .toString()
              .replaceFirst('Bad state: ', '')
              .replaceFirst('Exception: ', '');
        });
      }
      _toast(error.toString());
    } finally {
      if (mounted && _deviceConnectActionBusy && !modalContext.mounted) {
        setState(() {
          _connectionRevealActive = false;
          _deviceConnectActionBusy = false;
        });
      }
    }
  }

  /// 关闭 App 前二次确认；若已连接，先释放 BLE 会话再退出。
  Future<void> _disconnectAndExit() async {
    final connected = c.connected;
    final accepted = await _confirm(
      title: connected ? '断开并关闭 App？' : '关闭 App？',
      message: connected
          ? '将断开 ${AppIdentity.productName} 蓝牙连接并关闭 App。'
          : '将关闭 ${AppIdentity.productName} App。',
      detail: connected ? '重新打开 App 后会自动扫描设备。' : '',
      confirm: connected ? '断开并退出' : '关闭并退出',
      danger: true,
    );
    if (!accepted || !mounted) return;

    if (c.connected || c.ble.isScanning) {
      // 先等待 GATT 断开和扫描停止，再退出 Activity，避免退出和清理互相抢占。
      await c.closeBluetoothSession();
    }
    if (mounted) await SystemNavigator.pop();
  }
}
