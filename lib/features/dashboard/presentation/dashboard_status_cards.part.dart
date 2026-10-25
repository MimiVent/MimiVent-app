// UI helpers are split into parts to keep the dashboard organized by responsibility.
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'dashboard_page.dart';

extension _DashboardStatusCards on _DashboardPageState {
  Widget _profileBar(DeviceStatus status) {
    final matchesDevice = status.activeProfile == c.profile;
    final statusColor =
        matchesDevice ? MimiVentColors.mint : MimiVentColors.amber;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: MimiVentColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.tune_rounded, size: 17, color: statusColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('运行环境',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('设备：${status.activeProfile.label}',
                        style: TextStyle(fontSize: 10, color: statusColor)),
                  ],
                ),
              ),
              _tagShell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      matchesDevice
                          ? Icons.check_circle_rounded
                          : Icons.sync_problem_rounded,
                      size: 10,
                      color: statusColor,
                    ),
                    const SizedBox(width: 3),
                    Text(matchesDevice ? '已同步' : '未同步',
                        style: TextStyle(
                            fontSize: 9,
                            color: statusColor,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                statusColor,
                backgroundOpacity: .1,
                borderOpacity: 0,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1A17),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: TimingProfile.values.map((profile) {
                final selected = profile == c.profile;
                final accent = profile == TimingProfile.dev
                    ? MimiVentColors.amber
                    : MimiVentColors.mint;
                return Expanded(
                  child: Semantics(
                    button: true,
                    selected: selected,
                    label: '切换到${profile.label}',
                    child: InkWell(
                      onTap: c.busy ? null : () => _switchProfile(profile),
                      borderRadius: BorderRadius.circular(11),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        height: 40,
                        decoration: BoxDecoration(
                          color: selected
                              ? accent.withOpacity(.14)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                          border: selected
                              ? Border.all(color: accent.withOpacity(.28))
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              selected
                                  ? Icons.check_rounded
                                  : profile == TimingProfile.dev
                                      ? Icons.code_rounded
                                      : Icons.auto_awesome_rounded,
                              size: 15,
                              color: selected ? accent : MimiVentColors.muted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              profile.label,
                              style: TextStyle(
                                fontSize: 11,
                                color: selected ? accent : MimiVentColors.muted,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mismatchPanel(DeviceStatus status) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF17231F),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: MimiVentColors.amber.withOpacity(.32)),
          boxShadow: [
            BoxShadow(
              color: MimiVentColors.amber.withOpacity(.06),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: MimiVentColors.amber.withOpacity(.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.sync_problem_rounded,
                  color: MimiVentColors.amber, size: 19),
            ),
            const SizedBox(width: 11),
            const Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('环境未同步',
                        style: TextStyle(
                            color: MimiVentColors.amber,
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
                    SizedBox(height: 3),
                    Text('为避免误操作，控制和配置暂时锁定。',
                        style: TextStyle(
                            color: MimiVentColors.muted,
                            fontSize: 11,
                            height: 1.35)),
                  ],
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: _mismatchEnvironmentValue('APP 环境', c.profile.label)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.compare_arrows_rounded,
                  color: MimiVentColors.muted, size: 17),
            ),
            Expanded(
                child: _mismatchEnvironmentValue(
                    '设备环境', status.activeProfile.label)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: c.busy ? null : _switchDeviceToSelectedProfile,
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: const Text('切换设备环境',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                style: FilledButton.styleFrom(
                  backgroundColor: MimiVentColors.amber,
                  foregroundColor: MimiVentColors.darkText,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: c.busy ? null : _useDeviceProfile,
                icon: const Icon(Icons.device_hub_rounded, size: 16),
                label: const Text('App 跟随设备',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                style: OutlinedButton.styleFrom(
                  foregroundColor: MimiVentColors.mint,
                  side: BorderSide(color: MimiVentColors.mint.withOpacity(.35)),
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ]),
        ]),
      );

  Widget _mismatchEnvironmentValue(String label, String value) => Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1815),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white.withOpacity(.055)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style:
                    const TextStyle(color: MimiVentColors.muted, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  /// 纯展示卡片采用更明显的落影和轻微主题色外晕，与可点击的操作按钮区分。
  List<BoxShadow> _displayCardShadows(Color accent) => [
        BoxShadow(
          color: Colors.black.withOpacity(.62),
          blurRadius: 32,
          spreadRadius: 1,
          offset: const Offset(0, 14),
        ),
        BoxShadow(
          color: accent.withOpacity(.24),
          blurRadius: 28,
          spreadRadius: 2,
          offset: const Offset(0, 5),
        ),
      ];

  Widget _statusHero(DeviceStatus status) {
    final isOn = status.fan;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(21, 22, 20, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isOn
              ? const [Color(0xFF283523), Color(0xFF18241D)]
              : const [Color(0xFF18312A), Color(0xFF11221F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
            color: (isOn ? MimiVentColors.amber : MimiVentColors.mint)
                .withOpacity(.12)),
        boxShadow: isOn
            ? _displayCardShadows(MimiVentColors.amber)
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(.4),
                  blurRadius: 24,
                  offset: const Offset(0, 9),
                ),
                BoxShadow(
                  color: MimiVentColors.mint.withOpacity(.12),
                  blurRadius: 18,
                  spreadRadius: 1,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('MIMIVENT · STATUS',
                    style: TextStyle(
                        color: MimiVentColors.muted,
                        fontSize: 10,
                        letterSpacing: 1.5)),
                const SizedBox(height: 9),
                Text(
                    isOn
                        ? '风机运行中'
                        : status.mode == 'lock_off'
                            ? '持续关闭'
                            : '风机待机',
                    style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.6)),
                const SizedBox(height: 5),
                Text(DeviceStatusPresenter.phaseDescription(status),
                    style: const TextStyle(
                        color: MimiVentColors.muted, fontSize: 13)),
              ])),
          AnimatedContainer(
            duration: const Duration(milliseconds: 1800),
            curve: Curves.easeInOutCubic,
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (isOn ? MimiVentColors.amber : MimiVentColors.mint)
                  .withOpacity(.09),
              border: Border.all(
                  color: (isOn ? MimiVentColors.amber : MimiVentColors.mint)
                      .withOpacity(.26)),
            ),
            child: FanStatusRotor(
              isRunning: isOn,
              size: 38,
            ),
          ),
        ]),
        const SizedBox(height: 18),
        SizedBox(
          height: 26,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                _pill(
                    DeviceStatusPresenter.modeTagName(status.mode),
                    isOn || status.mode == 'timed_off'
                        ? MimiVentColors.amber
                        : MimiVentColors.mint),
                const SizedBox(width: 7),
                _pill(DeviceStatusPresenter.phaseTagText(status),
                    MimiVentColors.muted),
                const SizedBox(width: 7),
                _pill('蓝牙在线', MimiVentColors.mint,
                    icon: Icons.bluetooth_connected_rounded),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _tagShell(
    Widget content,
    Color color, {
    double backgroundOpacity = .09,
    double borderOpacity = .18,
  }) =>
      Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
            color: color.withOpacity(backgroundOpacity),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: color.withOpacity(borderOpacity))),
        child: content,
      );

  Widget _pill(String text, Color color, {IconData? icon}) => _tagShell(
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 10, color: color),
              const SizedBox(width: 3),
            ],
            Text(
              text,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                  color: color, fontSize: 9, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        color,
      );

  Widget _metricCard(
          {required String title,
          required String value,
          required String detail,
          required IconData icon,
          required Color accent}) =>
      Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
            color: MimiVentColors.surface,
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: Colors.white.withOpacity(.055)),
            boxShadow: _displayCardShadows(accent)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: accent, size: 17),
            const SizedBox(width: 7),
            Text(title,
                style:
                    const TextStyle(color: MimiVentColors.muted, fontSize: 12))
          ]),
          const SizedBox(height: 15),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: MimiVentColors.muted, fontSize: 10)),
        ]),
      );

  Widget _runtimeCard(DeviceStatus status) {
    final config = DeviceStatusPresenter.runtimeDescription(status);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
      decoration: BoxDecoration(
          color: const Color(0xFF10201D),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(.05)),
          boxShadow: _displayCardShadows(MimiVentColors.mint)),
      child: Column(children: [
        Row(children: [
          const Text('当前运行配置',
              style: TextStyle(fontSize: 10, color: MimiVentColors.muted)),
          const Spacer(),
          _tagShell(
            Text(c.profile.label,
                style: TextStyle(
                    fontSize: 9,
                    color: c.profile == TimingProfile.dev
                        ? MimiVentColors.amber
                        : MimiVentColors.mint,
                    fontWeight: FontWeight.w700)),
            c.profile == TimingProfile.dev
                ? MimiVentColors.amber
                : MimiVentColors.mint,
            backgroundOpacity: .1,
            borderOpacity: 0,
          ),
        ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(config.$1,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 3),
                Text(config.$2,
                    style: const TextStyle(
                        color: MimiVentColors.muted, fontSize: 11)),
              ])),
          Text(config.$3,
              style: const TextStyle(
                  color: MimiVentColors.mint,
                  fontSize: 17,
                  fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 9),
        Divider(height: 1, color: Colors.white.withOpacity(.07)),
        const SizedBox(height: 9),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _miniConfig('离开确认', status.leaveConfirmMs),
          _miniConfig('自动排风', status.autoExhaustMs),
          _miniConfig('临时排风', status.manualExhaustMs),
          _miniConfig('临时暂停', status.pauseMs),
          _miniConfig('启动冷静期', status.startupCooldownMs),
        ]),
      ]),
    );
  }

  Widget _miniConfig(String label, int time) => _tagShell(
        RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 9, color: MimiVentColors.muted),
            children: [
              TextSpan(text: '$label '),
              TextSpan(
                text: DurationFormatter.label(time),
                style: const TextStyle(
                    fontSize: 9,
                    color: Color(0xFFDCE9E3),
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        Colors.white,
        backgroundOpacity: .045,
        borderOpacity: .055,
      );

  Widget _sectionHeader(String title, String hint) => Row(children: [
        Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const Spacer(),
        Text(hint,
            style: const TextStyle(fontSize: 10, color: MimiVentColors.muted)),
      ]);

  Widget _autoButton(DeviceStatus status, bool mismatch) {
    final selected = status.mode == 'auto';
    return Material(
      color: selected ? const Color(0xFF9BE8CC) : MimiVentColors.surfaceRaised,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _canOperate(status, mismatch, allowCooldown: false)
            ? () => _runAction(ControlOperation.automatic)
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Row(children: [
            Icon(selected ? Icons.check_circle : Icons.autorenew_rounded,
                color:
                    selected ? const Color(0xFF12251E) : MimiVentColors.mint),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(selected ? '已启用自动感应' : '切换到自动感应',
                      style: TextStyle(
                          color:
                              selected ? const Color(0xFF12251E) : Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 15)),
                  const SizedBox(height: 3),
                  Text(selected ? '活动时立即停风；离开确认后排风' : '立即停止当前操作并恢复自动流程',
                      style: TextStyle(
                          color: selected
                              ? const Color(0xFF315C4A)
                              : MimiVentColors.muted,
                          fontSize: 11)),
                ])),
            Icon(Icons.arrow_forward_rounded,
                color:
                    selected ? const Color(0xFF12251E) : MimiVentColors.mint),
          ]),
        ),
      ),
    );
  }

  Widget _actionCard(
          {required Widget icon,
          required String title,
          required String detail,
          required bool selected,
          required Color accent,
          required bool enabled,
          required VoidCallback onTap}) =>
      Material(
        color: selected ? accent.withOpacity(.13) : MimiVentColors.surface,
        borderRadius: BorderRadius.circular(19),
        child: InkWell(
          borderRadius: BorderRadius.circular(19),
          onTap: enabled ? onTap : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 104),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(19),
                border: Border.all(
                    color: selected
                        ? accent.withOpacity(.55)
                        : Colors.white.withOpacity(.06),
                    width: selected ? 1.4 : 1)),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    icon,
                    const Spacer(),
                    if (selected)
                      Icon(Icons.check_circle, color: accent, size: 16)
                  ]),
                  const SizedBox(height: 12),
                  Text(title,
                      style: TextStyle(
                          color: enabled ? Colors.white : MimiVentColors.muted,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  const SizedBox(height: 3),
                  Text(detail,
                      style: TextStyle(
                          color: selected ? accent : MimiVentColors.muted,
                          fontSize: 11)),
                ]),
          ),
        ),
      );

  Widget _settingsCard(TimingSettings settings, bool mismatch) {
    final draft = c.draftSettings ?? settings;
    final canEdit = !mismatch && !c.busy;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 7, 15, 13),
      decoration: BoxDecoration(
          color: MimiVentColors.surface,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: Colors.white.withOpacity(.055))),
      child: Column(children: [
        _settingRow(
            '启动冷静期', '重启后保持风机关闭', 'startupCooldownMs', draft.startupCooldownMs,
            allowZero: false, enabled: canEdit),
        _settingRow('离开确认时间', 'PIR 连续 LOW 后开始排风', 'leaveConfirmMs',
            draft.leaveConfirmMs,
            allowZero: true, enabled: canEdit),
        _settingRow(
            '自动排风时长', '自动感应每轮运行时间', 'autoExhaustMs', draft.autoExhaustMs,
            allowZero: false, enabled: canEdit),
        _settingRow(
            '临时排风时长', '点击临时排风后自动停止', 'manualExhaustMs', draft.manualExhaustMs,
            allowZero: false, enabled: canEdit),
        _settingRow('临时暂停时长', '暂停到期后恢复自动感应', 'pauseMs', draft.pauseMs,
            allowZero: false, enabled: canEdit),
        const Divider(height: 15, color: Color(0x223E514A)),
        LayoutBuilder(builder: (context, constraints) {
          final status = Text(
            c.hasUnsavedSettings ? '有未保存的修改' : '设置已同步到设备',
            style: TextStyle(
              color: c.hasUnsavedSettings
                  ? MimiVentColors.amber
                  : MimiVentColors.muted,
              fontSize: 11,
            ),
          );
          final actions = Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(
                onPressed: canEdit && !c.busy ? _resetSettings : null,
                child: const Text('重置')),
            const SizedBox(width: 5),
            FilledButton.tonalIcon(
              onPressed: canEdit && c.hasUnsavedSettings && !c.busy
                  ? _saveSettings
                  : null,
              icon: c.busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined, size: 16),
              label: const Text('保存'),
            ),
          ]);
          final stacked =
              constraints.maxWidth < 380 || AppLayout.usesLargeText(context);
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                status,
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(children: [status, const Spacer(), actions]);
        }),
      ]),
    );
  }

  Widget _settingRow(String title, String description, String key, int value,
          {required bool allowZero, required bool enabled}) =>
      InkWell(
        onTap: enabled
            ? () => _editSetting(key, title, value, allowZero: allowZero)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color:
                              enabled ? Colors.white : MimiVentColors.muted)),
                  const SizedBox(height: 3),
                  Text(description,
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 10)),
                ])),
            const SizedBox(width: 8),
            Text(DurationFormatter.label(value),
                style: TextStyle(
                    color: enabled ? MimiVentColors.mint : MimiVentColors.muted,
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
            const SizedBox(width: 3),
            const Icon(Icons.chevron_right,
                color: MimiVentColors.muted, size: 17),
          ]),
        ),
      );

  bool _canOperate(DeviceStatus status, bool mismatch,
          {required bool allowCooldown}) =>
      !mismatch &&
      !c.busy &&
      (allowCooldown || status.phase != 'startup_cooldown');

  Widget _loadingPanel() => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
            color: MimiVentColors.surface,
            borderRadius: BorderRadius.circular(22)),
        child: const Column(children: [
          CircularProgressIndicator(color: MimiVentColors.mint),
          SizedBox(height: 14),
          Text('正在读取设备状态和时序配置', style: TextStyle(color: MimiVentColors.muted)),
        ]),
      );

  Widget _connectionErrorBanner() {
    final error = c.lastError?.toLowerCase() ?? '';
    final connectionLost = error.contains('not connected') ||
        error.contains('蓝牙未连接') ||
        error.contains('连接已断开');
    final title = connectionLost
        ? '蓝牙连接已断开'
        : c.connected
            ? '设备操作失败'
            : '设备连接失败';
    final detail = connectionLost
        ? '本次操作未执行，请重新连接设备。'
        : c.connected
            ? '设备未能完成这次操作，请检查连接后重试。'
            : '没有连接成功，请确认设备通电且蓝牙可用。';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2E2020),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MimiVentColors.red.withOpacity(.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_disabled_rounded,
              color: MimiVentColors.red, size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: MimiVentColors.red,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail,
                    style: const TextStyle(
                        color: MimiVentColors.muted,
                        fontSize: 10,
                        height: 1.25)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed:
                c.busy || _reconnectInProgress ? null : _showReconnectChoices,
            style: OutlinedButton.styleFrom(
              foregroundColor: MimiVentColors.red,
              side: BorderSide(color: MimiVentColors.red.withOpacity(.45)),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: _reconnectInProgress
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('重新连接',
                    style:
                        TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
