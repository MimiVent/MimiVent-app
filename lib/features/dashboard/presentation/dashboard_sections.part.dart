// UI helpers are split into parts to keep the dashboard organized by responsibility.
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'dashboard_page.dart';

extension _DashboardMainSections on _DashboardPageState {
  Widget _bottomBar() => SafeArea(
        top: false,
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: const Color(0xFF111D1A).withOpacity(.96),
            border:
                Border(top: BorderSide(color: Colors.white.withOpacity(.06))),
          ),
          child: Row(
            children: [
              _navItem(
                0,
                (color) => FanRotorGlyph(color: color, size: 11),
                '控制',
              ),
              _navItem(
                1,
                (color) => Icon(Icons.tune_rounded, size: 14, color: color),
                '时间设置',
              ),
              _navItem(
                2,
                (color) =>
                    Icon(Icons.bar_chart_rounded, size: 15, color: color),
                '统计',
              ),
            ],
          ),
        ),
      );

  Widget _navItem(
      int index, Widget Function(Color color) iconBuilder, String label) {
    final selected = _activeTab == index;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: () {
            setState(() => _selectedTab = index);
          },
          child: Center(
            child: SizedBox(
              width: 92,
              height: 46,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: selected
                      ? MimiVentColors.mint.withOpacity(.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconBuilder(
                        selected ? MimiVentColors.mint : MimiVentColors.muted),
                    const SizedBox(height: 2),
                    Text(label,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          color: selected
                              ? MimiVentColors.mint
                              : MimiVentColors.muted,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        )),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabBody() {
    final status = c.status;
    final settings = c.settings;
    // 导航与统计页始终存在；没有实时数据时展示未知状态，不填入假状态或默认配置。
    return IndexedStack(
      index: _activeTab,
      children: [
        if (_deviceReady)
          _controlPage(status!, settings!)
        else
          _unavailableControlPage(),
        if (_deviceReady)
          _settingsPage(status!, settings!)
        else
          _unavailableSettingsPage(),
        StatisticsPage(
          controller: c,
          active: _activeTab == 2,
          appVersion: _appVersion,
        ),
      ],
    );
  }

  Widget _connectionStatusBanner() {
    final offline = c.offlineViewing;
    final connecting = _deviceConnectActionBusy ||
        c.ble.connectionStatus == BleConnectionStatus.connecting;
    final scanning = c.ble.isScanning;
    final bleLinked = c.ble.isConnected;
    final color = offline
        ? MimiVentColors.muted
        : connecting || scanning || bleLinked
            ? MimiVentColors.amber
            : MimiVentColors.red;
    final text = offline
        ? '离线模式 · 仅查看缓存数据'
        : connecting
            ? '正在连接蓝牙 · 请稍候…'
            : scanning
                ? '正在搜索附近设备 · 请稍候…'
                : bleLinked
                    ? '蓝牙已连接 · 正在同步设备状态'
                    : '设备未连接 · 可查看缓存数据';
    final action = connecting
        ? '连接中…'
        : scanning
            ? '搜索中…'
            : '连接设备';
    final icon = offline
        ? Icons.offline_bolt_outlined
        : connecting || scanning
            ? Icons.bluetooth_searching
            : bleLinked
                ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled;
    return Material(
      color: MimiVentColors.surfaceRaised,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: _leaveOfflineAndConnect,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11),
              ),
            ),
            const SizedBox(width: 6),
            Text(action,
                style:
                    const TextStyle(color: MimiVentColors.mint, fontSize: 11)),
            if (!connecting && !scanning)
              const Icon(Icons.chevron_right_rounded,
                  size: 17, color: MimiVentColors.mint),
          ]),
        ),
      ),
    );
  }

  Widget _unavailableControlPage() => _scrollPage('unavailable-control-page', [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: MimiVentColors.surface,
            borderRadius: BorderRadius.circular(27),
            border: Border.all(color: Colors.white.withOpacity(.06)),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      c.offlineViewing
                          ? '离线查看'
                          : c.connected && c.deviceOtaBusy
                              ? '设备正在升级'
                              : c.connected && !c.appVersionCompatible
                                  ? '请更新 MimiVent App'
                                  : c.connected
                                      ? '正在同步'
                                      : '等待连接',
                      style: const TextStyle(
                          fontSize: 27, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 9),
                  const Text('风机与感应实时状态未知',
                      style:
                          TextStyle(color: MimiVentColors.muted, fontSize: 12)),
                  const SizedBox(height: 5),
                  Text(
                      c.deviceOtaBusy
                          ? 'OTA 正在执行，设备仍会独立运行；完成后重新连接即可核验'
                          : (!c.appVersionCompatible && c.lastError != null
                              ? c.lastError!
                              : '连接蓝牙后同步，设备继续独立运行'),
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 10)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const FanRotorGlyph(color: MimiVentColors.muted, size: 60),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: _metricCard(
              title: '空间感应',
              value: '状态未知',
              detail: '连接后同步 PIR',
              icon: Icons.radar_rounded,
              accent: MimiVentColors.muted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _metricCard(
              title: '风机运行',
              value: '--:--',
              detail: '尚未获取实时数据',
              icon: Icons.schedule_rounded,
              accent: MimiVentColors.muted,
            ),
          ),
        ]),
        const SizedBox(height: 14),
        _unavailableQuickActions(),
        const SizedBox(height: 18),
        Center(
          child: Text('App v$_appVersion',
              style:
                  const TextStyle(color: MimiVentColors.muted, fontSize: 10)),
        ),
      ]);

  Widget _unavailableQuickActions() {
    const actions = <(ControlOperation, String, IconData)>[
      (ControlOperation.automatic, '自动感应', Icons.sensors_rounded),
      (ControlOperation.exhaust, '临时排风', Icons.air_rounded),
      (ControlOperation.pause, '临时暂停', Icons.pause_circle_outline_rounded),
      (ControlOperation.forceExhaust, '强制排风', Icons.science_outlined),
      (
        ControlOperation.persistentOff,
        '持续关闭',
        Icons.power_settings_new_rounded
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (var index = 0; index < actions.length; index++) ...[
          if (index > 0) const SizedBox(width: 10),
          SizedBox(
            width: 154,
            child: _actionCard(
              icon: actions[index].$1 == ControlOperation.exhaust
                  ? const FanRotorGlyph(color: MimiVentColors.muted, size: 11)
                  : Icon(actions[index].$3,
                      size: 16, color: MimiVentColors.muted),
              title: actions[index].$2,
              detail: '需要连接蓝牙',
              selected: false,
              accent: MimiVentColors.mint,
              enabled: true,
              onTap: () => _runAction(actions[index].$1),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _unavailableSettingsPage() =>
      _scrollPage('unavailable-settings-page', [
        _sectionHeader('时间设置', '连接后读取设备配置'),
        const SizedBox(height: 10),
        const Text('当前环境和时序尚未同步。点击设置可连接设备。',
            style: TextStyle(color: MimiVentColors.muted, fontSize: 12)),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: MimiVentColors.surface,
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: Colors.white.withOpacity(.06)),
          ),
          child: Column(children: [
            for (final title in const [
              '运行环境',
              '启动冷静期',
              '离开确认时间',
              '自动排风时长',
              '临时排风时长',
              '临时暂停时长',
            ])
              ListTile(
                title: Text(title, style: const TextStyle(fontSize: 13)),
                trailing: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('未同步',
                      style:
                          TextStyle(color: MimiVentColors.muted, fontSize: 11)),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: MimiVentColors.muted),
                ]),
                onTap: _requireDeviceConnection,
              ),
          ]),
        ),
        const SizedBox(height: 14),
        _diagnosticsEntry(),
      ]);

  Widget _scrollPage(String key, List<Widget> children) => LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = constraints.maxWidth.clamp(0, 860).toDouble();
          return ListView(
            key: PageStorageKey(key),
            primary: false,
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: contentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ],
          );
        },
      );

  Widget _controlPage(DeviceStatus status, TimingSettings settings) =>
      _scrollPage('control-page', [
        VersionCompatibilityNotice(
          appVersion: _appVersion,
          firmwareVersion: status.firmware,
          minimumAppVersion: status.minimumAppVersion,
        ),
        if (!c.profileMatches) ...[
          _mismatchPanel(status),
          const SizedBox(height: 14),
        ],
        _statusHero(status),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: _metricCard(
              title: '空间感应',
              value: status.pir ? '检测到活动' : '环境稳定',
              detail: 'PIR · GPIO 4 · ${status.pir ? 'HIGH' : 'LOW'}',
              icon: Icons.radar_rounded,
              accent: status.pir ? MimiVentColors.amber : MimiVentColors.mint,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _metricCard(
              title: '风机运行',
              value: DurationFormatter.clock(c.displayFanRunMs),
              detail: '本次运行时长',
              icon: Icons.schedule_rounded,
              accent: status.fan ? MimiVentColors.amber : MimiVentColors.mint,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _runtimeCard(status),
        const SizedBox(height: 14),
        _quickActionsRow(status, settings),
        const SizedBox(height: 8),
        Center(child: _deviceMetaRow(status)),
      ]);

  Widget _quickActionsRow(DeviceStatus status, TimingSettings settings) {
    final mismatch = !c.profileMatches;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(children: [
        SizedBox(
          width: 154,
          child: _actionCard(
            icon: Icon(
              Icons.sensors_rounded,
              size: 16,
              color: status.mode == 'auto'
                  ? MimiVentColors.mint
                  : MimiVentColors.muted,
            ),
            title: '自动感应',
            detail: '活动停风 · 离开后排风',
            selected: status.mode == 'auto',
            accent: MimiVentColors.mint,
            enabled: _canOperate(status, mismatch, allowCooldown: false),
            onTap: () => _runAction(ControlOperation.automatic),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
            width: 154,
            child: _actionCard(
              icon: FanRotorGlyph(
                color: status.mode == 'timed_on'
                    ? MimiVentColors.mint
                    : MimiVentColors.muted,
                size: 11,
              ),
              title: '临时排风',
              detail: DurationFormatter.label(settings.manualExhaustMs),
              selected: status.mode == 'timed_on',
              accent: MimiVentColors.mint,
              enabled: _canOperate(status, mismatch, allowCooldown: false),
              onTap: () => _runAction(ControlOperation.exhaust),
            )),
        const SizedBox(width: 10),
        SizedBox(
            width: 154,
            child: _actionCard(
              icon: Icon(
                Icons.pause_circle_outline_rounded,
                size: 16,
                color: status.mode == 'timed_off'
                    ? const Color(0xFF9AC8FF)
                    : MimiVentColors.muted,
              ),
              title: '临时暂停',
              detail: DurationFormatter.label(settings.pauseMs),
              selected: status.mode == 'timed_off',
              accent: const Color(0xFF9AC8FF),
              enabled: _canOperate(status, mismatch, allowCooldown: false),
              onTap: () => _runAction(ControlOperation.pause),
            )),
        const SizedBox(width: 10),
        SizedBox(
          width: 154,
          child: _actionCard(
            icon: Icon(
              Icons.science_outlined,
              size: 16,
              color: status.mode == 'force_test'
                  ? MimiVentColors.amber
                  : MimiVentColors.muted,
            ),
            title: '强制排风',
            detail:
                '${DurationFormatter.label(settings.manualExhaustMs)} · 忽略PIR',
            selected: status.mode == 'force_test',
            accent: MimiVentColors.amber,
            enabled: _canOperate(status, mismatch, allowCooldown: true),
            onTap: () => _runAction(ControlOperation.forceExhaust),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 154,
          child: _actionCard(
            icon: Icon(
              Icons.power_settings_new_rounded,
              size: 16,
              color: status.mode == 'lock_off'
                  ? MimiVentColors.red
                  : MimiVentColors.muted,
            ),
            title: '持续关闭',
            detail: status.mode == 'lock_off' ? '待手动恢复' : '持续关闭不再运行风机',
            selected: status.mode == 'lock_off',
            accent: MimiVentColors.red,
            enabled: _canOperate(status, mismatch, allowCooldown: true),
            onTap: () => _runAction(ControlOperation.persistentOff),
          ),
        ),
      ]),
    );
  }

  Widget _settingsPage(DeviceStatus status, TimingSettings settings) =>
      _scrollPage('settings-page', [
        if (!c.profileMatches) ...[
          _mismatchPanel(status),
          const SizedBox(height: 14),
        ],
        _profileBar(status),
        const SizedBox(height: 16),
        _sectionHeader('时间设置', '${c.profile.label}独立保存'),
        const SizedBox(height: 6),
        const Text('调整冷静期、离开确认和排风时长；修改后点击保存写入设备。',
            style: TextStyle(
                color: MimiVentColors.muted, fontSize: 12, height: 1.5)),
        const SizedBox(height: 14),
        _settingsCard(settings, !c.profileMatches),
        const SizedBox(height: 14),
        _runtimeCard(status),
        const SizedBox(height: 14),
        _diagnosticsEntry(),
      ]);

  Widget _diagnosticsEntry() => Material(
        color: MimiVentColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: _openDiagnostics,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(.06)),
            ),
            child: const Row(children: [
              Icon(Icons.receipt_long_outlined,
                  color: MimiVentColors.mint, size: 20),
              SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('设备诊断',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: 3),
                    Text('查看扫描、连接和设备通信记录',
                        style: TextStyle(
                            color: MimiVentColors.muted, fontSize: 11)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: MimiVentColors.muted, size: 20),
            ]),
          ),
        ),
      );

  /// 版本号放在控制页末尾，方便排查固件与 App 是否匹配。
  Widget _deviceMetaRow(DeviceStatus status) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'App v$_appVersion${_appBuildNumber.isEmpty ? '' : ' ($_appBuildNumber)'}'
            '  ·  固件版本 v${status.firmware}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF84958E),
              fontSize: 10,
              height: 1.2,
            ),
          ),
        ],
      );
}
