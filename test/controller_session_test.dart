import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mimivent_app/features/statistics/presentation/statistics_page.dart';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimivent_app/data/device_repository.dart';
import 'package:mimivent_app/data/mimivent_controller.dart';
import 'package:mimivent_app/data/models.dart';
import 'package:mimivent_app/data/statistics_query.dart';
import 'package:mimivent_app/ble/mimivent_ble_manager.dart';
import 'package:mimivent_app/ble/ble_request_queue.dart';
import 'package:mimivent_app/features/control/control_operation.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_transport.dart';
import 'package:mimivent_app/features/local_network/wifi_binding.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('NAS 环境切换同时更新设置和状态，旧缓存不回退环境', () async {
    final gateway = _FakeNasGateway();
    gateway.onReadPath = (_) async => {
          ...gateway.state,
          'activeProfile': 'dev',
          'viewProfile': 'dev',
          'startupCooldownMs': 5000,
          'leaveConfirmMs': 0,
          'autoExhaustMs': 10000,
          'manualExhaustMs': 10000,
          'pauseMs': 10000
        };
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    addTearDown(controller.dispose);
    await controller.activateNasMqtt(_binding());
    final mismatches = <bool>[];
    controller.addListener(() => mismatches.add(controller.profileMatches));
    await controller.switchProfile(TimingProfile.dev);
    expect(controller.profile, TimingProfile.dev);
    expect(controller.settings?.pauseMs, 10000);
    expect(mismatches, everyElement(isTrue));
    await controller.refresh();
    expect(controller.profile, TimingProfile.dev);
    expect(controller.status?.activeProfile, TimingProfile.dev);
  });

  test('NAS 重置时间设置无需蓝牙，等待回执时显示正在执行', () async {
    final gateway = _FakeNasGateway();
    final response = Completer<NasGatewayHttpResult?>();
    gateway.onWrite = () => response.future;
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    addTearDown(controller.dispose);
    await controller.activateNasMqtt(_binding());
    final resetting = controller.resetSettings();
    await Future<void>.delayed(Duration.zero);
    expect(controller.busy, isTrue);
    expect(controller.pendingNasMqttAction, '重置时间设置');
    expect(controller.nasMqttWriteInFlight, isTrue);
    response.complete(const NasGatewayHttpResult(200, {'ok': true}));
    await resetting;
    expect(controller.settings?.manualExhaustMs, 60000);
    expect(controller.pendingNasMqttAction, isNull);
    expect(controller.hasPendingNasMqttRequest, isFalse);
    expect(controller.busy, isFalse);
  });

  test('相同范围的并发调用等待同一次真实查询完成', () async {
    final gateway = _FakeNasGateway();
    gateway.state.addAll({'statsRangeApiVersion': 2, 'tzOffsetSeconds': 28800});
    final response = Completer<Map<String, dynamic>>();
    var calls = 0;
    gateway.onReadPath = (_) {
      calls++;
      return response.future;
    };
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    addTearDown(controller.dispose);
    await controller.activateNasMqtt(_binding());
    final query =
        StatisticsQuery.today(now: 1794390000, tzOffsetSeconds: 28800);
    final first = controller.refreshStatisticsRange(query);
    var secondFinished = false;
    final second = controller
        .refreshStatisticsRange(query)
        .then((_) => secondFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(secondFinished, isFalse);
    expect(calls, 1);
    response.complete({'apiVersion': 2});
    await Future.wait([first, second]);
  });

  test('已切走的排队范围不会发给 NAS', () async {
    final gateway = _FakeNasGateway();
    gateway.state.addAll({'statsRangeApiVersion': 2, 'tzOffsetSeconds': 28800});
    final response = Completer<Map<String, dynamic>>();
    var calls = 0;
    gateway.onReadPath = (_) {
      calls++;
      return response.future;
    };
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    addTearDown(controller.dispose);
    await controller.activateNasMqtt(_binding());
    final first = controller.refreshStatisticsRange(
        StatisticsQuery.today(now: 1794390000, tzOffsetSeconds: 28800));
    var visible = true;
    final obsolete = controller.refreshStatisticsRange(
        StatisticsQuery.yesterday(now: 1794390000, tzOffsetSeconds: 28800),
        shouldRead: () => visible);
    final cancelled = expectLater(obsolete, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    visible = false;
    response.complete({'apiVersion': 2});
    await first;
    await cancelled;
    expect(calls, 1);
  });

  test('设备明确拒绝限时任务切换时返回确认意图，不自动重发', () async {
    final gateway = _FakeNasGateway()
      ..writeResult = const NasGatewayHttpResult(
          409, {'error': '当前有限时任务，请先确认停止并切换'},
          commandOutcomeKnown: true);
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    addTearDown(controller.dispose);
    await controller.activateNasMqtt(_binding());
    final result =
        await controller.executeOperation(ControlOperation.automatic);
    expect(result, isA<OperationNeedsReplacement>());
    expect(gateway.writeCalls, 1);
    expect(controller.hasPendingNasMqttRequest, isFalse);
  });

  test('NAS 统计查询等待期间控制无需等待查询完成', () async {
    final gateway = _FakeNasGateway();
    gateway.state.addAll({'statsRangeApiVersion': 2, 'tzOffsetSeconds': 28800});
    final response = Completer<Map<String, dynamic>>();
    gateway.onReadPath = (_) => response.future;
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    addTearDown(controller.dispose);
    await controller.activateNasMqtt(_binding());
    final query =
        StatisticsQuery.today(now: 1794390000, tzOffsetSeconds: 28800);
    final reading = controller.refreshStatisticsRange(query);
    await Future<void>.delayed(Duration.zero);
    try {
      await controller.setAuto().timeout(const Duration(seconds: 1));
      expect(gateway.writeCalls, 1);
      expect(response.isCompleted, isFalse);
    } finally {
      response.complete({'apiVersion': 2});
      await reading;
    }
  });

  testWidgets('新版今日事件分页沿用范围游标，首批失败可重试并加载后续页', (tester) async {
    final gateway = _FakeNasGateway();
    gateway.state.addAll({'statsRangeApiVersion': 2, 'tzOffsetSeconds': 28800});
    var eventCalls = 0;
    final eventPaths = <Uri>[];
    gateway.onReadPath = (path) async {
      final uri = Uri.parse(path);
      if (uri.path == '/api/stats/range') {
        return {
          'apiVersion': 2,
          'from': int.parse(uri.queryParameters['from']!),
          'to': int.parse(uri.queryParameters['to']!),
          'dayCount': 1,
          'bucketHours': 1,
          'summary': <String, dynamic>{},
          'buckets': [],
          'coverage': <String, dynamic>{},
          'deviceId': 'dataset',
          'dataEpoch': 'epoch'
        };
      }
      eventPaths.add(uri);
      eventCalls++;
      if (eventCalls == 1) {
        throw const NasGatewayException('DEVICE_QUERY_TIMEOUT', '设备查询超时');
      }
      final more = uri.queryParameters['beforeId'] == null;
      return {
        'events': [
          for (final id in (more ? [10, 9] : [8]))
            {
              'id': id,
              'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              'kind': 'activity',
              'state': 'completed',
              'durationSeconds': 1
            }
        ],
        'total': 3,
        'hasMore': more,
        'nextCursor': more ? 9 : null
      };
    };
    final controller = MimiVentController(
        bleManager: _FakeBleManager(),
        deviceRepository: _FakeRepository(),
        nasGatewayTransport: gateway);
    await controller.activateNasMqtt(_binding());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatisticsPage(
                controller: controller, active: true, appVersion: '0.7.6'))));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
            of: find.byKey(const PageStorageKey('statistics-page')),
            matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('事件加载失败，点击重试'), 350,
        scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('事件加载失败，点击重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件加载失败，点击重试'));
    await tester.pumpAndSettle();
    // 首批事件只存范围缓存，旧版 mode 缓存为空，仍应出现可用分页入口。
    expect(controller.statisticsFor('today'), isNull);
    await tester.drag(scrollable, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(eventPaths.last.queryParameters['beforeId'], '9');
    expect(eventPaths.last.queryParameters['limit'], '8');
    expect(find.text('已显示全部可用事件'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test('范围缓存隔离设备，批次变化后丢弃旧查询的迟到响应', () async {
    final ble = _FakeBleManager()
      ..connectionStatus = BleConnectionStatus.connected;
    final repository = _FakeRepository();
    final controller =
        MimiVentController(bleManager: ble, deviceRepository: repository);
    controller.status = _status('0.7.0')
        .copyWith(statsRangeApiVersion: 2, tzOffsetSeconds: 28800);
    final query =
        StatisticsQuery.today(now: 1793287800, tzOffsetSeconds: 28800);
    final other =
        StatisticsQuery.yesterday(now: 1793287800, tzOffsetSeconds: 28800);
    repository.onRange = (_) async =>
        {'apiVersion': 2, 'deviceId': 'physical-device', 'dataEpoch': 'old'};
    await controller.refreshStatisticsRange(query);
    expect(controller.statisticsRangeFor(query)?['dataEpoch'], 'old');
    ble.deviceIdentity = 'device-b';
    expect(controller.statisticsRangeFor(query), isNull);
    // 同一硬件由另一个连接身份访问（例如 BLE/WiFi 切换）。
    await controller.refreshStatisticsRange(query);
    ble.deviceIdentity = 'device-a';
    expect(controller.statisticsRangeFor(query)?['dataEpoch'], 'old');
    final delayed = Completer<Map<String, dynamic>>();
    repository.onRange = (_) => delayed.future;
    final pending = controller.refreshStatisticsRange(other);
    // 范围读取先检查本地缓存，再启动 BLE 请求。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    repository.onRange = (_) async =>
        {'apiVersion': 2, 'deviceId': 'physical-device', 'dataEpoch': 'new'};
    await controller.refreshStatisticsRange(query);
    delayed.complete(
        {'apiVersion': 2, 'deviceId': 'physical-device', 'dataEpoch': 'old'});
    await pending;
    expect(controller.statisticsRangeFor(query)?['dataEpoch'], 'new');
    expect(controller.statisticsRangeFor(other), isNull);
    ble.deviceIdentity = 'device-b';
    expect(controller.statisticsRangeFor(query), isNull);
    controller.dispose();
  });

  test('统计范围先恢复本地快照，再用当前设备结果刷新', () async {
    final query =
        StatisticsQuery.today(now: 1793287800, tzOffsetSeconds: 28800);
    final ble = _FakeBleManager()
      ..connectionStatus = BleConnectionStatus.connected;
    final firstRepository = _FakeRepository()
      ..onRange = (_) async => {
            'apiVersion': 2,
            'deviceId': 'dataset-1',
            'dataEpoch': 'epoch-1',
            'from': query.from,
            'to': query.to,
            'tzOffsetSeconds': query.tzOffsetSeconds,
            'buckets': [],
          };
    final first =
        MimiVentController(bleManager: ble, deviceRepository: firstRepository);
    first.status = _status('0.7.0')
        .copyWith(statsRangeApiVersion: 2, tzOffsetSeconds: 28800);
    await first.refreshStatisticsRange(query);
    await Future<void>.delayed(Duration.zero);
    first.dispose();

    final pending = Completer<Map<String, dynamic>>();
    final secondRepository = _FakeRepository()..onRange = (_) => pending.future;
    final secondBle = _FakeBleManager()
      ..connectionStatus = BleConnectionStatus.connected;
    final second = MimiVentController(
        bleManager: secondBle, deviceRepository: secondRepository);
    addTearDown(second.dispose);
    second.status = _status('0.7.0')
        .copyWith(statsRangeApiVersion: 2, tzOffsetSeconds: 28800);
    final refresh = second.refreshStatisticsRange(query);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(second.statisticsRangeFor(query)?['deviceId'], 'dataset-1');
    expect(second.statisticsRangeUpdatedAtFor(query), isNotNull);
    pending.complete({
      'apiVersion': 2,
      'deviceId': 'dataset-1',
      'dataEpoch': 'epoch-1',
      'from': query.from,
      'to': query.to,
      'tzOffsetSeconds': query.tzOffsetSeconds,
      'buckets': [],
    });
    await refresh;
  });

  test('Dashboard WiFi 状态只从 NAS 网关读取', () async {
    final gateway = _FakeNasGateway();
    final controller = MimiVentController(
      bleManager: _FakeBleManager(),
      deviceRepository: _FakeRepository(),
      nasGatewayTransport: gateway,
    );
    await controller.activateNasMqtt(_binding());
    expect(controller.status?.firmware, '0.7.1');
    expect(gateway.readCalls, 1);
    await controller.closeBluetoothSession();
    controller.deactivateNasMqtt();
    controller.dispose();
  });

  test('NAS MQTT 会话结束后迟到的状态不会覆盖新会话', () async {
    final gateway = _FakeNasGateway();
    final controller = MimiVentController(
      bleManager: _FakeBleManager(),
      deviceRepository: _FakeRepository(),
      nasGatewayTransport: gateway,
    );
    await controller.activateNasMqtt(_binding());

    final delayedRead = Completer<NasGatewayHttpResult?>();
    gateway.pendingRead = delayedRead;
    final refresh = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.readCalls, 2);

    controller.deactivateNasMqtt();
    controller.status = _status('0.7.2');
    delayedRead.complete(NasGatewayHttpResult(200, {
      ..._gatewayState(),
      'firmware': '0.7.0',
    }));
    await refresh;

    expect(controller.status?.firmware, '0.7.2');
    controller.dispose();
  });

  test('Dashboard WiFi 设置复用 NAS MQTT 状态快照，不请求设备 HTTPS', () async {
    final gateway = _FakeNasGateway();
    final repository = _FakeRepository();
    final controller = MimiVentController(
      bleManager: _FakeBleManager(),
      deviceRepository: repository,
      nasGatewayTransport: gateway,
    );
    await controller.activateNasMqtt(_binding());
    final readsBefore = gateway.readCalls;

    await controller.loadSettings();

    expect(gateway.readCalls, readsBefore + 1);
    expect(controller.settings?.manualExhaustMs, 60000);
    expect(repository.settingsCalls, 0);
    controller.deactivateNasMqtt();
    controller.dispose();
  });

  test('Dashboard 对过期 NAS 快照显示缓存状态并保留样本年龄', () async {
    final gateway = _FakeNasGateway()
      ..state = {
        ..._gatewayState(),
        'stateFreshness': 'stale',
        'stale': true,
        'stateAgeMs': 18000,
      };
    final controller = MimiVentController(
      bleManager: _FakeBleManager(),
      deviceRepository: _FakeRepository(),
      nasGatewayTransport: gateway,
    );
    await expectLater(controller.activateNasMqtt(_binding()),
        throwsA(isA<NasGatewayException>()));
    expect(controller.nasStateStale, isTrue);
    expect(controller.nasStateAgeMs, 18000);
    controller.deactivateNasMqtt();
    controller.dispose();
  });

  test('Dashboard NAS MQTT 控制结果未知时保留 requestId 并阻止新命令', () async {
    final gateway = _FakeNasGateway()..writeUnknown = true;
    final controller = MimiVentController(
      bleManager: _FakeBleManager(),
      deviceRepository: _FakeRepository(),
      nasGatewayTransport: gateway,
    );
    await controller.activateNasMqtt(_binding());
    final first = await controller.executeOperation(ControlOperation.exhaust);
    final second = await controller.executeOperation(ControlOperation.pause);
    expect(first, isA<OperationRejected>());
    expect(second, isA<OperationRejected>());
    expect(gateway.writeCalls, 1);
    expect(gateway.queryCalls, 1);
    await controller.closeBluetoothSession();
    controller.deactivateNasMqtt();
    controller.dispose();
  });

  test('OTA 传输层重连后先校时再恢复配置，后续轮询不重复校时', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    final order = <String>[];
    repository.onSyncClock = (_) async {
      order.add('clock');
    };
    repository.onGetSettings = (_) async {
      order.add('settings');
      return _settings(300000);
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    // 模拟 OTA 管理器直接恢复 BLE，会绕过 controller.connect。
    ble.setConnected(true);
    await controller.refresh();
    expect(order, ['clock', 'settings']);
    await controller.refresh();
    expect(order, ['clock', 'settings']);
    await controller.closeBluetoothSession();
    controller.dispose();
  });

  test('重连校时期间断开后不再读取旧会话配置', () async {
    final ble = _FakeBleManager();
    final repository = _FakeRepository();
    repository.onSyncClock = (_) async {
      ble.setConnected(false);
    };
    final controller = MimiVentController(
      bleManager: ble,
      deviceRepository: repository,
    );
    ble.setConnected(true);
    await controller.refresh();
    expect(repository.settingsCalls, 0);
    expect(controller.settings, isNull);
    controller.dispose();
  });

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

WifiBinding _binding() => WifiBinding(
      deviceId: '0123456789abcdef0123456789abcdef',
      tokenId: 'abcdef0123456789abcdef0123456789',
      token: List.filled(43, 'A').join(),
      pin: List.filled(64, 'a').join(),
      host: '192.168.2.5',
      clientId: 'test-client',
      state: 'active',
    );

Map<String, dynamic> _gatewayState() => {
      'deviceId': _binding().deviceId,
      // P2：Gateway 返回手机实例标识 appInstanceId（binding.tokenId 保存的就是它）。
      'appInstanceId': _binding().tokenId,
      'role': 'admin',
      'bindingState': 'active',
      'protocolVersion': 1,
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
      'firmware': '0.7.1',
      'stateFreshness': 'fresh',
      'stale': false,
    };

class _FakeNasGateway extends NasGatewayTransport {
  Future<Map<String, dynamic>> Function(String path)? onReadPath;
  @override
  Future<Map<String, dynamic>> readPath(WifiBinding binding, String path) =>
      onReadPath?.call(path) ?? Future.error(UnimplementedError('readPath'));
  int readCalls = 0;
  int writeCalls = 0;
  int queryCalls = 0;
  bool writeUnknown = false;
  NasGatewayHttpResult? writeResult;
  Future<NasGatewayHttpResult?> Function()? onWrite;
  Completer<NasGatewayHttpResult?>? pendingRead;
  Map<String, dynamic> state = _gatewayState();

  @override
  Future<NasGatewayHttpResult?> tryReadState(WifiBinding binding) {
    readCalls++;
    return pendingRead?.future ??
        Future.value(NasGatewayHttpResult(200, state));
  }

  @override
  Future<NasGatewayHttpResult?> tryWrite(WifiBinding binding,
      {required String path,
      required String body,
      required String requestId}) async {
    writeCalls++;
    if (onWrite != null) return onWrite!();
    if (writeResult != null) return writeResult;
    return writeUnknown
        ? const NasGatewayHttpResult(504, {
            'error': 'GATEWAY_RESULT_UNKNOWN',
            'resultUnknown': true,
          })
        : const NasGatewayHttpResult(200, {'ok': true});
  }

  @override
  Future<NasGatewayHttpResult?> queryRequest(
      WifiBinding binding, String requestId) async {
    queryCalls++;
    return null;
  }
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
  Future<void> Function(TimingProfile profile)? onSyncClock;
  Future<Map<String, dynamic>> Function(TimingProfile profile)? onRange;
  int settingsCalls = 0;

  @override
  Future<Map<String, dynamic>> getStatisticsRange(
    TimingProfile profile, {
    required int from,
    required int to,
    required int tzOffsetSeconds,
  }) =>
      onRange?.call(profile) ??
      Future<Map<String, dynamic>>.error(UnimplementedError('range 未在本用例启用'));
  int confirmLockOffCalls = 0;
  int setAutoCalls = 0;

  @override
  Future<Map<String, dynamic>> getStatistics(
    TimingProfile profile,
    String range, {
    int offset = 0,
  }) async =>
      <String, dynamic>{};

  @override
  Future<DeviceEventPage> queryEvents(
          TimingProfile profile, DeviceEventQuery query) async =>
      const DeviceEventPage(
        events: [],
        offset: 0,
        nextOffset: 0,
        total: 0,
        hasMore: false,
      );

  @override
  Future<void> syncClock(TimingProfile profile) async {
    await onSyncClock?.call(profile);
  }

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
  String deviceIdentity = 'device-a';
  @override
  String? get connectedDeviceId => isConnected ? deviceIdentity : null;

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
