// UI helpers are split into parts to keep the dashboard organized by responsibility.
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'dashboard_page.dart';

extension _DashboardActionSection on _DashboardPageState {
  /// 只引导连接，不把刚点击的操作排队，也不在连接完成后自动补发。
  Future<bool> _requireDeviceConnection() async {
    if (_deviceReady) return true;
    final accepted = await _confirm(
      title: '需要连接蓝牙',
      message: '连接 MimiVent 后才能控制风机和修改设置。',
      detail: '连接后请重新选择操作，当前操作不会自动执行。',
      confirm: '连接设备',
    );
    if (accepted && mounted) await _scanAndConnect();
    return false;
  }

  Future<void> _runAction(ControlOperation action,
      {bool replace = false}) async {
    if (!await _requireDeviceConnection() || !mounted) return;
    if (!c.profileMatches) {
      _toast('当前页面环境与设备不一致，请先切换环境');
      return;
    }
    if (c.status?.phase == 'startup_cooldown' &&
        !action.allowedDuringStartupCooldown) {
      _toast('开机冷静期中，风机保持关闭');
      return;
    }
    final sameTask = action.matches(c.status);
    // 再次点击当前相同的限时操作时，replace 会从现在起重新计满设置时长。
    // 不弹中断确认，也不把新操作排到旧计时之后。
    if (sameTask) replace = true;
    var lockAlreadyConfirmed = false;
    if (c.hasInterruptibleTask && !replace) {
      final locking = action == ControlOperation.persistentOff;
      final accepted = await _confirm(
        title: locking ? '停止当前流程并持续关闭？' : '停止当前流程并切换？',
        message: locking
            ? '当前正在进行${_taskName(c.status!)}。确认后会立即取消计时并持续关闭风机。'
            : '当前正在进行${_taskName(c.status!)}。确认后会立即取消当前计时并执行新操作。',
        detail: locking ? '持续关闭后不会自动恢复，需要手动启用自动感应。' : '操作不会排队，旧任务不会在新任务结束后继续。',
        confirm: locking ? '停止并关闭' : '停止并切换',
        danger: locking,
      );
      if (!accepted) return;
      replace = true;
      lockAlreadyConfirmed = locking;
    }
    try {
      switch (action) {
        case ControlOperation.automatic:
          final result = await c.executeOperation(action, replace: replace);
          if (result is OperationRejected) {
            _toast('操作失败：${result.reason}');
            break;
          }
          _toast('自动感应已恢复，风机已停止');
          break;
        case ControlOperation.exhaust:
          final result = await c.executeOperation(action, replace: replace);
          if (result is OperationRejected) {
            _toast('操作失败：${result.reason}');
            break;
          }
          _toast(sameTask ? '临时排风时间已重置' : '临时排风已启动');
          break;
        case ControlOperation.pause:
          final result = await c.executeOperation(action, replace: replace);
          if (result is OperationRejected) {
            _toast('操作失败：${result.reason}');
            break;
          }
          _toast(sameTask ? '临时暂停时间已重置' : '临时暂停已启动');
          break;
        case ControlOperation.forceExhaust:
          final result = await c.executeOperation(action, replace: replace);
          if (result is OperationRejected) {
            _toast('操作失败：${result.reason}');
            break;
          }
          _toast(sameTask ? '强制排风时间已重置，当前忽略 PIR' : '强制排风已启动，当前忽略 PIR');
          break;
        case ControlOperation.persistentOff:
          if (c.status?.mode == 'lock_off') {
            final accepted = await _confirm(
              title: '切换到自动感应？',
              message: '确认后将解除持续关闭，恢复 PIR 自动感应。',
              confirm: '恢复自动感应',
            );
            if (!accepted) break;
            await c.setAuto(replace: true);
            _toast('自动感应已恢复，风机已停止');
          } else {
            await _lockOff(
              replace: replace,
              alreadyConfirmed: lockAlreadyConfirmed,
            );
          }
          break;
      }
    } catch (error) {
      _toast('操作失败：$error');
    }
  }

  Future<void> _lockOff({
    required bool replace,
    bool alreadyConfirmed = false,
  }) async {
    if (!alreadyConfirmed) {
      final accepted = await _confirm(
        title: '启用持续关闭？',
        message: '风机将保持关闭，PIR 自动感应暂停。',
        detail: '持续关闭期间不会自动恢复，需要手动启用自动感应。',
        confirm: '关闭风机',
        danger: true,
      );
      if (!accepted) return;
    }
    await c.enableLockOff(replace: replace);
    _toast('持续关闭已启用');
  }

