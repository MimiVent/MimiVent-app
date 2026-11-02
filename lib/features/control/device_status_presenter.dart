import '../../core/formatting/duration_formatter.dart';
import '../../data/models.dart';

/// 将固件状态映射成页面文字，避免每张卡片重复编写状态判断。
class DeviceStatusPresenter {
  const DeviceStatusPresenter._();

  static String modeTagName(String mode) => switch (mode) {
        'auto' => '自动',
        'timed_on' => '排风',
        'timed_off' => '暂停',
        'force_test' => '强排',
        'lock_off' => '持续关闭',
        _ => '未连接',
      };

  static String phaseTagText(DeviceStatus status, {int? remainingMs}) {
    final remaining = remainingMs ?? status.remainingMs;
    if (status.phase == 'startup_cooldown') {
      return '冷静 ${DurationFormatter.clock(remaining)}';
    }
    if (status.mode == 'timed_on' || status.mode == 'force_test') {
      return '剩余 ${DurationFormatter.clock(remaining)}';
    }
    if (status.mode == 'timed_off') return '暂停中';
    if (status.mode == 'lock_off') return '手动恢复';
    if (status.phase == 'occupied') return '活动中';
    if (status.phase == 'clear_confirm') {
      return '离开确认 ${DurationFormatter.clock(remaining)}';
    }
    if (status.phase == 'exhausting') {
      return '排风中 ${DurationFormatter.clock(remaining)}';
    }
    return status.pir ? '等待离开' : '待机';
  }

  static String phaseDescription(DeviceStatus status, {int? remainingMs}) {
    final remaining = remainingMs ?? status.remainingMs;
    if (status.phase == 'startup_cooldown') {
      return '开机冷静期 · ${DurationFormatter.clock(remaining)}';
    }
    if (status.mode == 'timed_on') {
      return '临时排风 · ${DurationFormatter.clock(remaining)}';
    }
    if (status.mode == 'timed_off') {
      return '暂停剩余 · ${DurationFormatter.clock(remaining)}';
    }
    if (status.mode == 'force_test') {
      return '强制排风 · 剩余 ${DurationFormatter.clock(remaining)}';
    }
    if (status.mode == 'lock_off') return '持续关闭 · 手动恢复';
    if (status.phase == 'occupied') return '检测到活动，风机保持停止';
    if (status.phase == 'clear_confirm') {
      return '离开确认 · ${DurationFormatter.clock(remaining)}';
    }
    if (status.phase == 'exhausting') {
      return '自动排风 · ${DurationFormatter.clock(remaining)}';
    }
    return status.pir ? '检测到活动，等待离开' : '等待下一次活动';
  }

  static (String, String, String) runtimeDescription(DeviceStatus status,
      {int? remainingMs}) {
    final remaining = remainingMs ?? status.remainingMs;
    if (status.phase == 'startup_cooldown') {
      return (
        '开机冷静期',
        '风机保持关闭，结束后开始自动感应',
        DurationFormatter.label(status.phaseDurationMs),
      );
    }
    if (status.mode == 'timed_on') {
      return (
        '临时排风',
        '限时运行；PIR 活动时立即停风',
        DurationFormatter.label(status.durationMs),
      );
    }
    if (status.mode == 'timed_off') {
      return (
        '临时暂停',
        '暂停到期后恢复自动感应',
        DurationFormatter.label(status.durationMs),
      );
    }
    if (status.mode == 'force_test') {
      return (
        '强制排风',
        '本次运行忽略 PIR',
        DurationFormatter.clock(remaining),
      );
    }
    if (status.mode == 'lock_off') {
      return ('持续关闭', '风机保持关闭，需要手动恢复', '手动恢复');
    }
    if (status.phase == 'clear_confirm') {
      return (
        '自动感应 · 离开确认',
        'PIR 连续 LOW 后开始排风',
        DurationFormatter.label(status.phaseDurationMs),
      );
    }
    if (status.phase == 'exhausting') {
      return (
        '自动排风',
        '检测到活动时会立即停风',
        DurationFormatter.label(status.phaseDurationMs),
      );
    }
    if (status.phase == 'occupied') {
      return ('检测到活动', 'PIR 保持 HIGH，风机已停止', '等待离开');
    }
    return ('自动感应待机', '等待 PIR 检测到下一次活动', '等待触发');
  }
}
