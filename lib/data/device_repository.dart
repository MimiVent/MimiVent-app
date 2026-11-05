import 'models.dart';

/// 控制器依赖的设备能力边界，BLE 是当前唯一实现。
abstract interface class DeviceRepository {
  Future<DeviceStatus> getStatus(TimingProfile profile);
  Future<TimingSettings> getSettings(TimingProfile profile);
  Future<void> syncClock(TimingProfile profile);
  Future<Map<String, dynamic>> getStatistics(
    TimingProfile profile,
    String range, {
    int offset = 0,
  });
  Future<Map<String, dynamic>> getStatisticsRange(
    TimingProfile profile, {
    required int from,
    required int to,
    required int tzOffsetSeconds,
  });
  Future<DeviceEventPage> queryEvents(
      TimingProfile profile, DeviceEventQuery query);
  Future<void> saveSettings(TimingProfile profile, TimingSettings settings);
  Future<void> resetSettings(TimingProfile profile);
  Future<void> setAuto(TimingProfile profile,
      {bool replace = false, bool switchProfile = false});
  Future<void> startTimed(TimingProfile profile, {bool replace = false});
  Future<void> startPause(TimingProfile profile, {bool replace = false});
  Future<void> startFanTest(TimingProfile profile, {bool replace = false});
  Future<void> armLockOff(TimingProfile profile);
  Future<void> confirmLockOff(TimingProfile profile, {bool replace = false});
  Future<void> cancelLockOff(TimingProfile profile);
}