  String _taskName(DeviceStatus status) {
    if (status.mode == 'auto' && status.phase == 'clear_confirm') return '离开确认';
    if (status.mode == 'auto' && status.phase == 'exhausting') return '自动排风';
    return switch (status.mode) {
      'timed_on' => '临时排风',
      'timed_off' => '临时暂停',
      'force_test' => '强制排风',
      _ => '当前运行流程',
    };
  }

  Future<void> _switchProfile(TimingProfile next) async {
    if (!await _requireDeviceConnection() || !mounted) return;
    if (next == c.profile) return;
    final accepted = await _confirm(
      title: '切换到${next.label}？',
      message: '切换后会立即停止当前操作，并取消排风或暂停倒计时。',
      detail: '设备会进入目标环境的自动感应。正在执行的任务不会排队。',
      confirm: '停止并切换',
    );
    if (!accepted) return;
    try {
      await c.switchProfile(next);
      _toast('已切换到${next.label}');
    } catch (error) {
      _toast('切换失败：$error');
    }
  }

  Future<void> _useDeviceProfile() async {
    await c.followDeviceProfile();
  }

  Future<void> _switchDeviceToSelectedProfile() async {
    final accepted = await _confirm(
      title: '切换设备到${c.profile.label}？',
      message: '设备将立即停止当前流程，并切换到 App 当前选择的环境。',
      detail: '切换完成后会进入该环境的自动感应。',
      confirm: '停止并切换',
    );
    if (!accepted) return;
    try {
      await c.switchDeviceToSelectedProfile();
      _toast('设备已切换到${c.profile.label}');
    } catch (error) {
      _toast('切换失败：$error');
    }
  }

  Future<int?> _pickTime(
      {required String title,
      required int current,
      required bool allowZero}) async {
    final options = timeOptions
        .where((option) => allowZero || option.milliseconds != 0)
        .toList();
    var selected = options.indexWhere((item) => item.milliseconds == current);
    if (selected < 0) selected = 0;
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF142420),
      builder: (context) {
        final availableHeight = MediaQuery.sizeOf(context).height;
        final pickerHeight =
            availableHeight < 420 ? availableHeight * .82 : 330.0;
        return SafeArea(
            child: SizedBox(
          height: pickerHeight,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(children: [
                SizedBox(
                  width: 68,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                SizedBox(
                  width: 68,
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, options[selected].milliseconds),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(68, 40),
                      padding: EdgeInsets.zero,
                    ),
                    child: const Text('完成'),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: CupertinoPicker(
                scrollController:
                    FixedExtentScrollController(initialItem: selected),
                itemExtent: 48,
                selectionOverlay: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                        horizontal: BorderSide(
                            color: MimiVentColors.mint.withOpacity(.45))),
                  ),
                ),
                onSelectedItemChanged: (index) => selected = index,
                children: options
                    .map((item) => Center(
                          child: Text(item.label,
                              style: const TextStyle(
                                  fontSize: 20, color: Colors.white)),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
          ]),
        ));
      },
    );
  }

  Future<void> _editSetting(String key, String title, int value,
      {bool allowZero = false}) async {
    if (!await _requireDeviceConnection() || !mounted) return;
    final picked =
        await _pickTime(title: title, current: value, allowZero: allowZero);
    if (picked != null) await c.updateSetting(key, picked);
  }

  Future<void> _saveSettings() async {
    if (!await _requireDeviceConnection() || !mounted) return;
    try {
      await c.saveSettings();
      _toast('时序设置已保存');
    } catch (error) {
      _toast('保存失败：$error');
    }
  }

  Future<void> _resetSettings() async {
    if (!await _requireDeviceConnection() || !mounted) return;
    final accepted = await _confirm(
      title: '重置当前环境配置？',
      message: '五项时序将恢复到固件默认值并保存到设备。',
      detail: '另一环境的时序不会改变。',
      confirm: '重置配置',
    );
    if (!accepted) return;
    try {
      await c.resetSettings();
      _toast('当前环境已恢复默认配置');
    } catch (error) {
      _toast('重置失败：$error');
    }
  }
}
