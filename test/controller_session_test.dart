import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimivent_app/data/device_repository.dart';
import 'package:mimivent_app/data/mimivent_controller.dart';
import 'package:mimivent_app/data/models.dart';
import 'package:mimivent_app/ble/mimivent_ble_manager.dart';
import 'package:mimivent_app/ble/ble_request_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('断开并快速重连时，旧会话不继续读配置或覆盖新状态', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    final oldStatus = Completer<DeviceStatus>();
    var statusCalls = 0;
    repository.onGetStatus = (_) {
      statusCalls++;
      if (statusCalls == 1) return Future.value(_status('old'));
      if (statusCalls == 2) return oldStatus.future;
      return Future.value(_status('new'));
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    final device = BluetoothDevice.fromId('device-id');

    await controller.connect(device);
    expect(repository.settingsCalls, 1);

    final oldRefresh = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    ble.setConnected(false);
    await controller.connect(device);
    expect(controller.status?.firmware, 'new');
    expect(repository.settingsCalls, 2);

    oldStatus.complete(_status('old-response'));
    await oldRefresh;

    // 旧状态读取一旦发现会话变化，就不应再发起下一条配置读取。
    expect(repository.settingsCalls, 2);
    expect(controller.status?.firmware, 'new');
    expect(controller.lastError, isNull);

    await controller.closeBluetoothSession();
    controller.dispose();
  });

  test('旧连接请求失败时不能覆盖新会话的错误/成功状态', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    final oldStatus = Completer<DeviceStatus>();
    var statusCalls = 0;
    repository.onGetStatus = (_) {
      statusCalls++;
      if (statusCalls == 1) return Future.value(_status('initial'));
      if (statusCalls == 2) return oldStatus.future;
      return Future.value(_status('current'));
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    final device = BluetoothDevice.fromId('device-id');

    await controller.connect(device);
    final oldConnect = controller.connect(device);
    await Future<void>.delayed(Duration.zero);
    ble.setConnected(false);
    await controller.connect(device);
    expect(controller.lastError, isNull);

    oldStatus.completeError(StateError('旧会话请求失败'));
    await oldConnect;

    expect(controller.status?.firmware, 'current');
    expect(controller.lastError, isNull);
    await controller.closeBluetoothSession();
    controller.dispose();
  });

  test('控制器销毁后返回的旧读取不再通知页面', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    final delayed = Completer<DeviceStatus>();
    var statusCalls = 0;
    repository.onGetStatus = (_) {
      statusCalls++;
      return statusCalls == 1
          ? Future.value(_status('connected'))
          : delayed.future;
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    await controller.connect(BluetoothDevice.fromId('dispose-device'));
    var notifications = 0;
    controller.addListener(() => notifications++);
    final refresh = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    final countAtDispose = notifications;

    delayed.complete(_status('late-response'));
    await refresh;
    await Future<void>.delayed(Duration.zero);

    expect(notifications, countAtDispose);
  });

  test('设备状态响应无效后暂停控制，成功刷新后恢复', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    var invalidResponse = false;
    repository.onGetStatus = (_) async {
      if (invalidResponse) throw const FormatException('状态字段缺失');
      return _status('0.2.0');
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    await controller.connect(BluetoothDevice.fromId('invalid-status-device'));

    invalidResponse = true;
    await controller.refresh();
    expect(controller.statusInvalid, isTrue);
    await expectLater(controller.setAuto(), throwsStateError);
    expect(repository.setAutoCalls, 0);

    invalidResponse = false;
    await controller.refresh();
    expect(controller.statusInvalid, isFalse);
    await controller.setAuto();
    expect(repository.setAutoCalls, 1);

    await controller.closeBluetoothSession();
    controller.dispose();
  });

  test('断连后返回的旧环境配置不覆盖重连后的配置', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    final oldSettings = Completer<TimingSettings>();
    var settingsCalls = 0;
    repository.onGetSettings = (_) {
      settingsCalls++;
      if (settingsCalls == 2) return oldSettings.future;
      return Future.value(_settings(settingsCalls == 1 ? 300000 : 120000));
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    final device = BluetoothDevice.fromId('settings-device');

    await controller.connect(device);
    final oldLoad = controller.loadSettings();
    await Future<void>.delayed(Duration.zero);
    ble.setConnected(false);
    await controller.connect(device);
    expect(controller.settings?.pauseMs, 120000);

    oldSettings.complete(_settings(60000));
    await oldLoad;
    expect(controller.settings?.pauseMs, 120000);

    await controller.closeBluetoothSession();
    controller.dispose();
  });

  test('持续关闭两步命令跨会话时不会向新连接发送确认命令', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    final prepare = Completer<void>();
    repository.onArmLockOff = (_) => prepare.future;
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    final device = BluetoothDevice.fromId('lock-device');
    await controller.connect(device);

    final operation = controller.enableLockOff();
    await Future<void>.delayed(Duration.zero);
    ble.setConnected(false);
    await controller.connect(device);
    prepare.complete();

    await expectLater(operation, throwsStateError);
    expect(repository.confirmLockOffCalls, 0);
    expect(controller.lastError, isNull);
    await controller.closeBluetoothSession();
    controller.dispose();
  });

  test('串行队列拒绝等待期间已经过期的请求并继续处理后续请求', () async {
    final queue = BleRequestQueue();
    final firstResponse = Completer<String>();
    var session = 1;
    var sent = 0;
    final first = queue.enqueue<String>(
      isSessionCurrent: () => session == 1,
      send: () {
        sent++;
        return firstResponse.future;
      },
    );
    await Future<void>.delayed(Duration.zero);
    final stale = queue.enqueue<String>(
      isSessionCurrent: () => session == 1,
      send: () async {
        sent++;
        return 'stale';
      },
    );
    session = 2;
    firstResponse.complete('first');

    expect(await first, isA<BleRequestSucceeded<String>>());
    final staleResult = await stale;
    expect(staleResult, isA<BleRequestRejected<String>>());
    expect(
        (staleResult as BleRequestRejected<String>).error, isA<StateError>());
    expect(sent, 1);

    final fresh = await queue.enqueue<String>(
      isSessionCurrent: () => session == 2,
      send: () async {
        sent++;
        return 'fresh';
      },
    );
    expect(fresh, isA<BleRequestSucceeded<String>>());
    expect((fresh as BleRequestSucceeded<String>).value, 'fresh');
    expect(sent, 2);
  });
}

