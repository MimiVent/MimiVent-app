import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/models.dart';

void main() {
  test('设备环境和 App 请求环境分别解析，DEV 不会被误判为正式', () {
    final status = DeviceStatus.fromJson({
      'fan': false,
      'pir': false,
      'mode': 'auto',
      'phase': 'armed',
      'activeProfile': 'dev',
      'viewProfile': 'production',
      'fanRunMs': 0,
      'remainingMs': 0,
      'durationMs': 0,
      'phaseDurationMs': 0,
      'startupCooldownMs': 5000,
      'leaveConfirmMs': 0,
      'autoExhaustMs': 10000,
      'manualExhaustMs': 10000,
      'pauseMs': 10000,
      'firmware': '0.2.0',
    });

    expect(status.activeProfile, TimingProfile.dev);
    expect(status.viewProfile, TimingProfile.production);
    expect(status.activeProfile == status.viewProfile, isFalse);
  });
}
