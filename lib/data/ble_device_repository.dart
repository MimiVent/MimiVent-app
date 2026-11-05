import '../api/mimivent_api.dart';
import 'models.dart';
import 'device_repository.dart';

/// 把固件 HTTP API 经由 BLE 传输，适配为控制器使用的 Repository。
class BleDeviceRepository implements DeviceRepository {
  BleDeviceRepository(this._api);

  final MimiVentApi _api;

  @override
  Future<DeviceStatus> getStatus(TimingProfile profile) =>
      _api.getStatus(profile);
  @override
  Future<TimingSettings> getSettings(TimingProfile profile) =>
      _api.getSettings(profile);
  @override
  Future<void> syncClock(TimingProfile profile) => _api.syncClock(profile);
  @override
  Future<Map<String, dynamic>> getStatistics(
    TimingProfile profile,
    String range, {
    int offset = 0,
  }) =>
      _api.getStatistics(profile, range, offset: offset);
  @override
  Future<Map<String, dynamic>> getStatisticsRange(
    TimingProfile profile, {
    required int from,
    required int to,
    required int tzOffsetSeconds,
  }) =>
      _api.getStatisticsRange(
        profile,
        from: from,
        to: to,
        tzOffsetSeconds: tzOffsetSeconds,
      );
  @override
  Future<DeviceEventPage> queryEvents(
          TimingProfile profile, DeviceEventQuery query) =>
      _api.queryEvents(profile, query);
  @override
  Future<void> saveSettings(TimingProfile profile, TimingSettings settings) =>
      _api.saveSettings(profile, settings);
  @override
  Future<void> resetSettings(TimingProfile profile) =>
      _api.resetSettings(profile);
  @override
  Future<void> setAuto(TimingProfile profile,
          {bool replace = false, bool switchProfile = false}) =>
      _api.setAuto(profile, replace: replace, switchProfile: switchProfile);
  @override
  Future<void> startTimed(TimingProfile profile, {bool replace = false}) =>
      _api.startTimed(profile, replace: replace);
  @override
  Future<void> startPause(TimingProfile profile, {bool replace = false}) =>
      _api.startPause(profile, replace: replace);
  @override
  Future<void> startFanTest(TimingProfile profile, {bool replace = false}) =>
      _api.startFanTest(profile, replace: replace);
  @override
  Future<void> armLockOff(TimingProfile profile) => _api.armLockOff(profile);
  @override
  Future<void> confirmLockOff(TimingProfile profile, {bool replace = false}) =>
      _api.confirmLockOff(profile, replace: replace);
  @override
  Future<void> cancelLockOff(TimingProfile profile) =>
      _api.cancelLockOff(profile);
}
