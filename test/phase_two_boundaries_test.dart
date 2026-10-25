import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/models.dart';
import 'package:mimivent_app/data/settings_draft.dart';
import 'package:mimivent_app/features/connection/connection_presentation.dart';
import 'package:mimivent_app/features/control/control_operation.dart';

void main() {
  const status = DeviceStatus(
    fan: false,
    pir: false,
    mode: 'timed_on',
    phase: 'manual',
    activeProfile: TimingProfile.production,
    viewProfile: TimingProfile.production,
    fanRunMs: 1000,
    remainingMs: 9000,
    durationMs: 10000,
    phaseDurationMs: 10000,
    startupCooldownMs: 30000,
    leaveConfirmMs: 30000,
    autoExhaustMs: 120000,
    manualExhaustMs: 60000,
    pauseMs: 300000,
    firmware: '0.2.0',
  );

  test('同类限时操作重置，常规操作不匹配', () {
    expect(ControlOperation.exhaust.matches(status), isTrue);
    expect(ControlOperation.pause.matches(status), isFalse);
    expect(ControlOperation.forceExhaust.matches(status), isFalse);
    expect(hasInterruptibleOperation(status), isTrue);
    expect(ControlOperation.forceExhaust.allowedDuringStartupCooldown, isTrue);
    expect(ControlOperation.exhaust.allowedDuringStartupCooldown, isFalse);
  });

  test('设置草稿与已保存值隔离，保存或更新后 dirty 状态准确', () {
    const original = TimingSettings(
      startupCooldownMs: 30000,
      leaveConfirmMs: 30000,
      autoExhaustMs: 120000,
      manualExhaustMs: 60000,
      pauseMs: 300000,
    );
    final edited = SettingsDraft(saved: original, value: original)
        .update('pauseMs', 60000);
    expect(edited.isDirty, isTrue);
    expect(edited.saved.pauseMs, 300000);
    expect(edited.value.pauseMs, 60000);
    expect(edited.markSaved(edited.value).isDirty, isFalse);
    expect(edited.update('unknown', 1).value.pauseMs, 60000);
  });

  test('连接呈现优先级：连接中、已连接、扫描中、断开', () {
    expect(
      connectionPresentation(connected: true, connecting: true, scanning: true),
      ConnectionPresentation.connecting,
    );
    expect(
      connectionPresentation(
          connected: true, connecting: false, scanning: true),
      ConnectionPresentation.connected,
    );
    expect(
      connectionPresentation(
          connected: false, connecting: false, scanning: true),
      ConnectionPresentation.scanning,
    );
    expect(
      connectionPresentation(
          connected: false, connecting: false, scanning: false),
      ConnectionPresentation.disconnected,
    );
  });
}