DeviceStatus _status(String firmware) => DeviceStatus(
      fan: false,
      pir: false,
      mode: 'auto',
      phase: 'armed',
      activeProfile: TimingProfile.production,
      viewProfile: TimingProfile.production,
      fanRunMs: 0,
      remainingMs: 0,
      durationMs: 0,
      phaseDurationMs: 0,
      startupCooldownMs: 30000,
      leaveConfirmMs: 30000,
      autoExhaustMs: 120000,
      manualExhaustMs: 60000,
      pauseMs: 300000,
      firmware: firmware,
    );

TimingSettings _settings(int pauseMs) => TimingSettings(
      startupCooldownMs: 30000,
      leaveConfirmMs: 30000,
      autoExhaustMs: 120000,
      manualExhaustMs: 60000,
      pauseMs: pauseMs,
    );

class _FakeRepository implements DeviceRepository {
  Future<DeviceStatus> Function(TimingProfile profile)? onGetStatus;
  Future<TimingSettings> Function(TimingProfile profile)? onGetSettings;
  Future<void> Function(TimingProfile profile)? onArmLockOff;
  int settingsCalls = 0;
  int confirmLockOffCalls = 0;
  int setAutoCalls = 0;

  @override
  Future<DeviceStatus> getStatus(TimingProfile profile) =>
      onGetStatus?.call(profile) ?? Future.value(_status('default'));
  @override
  Future<TimingSettings> getSettings(TimingProfile profile) async {
    settingsCalls++;
    return onGetSettings?.call(profile) ??
        const TimingSettings(
          startupCooldownMs: 30000,
          leaveConfirmMs: 30000,
          autoExhaustMs: 120000,
          manualExhaustMs: 60000,
          pauseMs: 300000,
        );
  }

  @override
  Future<void> armLockOff(TimingProfile profile) async {
    final handler = onArmLockOff;
    if (handler != null) await handler(profile);
  }

  @override
  Future<void> cancelLockOff(TimingProfile profile) async {}
  @override
  Future<void> confirmLockOff(TimingProfile profile,
      {bool replace = false}) async {
    confirmLockOffCalls++;
  }

  @override
  Future<void> resetSettings(TimingProfile profile) async {}
  @override
  Future<void> saveSettings(
      TimingProfile profile, TimingSettings settings) async {}
  @override
  Future<void> setAuto(TimingProfile profile,
      {bool replace = false, bool switchProfile = false}) async {
    setAutoCalls++;
  }

  @override
  Future<void> startFanTest(TimingProfile profile,
      {bool replace = false}) async {}
  @override
  Future<void> startPause(TimingProfile profile,
      {bool replace = false}) async {}
  @override
  Future<void> startTimed(TimingProfile profile,
      {bool replace = false}) async {}
}

class _FakeBleManager extends MimiVentBleManager {
  bool _disposed = false;

  void setConnected(bool connected) {
    connectionStatus = connected
        ? BleConnectionStatus.connected
        : BleConnectionStatus.disconnected;
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> connect(BluetoothDevice device) async => setConnected(true);

  @override
  Future<void> stopScan() async {
    if (isScanning) setConnected(false);
  }

  @override
  Future<void> disconnect() async => setConnected(false);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
