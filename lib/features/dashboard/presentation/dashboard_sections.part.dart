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
            if (!c.connected) {
              _toast('请先连接 ${AppIdentity.productName}，连接后即可使用全部功能');
              return;
            }
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
    if (!c.connected) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: const PageStorageKey('connection-page'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 32).clamp(0, double.infinity),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _disconnectedPanel(),
              ),
            ),
          ),
        ),
      );
    }
    final status = c.status;
    final settings = c.settings;
    if (status == null || settings == null) {
      return ListView(
        key: const PageStorageKey('loading-page'),
        primary: false,
        padding: const EdgeInsets.all(18),
        children: [
          _loadingPanel(),
        ],
      );
    }

    // 两个常驻页面各自保留滚动状态；轮询刷新状态时不重建单一长列表。
    return IndexedStack(
      index: _activeTab,
      children: [
        _controlPage(status, settings),
        _settingsPage(status, settings),
      ],
    );
  }

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
        if (!c.profileMatches) ...[
          _mismatchPanel(status),
          const SizedBox(height: 14),
        ],
        _statusHero(status),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            // 大字体时优先堆叠状态卡，避免数值和说明挤压或裁切。
            final compact =
                constraints.maxWidth < 340 || AppLayout.usesLargeText(context);
            final sensor = _metricCard(
              title: '空间感应',
              value: status.pir ? '检测到活动' : '环境稳定',
              detail: 'PIR · GPIO 4 · ${status.pir ? 'HIGH' : 'LOW'}',
              icon: Icons.radar_rounded,
              accent: status.pir ? MimiVentColors.amber : MimiVentColors.mint,
            );
            final fan = _metricCard(
              title: '风机运行',
              value: DurationFormatter.clock(status.fanRunMs),
              detail: DeviceStatusPresenter.phaseDescription(status),
              icon: Icons.schedule_rounded,
              accent: status.fan ? MimiVentColors.amber : MimiVentColors.mint,
            );
            if (compact) {
              return Column(
                  children: [sensor, const SizedBox(height: 10), fan]);
            }
            return Row(children: [
              Expanded(child: sensor),
              const SizedBox(width: 10),
              Expanded(child: fan),
            ]);
          },
        ),
        const SizedBox(height: 12),
        _runtimeCard(status),
        const SizedBox(height: 14),
        _autoButton(status, !c.profileMatches),
        const SizedBox(height: 10),
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
