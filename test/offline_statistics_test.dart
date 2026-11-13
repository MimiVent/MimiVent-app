import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mimivent_app/app/theme/mimivent_theme.dart';
import 'package:mimivent_app/ble/mimivent_ble_manager.dart';
import 'package:mimivent_app/core/diagnostics/app_diagnostics_log.dart';
import 'package:mimivent_app/data/device_repository.dart';
import 'package:mimivent_app/data/mimivent_controller.dart';
import 'package:mimivent_app/data/models.dart';
import 'package:mimivent_app/data/statistics_event_cache.dart';
import 'package:mimivent_app/features/dashboard/presentation/dashboard_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('schema 4 新批次清除其余范围旧汇总和无身份快照，保留截断标记', () async {
    final values = _cachedPreferences();
    final snapshot =
        jsonDecode(values['mimivent.statistics.cache.today']! as String)
            as Map<String, dynamic>;
    values['mimivent.statistics.cache.yesterday'] = jsonEncode(snapshot);
    (snapshot['data'] as Map<String, dynamic>)['dataEpoch'] = 'old-epoch';
    values['mimivent.statistics.cache.sevenDays'] = jsonEncode(snapshot);
    SharedPreferences.setMockInitialValues(values);
    final ble = _OfflineBle();
    final repository = _Repository()
      ..datasetEpoch = 'new-epoch'
      ..truncated = true;
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: ble,
        deviceRepository: repository);
    await controller.enterOfflineViewing();
    expect(controller.statisticsFor('yesterday'), isNotNull);
    expect(controller.statisticsFor('sevenDays'), isNotNull);
    await controller.leaveOfflineViewing();
    ble.setConnected(true);
    await controller.refreshStatistics('today');
    expect(controller.statisticsFor('today')?['eventsTruncated'], isTrue);
    expect(controller.statisticsFor('yesterday'), isNull);
    expect(controller.statisticsFor('sevenDays'), isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getString('mimivent.statistics.cache.yesterday'), isNull);
    expect(
        preferences.getString('mimivent.statistics.cache.sevenDays'), isNull);
    controller.dispose();
  });

  testWidgets('明细截断提示在离线统计中仍可见', (tester) async {
    final values = _cachedPreferences();
    final snapshot =
        jsonDecode(values['mimivent.statistics.cache.today']! as String)
            as Map<String, dynamic>;
    (snapshot['data'] as Map<String, dynamic>)['eventsTruncated'] = true;
    values['mimivent.statistics.cache.today'] = jsonEncode(snapshot);
    SharedPreferences.setMockInitialValues(values);
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: _OfflineBle(),
        deviceRepository: _Repository());
    final diagnostics = AppDiagnosticsLog();
    await controller.enterOfflineViewing();
    await tester.pumpWidget(MaterialApp(
        theme: buildMimiVentTheme(),
        home: DashboardPage(controller: controller, diagnostics: diagnostics)));
    await tester.tap(find.text('统计'));
    await tester.pump();
    await tester.scrollUntilVisible(find.textContaining('部分历史明细已淘汰'), 180,
        scrollable: find
            .descendant(
                of: find.byKey(const PageStorageKey('statistics-page')),
                matching: find.byType(Scrollable))
            .first);
    expect(find.textContaining('部分历史明细已淘汰'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    diagnostics.dispose();
  });

  test('离线入口停止扫描并恢复缓存，重新打开不扫描或读取设备', () async {
    SharedPreferences.setMockInitialValues(_cachedPreferences());
    final ble = _OfflineBle();
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: ble,
        deviceRepository: repository);
    await controller.openApp();
    expect(ble.scanCalls, 1);

    await controller.enterOfflineViewing();
    expect(controller.offlineViewing, isTrue);
    expect(ble.isScanning, isFalse);
    expect(controller.statisticsFor('today')?['activityCount'], 26);
    expect(controller.statisticsIsCachedFor('today'), isTrue);
    expect(controller.statisticsCacheUpdatedAtFor('today'), isNotNull);
    await controller.openApp();
    await controller.refreshStatistics('today');
    await controller.loadMoreStatisticsEvents('today');
    expect(ble.scanCalls, 1);
    expect(repository.calls, 0);
    controller.dispose();

    final restartedBle = _OfflineBle();
    final restarted = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: restartedBle,
        deviceRepository: repository);
    await restarted.openApp();
    expect(restarted.offlineViewing, isTrue);
    expect(restartedBle.scanCalls, 0);
    expect(restarted.statisticsFor('today')?['runtimeSeconds'], 90);
    restarted.dispose();
  });

  test('离线期间即使迟到连接通知显示在线，也不能发控制、改环境或查设备', () async {
    final ble = _OfflineBle();
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: ble,
        deviceRepository: repository);
    await controller.enterOfflineViewing();
    ble.setConnected(true);

    await expectLater(controller.setAuto(), throwsStateError);
    await expectLater(controller.exhaust(), throwsStateError);
    await expectLater(controller.pause(), throwsStateError);
    await expectLater(controller.forceTest(), throwsStateError);
    await expectLater(controller.enableLockOff(), throwsStateError);
    await expectLater(controller.cancelLockOff(), throwsStateError);
    await expectLater(
        controller.switchProfile(TimingProfile.dev), throwsStateError);
    await expectLater(
        controller
            .queryDeviceEvents(DeviceEventQuery.forLocalDay(DateTime.now())),
        throwsStateError);
    await controller.refresh();
    await controller.loadSettings();
    await controller.refreshStatistics('today');
    expect(repository.calls, 0);
    controller.dispose();
  });

  test('主动连接并完成同步后离开离线模式，保存在线启动偏好', () async {
    final ble = _OfflineBle();
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: ble,
        deviceRepository: repository);
    await controller.enterOfflineViewing();
    await controller.connect(BluetoothDevice.fromId('offline-test-device'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.offlineViewing, isFalse);
    expect(controller.connected, isTrue);
    expect(controller.status?.firmware, '0.3.2');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('mimivent.offline_viewing'), isFalse);
    controller.dispose();
  });

  test('某个范围缓存损坏，不阻止其他范围离线读取', () async {
    final values = _cachedPreferences();
    values['mimivent.statistics.cache.yesterday'] =
        values['mimivent.statistics.cache.today']!;
    values['mimivent.statistics.cache.today'] = '{broken';
    SharedPreferences.setMockInitialValues(values);
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: _OfflineBle(),
        deviceRepository: _Repository());
    await controller.enterOfflineViewing();
    expect(controller.statisticsFor('today'), isNull);
    expect(controller.statisticsFor('yesterday')?['activityCount'], 26);
    controller.dispose();
  });

  test('统计批次变化后首屏不会重新合并旧事件', () {
    final previous = [
      {'id': 18, 'time': 100, 'kind': 'manual'},
    ];
    final incoming = [
      {'id': 1, 'time': 200, 'kind': 'activity'},
    ];

    final merged = StatisticsEventCache.mergeFirstPage(
      previous: previous,
      incoming: incoming,
      discardPrevious: true,
    );

    expect(merged, incoming);
    expect(merged.map((event) => event['id']), [1]);
  });

  test('加载旧批次下一页时识别 dataEpoch 改变', () {
    expect(
      StatisticsEventCache.shouldDiscardPrevious(
        previous: [
          {'id': 18, 'time': 100, 'kind': 'manual'},
        ],
        incoming: [
          {'id': 1, 'time': 90, 'kind': 'activity'},
        ],
        incomingTotal: 1,
        sameWindow: true,
        firstPage: false,
        previousDataEpoch: 'old-batch',
        incomingDataEpoch: 'new-batch',
      ),
      isTrue,
    );
  });

  test('同一批次的游标不能跨设备复用', () {
    expect(
      StatisticsEventCache.shouldDiscardPrevious(
        previous: [
          {'id': 18, 'time': 100, 'kind': 'manual'},
        ],
        incoming: [
          {'id': 17, 'time': 90, 'kind': 'activity'},
        ],
        incomingTotal: 2,
        sameWindow: true,
        firstPage: false,
        previousDataEpoch: 'same-epoch',
        incomingDataEpoch: 'same-epoch',
        previousDeviceId: 'device-a',
        incomingDeviceId: 'device-b',
      ),
      isTrue,
    );
  });

  test('分页请求把数据批次带给设备，防止旧游标跨批次读取', () {
    final query = DeviceEventQuery.forLocalDay(
      DateTime(2026, 10, 28),
      beforeId: 18,
      dataEpoch: 'batch-2',
    );

    expect(query.toQueryParameters(), containsPair('dataEpoch', 'batch-2'));
    expect(query.toQueryParameters(), containsPair('beforeId', '18'));
    expect(query.toQueryParameters(), isNot(contains('offset')));
  });

  test('事件缓存升级只清旧明细，保留汇总与图表缓存', () {
    final migrated = StatisticsEventCache.keepCompatibleSnapshot({
      'eventsIdentityVersion': 2,
      'activityCount': 12,
      'runtimeSeconds': 78,
      'bucketSeconds': List<int>.filled(24, 0),
      'eventsTotal': 125,
      'events': List<Map<String, dynamic>>.generate(
        125,
        (index) => {'id': 125 - index, 'time': 1000 + index},
      ),
      'eventsHasMore': true,
    });

    expect(migrated['activityCount'], 12);
    expect(migrated['runtimeSeconds'], 78);
    expect(migrated['bucketSeconds'], hasLength(24));
    expect(migrated.containsKey('events'), isFalse);
    expect(migrated['eventsTotal'], 0);
    expect(migrated['eventsHasMore'], isFalse);
    expect(migrated['eventsIdentityVersion'], 3);
  });

  test('首屏事件总数或 ID 回退时丢弃旧批次，正常追加时保留分页缓存', () {
    final cached = List<Map<String, dynamic>>.generate(
      125,
      (index) => {
        'id': 125 - index,
        'time': 1000 + index,
        'kind': 'automatic',
      },
    );
    final resetPage = List<Map<String, dynamic>>.generate(
      28,
      (index) => {
        'id': 28 - index,
        'time': 2000 + index,
        'kind': 'automatic',
      },
    );
    final appendedPage = [
      {'id': 130, 'time': 3000, 'kind': 'automatic'},
      ...cached.take(31),
    ];

    expect(
        StatisticsEventCache.shouldDiscardPrevious(
          previous: cached,
          incoming: resetPage,
          incomingTotal: 28,
          sameWindow: true,
          firstPage: true,
        ),
        isTrue);
    expect(
        StatisticsEventCache.shouldDiscardPrevious(
          previous: cached,
          incoming: appendedPage,
          incomingTotal: 130,
          sameWindow: true,
          firstPage: true,
        ),
        isFalse);
    expect(
        StatisticsEventCache.shouldDiscardPrevious(
          previous: cached,
          incoming: cached,
          incomingTotal: 125,
          sameWindow: true,
          firstPage: true,
          previousDataEpoch: 'old-batch',
          incomingDataEpoch: 'new-batch',
        ),
        isTrue);
  });

  testWidgets('离线保留三个 Tab，操作提示连接，设置不展示虚假值', (tester) async {
    final ble = _OfflineBle();
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: ble,
        deviceRepository: repository);
    final diagnostics = AppDiagnosticsLog();
    await controller.enterOfflineViewing();
    ble.setConnected(true);
    await tester.pumpWidget(MaterialApp(
      theme: buildMimiVentTheme(),
      home: DashboardPage(controller: controller, diagnostics: diagnostics),
    ));
    await tester.pump();
    expect(find.text('离线模式 · 仅查看缓存数据'), findsOneWidget);
    expect(find.text('状态未知'), findsOneWidget);
    expect(find.text('控制'), findsOneWidget);
    expect(find.text('时间设置'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    await tester.tap(find.text('临时排风'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('需要连接蓝牙')),
        findsOneWidget);
    expect(repository.calls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('时间设置'));
    await tester.pump();
    await tester.tap(find.text('启动冷静期'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('需要连接蓝牙')),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('统计'));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('offline-statistics-empty')), findsOneWidget);
    expect(repository.calls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    diagnostics.dispose();
  });

  testWidgets('未连接直接进入控制页，确认操作后打开连接弹窗，底部可选择离线', (tester) async {
    final ble = _OfflineBle();
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: ble,
        deviceRepository: repository);
    final diagnostics = AppDiagnosticsLog();
    await tester.pumpWidget(MaterialApp(
      theme: buildMimiVentTheme(),
      home: DashboardPage(controller: controller, diagnostics: diagnostics),
    ));
    await tester.pump();
    expect(find.text('等待连接'), findsOneWidget);
    expect(find.text('设备未连接 · 可查看缓存数据'), findsOneWidget);
    expect(find.text('连接你的设备'), findsNothing);
    await tester.tap(find.text('临时排风'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '连接设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        find.byKey(const ValueKey('connection-sheet-offline')), findsOneWidget);
    expect(ble.scanCalls, 1);
    expect(repository.calls, 0);
    await tester.tap(find.byKey(const ValueKey('connection-sheet-offline')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.offlineViewing, isTrue);
    expect(find.text('离线模式 · 仅查看缓存数据'), findsOneWidget);
    expect(find.text('控制'), findsOneWidget);
    expect(ble.isScanning, isFalse);
    expect(repository.calls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    diagnostics.dispose();
  });

  testWidgets('离线显示快照日期与历史运行状态，缺少范围缓存不伪装零数据', (tester) async {
    SharedPreferences.setMockInitialValues(_cachedPreferences());
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: _OfflineBle(),
        deviceRepository: repository);
    final diagnostics = AppDiagnosticsLog();
    await controller.enterOfflineViewing();
    await tester.pumpWidget(MaterialApp(
      theme: buildMimiVentTheme(),
      home: DashboardPage(controller: controller, diagnostics: diagnostics),
    ));
    await tester.pump();
    await tester.tap(find.text('统计'));
    await tester.pump();
    expect(find.textContaining('离线缓存'), findsOneWidget);
    expect(find.textContaining('10/28'), findsWidgets);
    await tester.scrollUntilVisible(find.textContaining('同步时运行中'), 180,
        scrollable: find
            .descendant(
                of: find.byKey(const PageStorageKey('statistics-page')),
                matching: find.byType(Scrollable))
            .first);
    expect(find.textContaining('同步时运行中'), findsOneWidget);
    expect(find.text('仅显示已缓存事件，连接设备可加载其余记录'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('昨天'), -180,
        scrollable: find
            .descendant(
                of: find.byKey(const PageStorageKey('statistics-page')),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('昨天'));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('offline-statistics-empty')), findsOneWidget);
    expect(repository.calls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    diagnostics.dispose();
  });

  testWidgets('停留统计 Tab 重连后正常同步，构建过程不触发异常', (tester) async {
    final repository = _Repository();
    final controller = MimiVentController(
        appVersionOverride: '0.3.0',
        bleManager: _OfflineBle(),
        deviceRepository: repository);
    final diagnostics = AppDiagnosticsLog();
    await controller.enterOfflineViewing();
    await tester.pumpWidget(MaterialApp(
      theme: buildMimiVentTheme(),
      home: DashboardPage(controller: controller, diagnostics: diagnostics),
    ));
    await tester.pump();
    await tester.tap(find.text('统计'));
    await tester.pump();
    await controller.connect(BluetoothDevice.fromId('reconnect-statistics'));
    await tester.pump();
    await tester.pump();
    expect(controller.offlineViewing, isFalse);
    expect(controller.statisticsFor('today'), isNotNull);
    expect(find.text('控制'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    diagnostics.dispose();
  });
}

Map<String, Object> _cachedPreferences() => {
      'mimivent.statistics.cache.today': jsonEncode({
        'updatedAt': DateTime(2026, 10, 28, 11, 30).millisecondsSinceEpoch,
        'data': {
          'timeSynced': true,
          'range': 'today',
          'runtimeSeconds': 90,
          'activityCount': 26,
          'automaticCount': 1,
          'bucketSeconds': List.filled(24, 0),
          'eventsIdentityVersion': StatisticsEventCache.schemaVersion,
          'eventsTotal': 2,
          'eventsHasMore': true,
          'eventsNextCursor': 5,
          'events': [
            {
              'id': 5,
              'time': DateTime(2026, 10, 28, 11).millisecondsSinceEpoch ~/ 1000,
              'kind': 'manual',
              'state': 'active',
              'durationSeconds': 20,
            }
          ],
        },
      }),
    };

/// 离线测试不接触原生 BLE；任何扫描行为都必须可观察。
class _OfflineBle extends MimiVentBleManager {
  int scanCalls = 0;
  bool _closed = false;

  void setConnected(bool value) {
    connectionStatus = value
        ? BleConnectionStatus.connected
        : BleConnectionStatus.disconnected;
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> scan({Duration timeout = const Duration(seconds: 12)}) async {
    scanCalls++;
    connectionStatus = BleConnectionStatus.scanning;
    if (!_closed) notifyListeners();
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
    _closed = true;
    super.dispose();
  }
}

class _Repository implements DeviceRepository {
  int calls = 0;
  String? datasetEpoch;
  bool truncated = false;

  @override
  Future<Map<String, dynamic>> getStatistics(
      TimingProfile profile, String range,
      {int offset = 0}) async {
    calls++;
    return {
      'range': range,
      if (datasetEpoch != null) 'dataEpoch': datasetEpoch,
      if (datasetEpoch != null) 'statisticsSchema': 4,
      'runtimeSeconds': 0,
      'activityCount': 0,
      'automaticCount': 0,
      'bucketSeconds': List.filled(24, 0),
      'events': [],
    };
  }

  @override
  Future<DeviceEventPage> queryEvents(
      TimingProfile profile, DeviceEventQuery query) async {
    calls++;
    return DeviceEventPage(
        events: const [],
        offset: 0,
        nextOffset: 0,
        total: 0,
        hasMore: false,
        dataEpoch: datasetEpoch,
        eventsTruncated: truncated);
  }

  @override
  Future<void> syncClock(TimingProfile profile) async => calls++;

  @override
  Future<DeviceStatus> getStatus(TimingProfile profile) async {
    calls++;
    return DeviceStatus(
      fan: false,
      pir: false,
      mode: 'auto',
      phase: 'armed',
      activeProfile: profile,
      viewProfile: profile,
      fanRunMs: 0,
      remainingMs: 0,
      durationMs: 0,
      phaseDurationMs: 0,
      startupCooldownMs: 30000,
      leaveConfirmMs: 30000,
      autoExhaustMs: 120000,
      manualExhaustMs: 60000,
      pauseMs: 300000,
      firmware: '0.3.2',
    );
  }

  @override
  Future<TimingSettings> getSettings(TimingProfile profile) async {
    calls++;
    return const TimingSettings(
      startupCooldownMs: 30000,
      leaveConfirmMs: 30000,
      autoExhaustMs: 120000,
      manualExhaustMs: 60000,
      pauseMs: 300000,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('离线不应调用 ${invocation.memberName}');
  }
}
