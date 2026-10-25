import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/models.dart';

void main() {
  test('设备状态保留固件通过 BLE /api/status 返回的版本号', () {
    final status = DeviceStatus.fromJson({...validStatus, 'firmware': '0.2.0'});

    expect(status.firmware, '0.2.0');
  });

  test('缺少关键字段时拒绝构造状态，不回退为看似有效的默认值', () {
    final incomplete = Map<String, dynamic>.from(validStatus)..remove('fan');

    expect(() => DeviceStatus.fromJson(incomplete), throwsFormatException);
  });

  test('未知设备环境或非法时长会被拒绝', () {
    expect(
      () => DeviceStatus.fromJson({...validStatus, 'activeProfile': 'other'}),
      throwsFormatException,
    );
    expect(
      () => DeviceStatus.fromJson({...validStatus, 'pauseMs': 12345}),
      throwsFormatException,
    );
  });

  test('配置关键字段缺失或时间不在固件选项内时拒绝加载', () {
    expect(
      () => TimingSettings.fromJson({
        'startupCooldownMs': 30000,
        'leaveConfirmMs': 0,
        'autoExhaustMs': 120000,
        'manualExhaustMs': 60000,
      }),
      throwsFormatException,
    );
    expect(
      () => TimingSettings.fromJson({
        'startupCooldownMs': 30000,
        'leaveConfirmMs': 0,
        'autoExhaustMs': 120000,
        'manualExhaustMs': 60000,
        'pauseMs': 1,
      }),
      throwsFormatException,
    );
  });
}

const validStatus = <String, dynamic>{
  'fan': false,
  'pir': false,
  'mode': 'auto',
  'phase': 'armed',
  'activeProfile': 'production',
  'viewProfile': 'production',
  'fanRunMs': 0,
  'remainingMs': 0,
  'durationMs': 0,
  'phaseDurationMs': 0,
  'startupCooldownMs': 30000,
  'leaveConfirmMs': 30000,
  'autoExhaustMs': 120000,
  'manualExhaustMs': 60000,
  'pauseMs': 300000,
};
