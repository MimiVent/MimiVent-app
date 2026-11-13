import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/mimivent_api.dart';
import '../ble/mimivent_ble_manager.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../features/control/control_operation.dart';
import '../features/local_network/wifi_binding.dart';
import '../features/local_network/nas_gateway_transport.dart';
import '../features/local_network/nas_gateway_models.dart';
import '../features/local_network/nas_gateway_serial_executor.dart';
import '../features/local_network/nas_pending_request_store.dart';
import 'ble_device_repository.dart';
import 'device_repository.dart';
import 'settings_draft.dart';
import 'statistics_query.dart';
import 'models.dart';
import 'statistics_event_cache.dart';
import '../transport/device_transport.dart';

class MimiVentController extends ChangeNotifier {
  MimiVentController(
      {MimiVentBleManager? bleManager,
      DeviceRepository? deviceRepository,
      this.appVersionOverride,
      this.diagnostics,
      NasGatewayTransport? nasGatewayTransport})
      : ble = bleManager ?? MimiVentBleManager(diagnostics: diagnostics) {
    _nasGatewayTransport = nasGatewayTransport ?? NasGatewayTransport();
    // 默认 Repository 与扫描/连接共用同一个 BLE 实例；测试可注入替身。
    repository = deviceRepository ??
        BleDeviceRepository(MimiVentApi(ble, diagnostics: diagnostics));
    _lastBleConnected = ble.isConnected;
    ble.addListener(_onBleChanged);
    // MQTT 状态有独立采样和年龄；本地显示倒计时每秒刷新即可，不额外发网络请求。
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (hasPendingNasMqttRequest &&
          _pendingNasMqttRequestCreatedAtMs != null) {
        final nextAge = (DateTime.now().millisecondsSinceEpoch -
                _pendingNasMqttRequestCreatedAtMs!)
            .clamp(0, 0x7fffffffffffffff)
            .toInt();
        if (nextAge != pendingNasMqttRequestAgeMs) {
          pendingNasMqttRequestAgeMs = nextAge;
          _notifyIfAlive();
        }
      }
      // 连接 12 秒仍无状态：多半是 GATT 缓存失效（133），直接给出可操作提示。
      if (ble.isConnected &&
          !_offlineViewing &&
          status == null &&
          lastError == null &&
          _bleConnectedSince != null &&
          DateTime.now().difference(_bleConnectedSince!) >
              const Duration(seconds: 12)) {
        lastError = '设备长时间无响应，请关闭手机蓝牙开关后重新连接';
        _notifyIfAlive();
      }
      if (ble.isConnected &&
          !_offlineViewing &&
          status != null &&
          lastError == null &&
          !ble.isOtaUploading &&
          !ble.isOtaVerifying &&
          !_connectionBootstrapInProgress &&
          !busy &&
          !_polling) {
        refresh();
      }
    });
  }

  final MimiVentBleManager ble;
  final AppDiagnosticsLog? diagnostics;
  final String? appVersionOverride;
  late DeviceRepository repository;
  DeviceStatus? status;

  /// 两次 NAS 状态采样之间本地插值，让运行时间每秒推进。
  int get displayFanRunMs {
    final current = status;
    if (current == null) return 0;
    if (!nasMqttActive || !current.fan) return current.fanRunMs;
    final started = _fanRunStartedAt;
    if (started == null) return current.fanRunMs;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    return elapsed > 0 ? elapsed : 0;
  }

  /// 两次 NAS 状态采样之间本地推进倒计时，避免倒计时每 3–6 秒才跳一次。
  int get displayRemainingMs {
    final current = status;
    if (current == null) return 0;
    final remaining = current.remainingMs;
    if (!nasMqttActive || _nasStatusAt == null || remaining <= 0) {
      return remaining;
    }
    final elapsed = DateTime.now().difference(_nasStatusAt!).inMilliseconds;
    final value = remaining - elapsed;
    return value > 0 ? value : 0;
  }

  Map<String, dynamic>? statistics;
  final Map<String, Map<String, dynamic>> _statisticsByRange = {};
  final Set<String> _statisticsLoadingRanges = {};
  final Set<String> _statisticsFailedRanges = {};
  final Set<String> _statisticsRequests = {};
  final Set<String> _statisticsCachedRanges = {};
  final Map<String, DateTime> _statisticsCacheUpdatedAt = {};
  // 范围查询缓存：键由 from/to（量化后）/tz 组成，设备身份与 dataEpoch 另行校验。
  final Map<String, Map<String, dynamic>> _statisticsRangeByKey = {};
  final Map<String, Future<void>> _statisticsRangeRequests = {};
  final Map<String, bool Function()> _statisticsRangeReadGuards = {};
  final Map<String, String> _statisticsDatasetByScope = {};
  final Map<String, Future<String?>> _statisticsDatasetLoadsByScope = {};
  final Map<String, String> _statisticsPeerScopeByScope = {};
  final Map<String, DateTime> _statisticsRangeUpdatedAt = {};
  static const _statisticsRangeCachePrefix = 'mimivent.statistics.range.v2.';
  static const _statisticsDatasetScopePrefix =
      'mimivent.statistics.dataset-scope.v1.';
  static const _statisticsPeerScopePrefix =
      'mimivent.statistics.peer-scope.v1.';
  static const _statisticsDatasetEpochPrefix =
      'mimivent.statistics.dataset-epoch.v1.';
  TimingSettings? settings;
  SettingsDraft? _settingsDraft;
  TimingSettings? get draftSettings => _settingsDraft?.value;
  TimingProfile profile = TimingProfile.production;
  Timer? _pollTimer;
  bool busy = false;
  bool wifiGattCacheStale = false;
  bool _polling = false;
  bool _statusInvalid = false;
  bool _initialized = false;
  bool _statisticsCacheLoaded = false;
  Future<void>? _statisticsCacheRestoring;
  Future<void>? _preferencesLoading;
  bool _offlineViewing = false;
  bool _disposed = false;
  int _sessionGeneration = 0;
  int _connectAttempt = 0;
  int? _connectionBootstrapAttempt;
  bool _bluetoothControlReady = false;
  bool _lastBleConnected = false;
  Future<void>? _closingBluetoothSession;
  String? _appVersionCache;
  static const _profileKey = 'mimivent.selected_profile';
  static const _offlineViewingKey = 'mimivent.offline_viewing';
  static const _statisticsCacheKeyPrefix = 'mimivent.statistics.cache.';
  String? lastError;
  WifiBinding? _wifiBinding;
  bool _nasMqttSessionReady = false;
  int _nasMqttSessionGeneration = 0;
  int _nasSnapshotRevision = 0;
  int _nasFastSyncUntilMs = 0;
  // 最近一次控制落地的时间戳。控制后几秒内到达的"陈旧"快照要丢弃：
  // 它们出发于控制之前，回来时控制已经生效，直接应用会把 UI 拉回旧状态。
  // 蓝牙路径用 refresh(expectedGeneration:) 规避同一问题，NAS 路径靠这个时间窗。
  int _nasControlAppliedAtMs = 0;
  late final NasGatewayTransport _nasGatewayTransport;
  bool _nasVersionCompatible = true;
  int _nasWritesInFlight = 0;
  bool get nasMqttWriteInFlight => _nasWritesInFlight > 0;
  TimingProfile? _nasExpectedProfile;
  TimingSettings? _nasExpectedSettings;
  DateTime? _nasConfigurationDeadline;

  final _nasGatewayExecutor = NasGatewaySerialExecutor();
  final _nasControlExecutor = NasGatewaySerialExecutor();
  Timer? _nasSyncTimer;
  bool nasMqttLost = false;
  bool nasMqttBusy = false;
  bool nasStateStale = false;
  int nasStateAgeMs = 0;
  bool hasPendingNasMqttRequest = false;
  int? pendingNasMqttRequestAgeMs;
  bool pendingNasMqttRequestAgeEstimated = false;
  int? _pendingNasMqttRequestCreatedAtMs;
  String? _lastNasPendingDeviceId;
  String? _lastNasPendingTokenId;
  String? pendingNasMqttAction;
  bool _nasStatsSerialized = false;
  int _nasSyncFailures = 0;
  bool _appForeground = true;
  bool _nasRefreshInFlight = false;
  DateTime? _nasStatusAt;
  DateTime? _fanRunStartedAt;

  bool get nasMqttActive => _wifiBinding != null && _nasMqttSessionReady;

  /// 固件是否支持 /api/stats/range（依据 /api/status 的能力字段）。
  bool get supportsStatisticsRange {
    _ensureRangeCapabilityScope();
    final api = status?.statsRangeApiVersion;
    if (api != null) _lastStatsRangeApiVersion = api;
    final effective = api ?? _lastStatsRangeApiVersion;
    return (effective ?? 0) >= 2 && deviceTimezoneOffsetSeconds != null;
  }

  /// 设备固定时区偏移（秒），范围查询必须原样带上。
  /// 断线时 status 会被清空，但时区与范围能力应保持"最近一次已知值"：
  /// 统计页靠它们构造查询命中缓存，否则断线瞬间整页变空。
  int? _lastTzOffsetSeconds;
  int? _lastStatsRangeApiVersion;

  int? get deviceTimezoneOffsetSeconds {
    _ensureRangeCapabilityScope();
    final tz = status?.tzOffsetSeconds;
    if (tz != null) _lastTzOffsetSeconds = tz;
    return tz ?? _lastTzOffsetSeconds;
  }

  String _lastRangeScope = 'disconnected';
  String? _rangeCapabilityScope;
  void _ensureRangeCapabilityScope() {
    final scope = _rangeScope;
    if (_rangeCapabilityScope == scope) return;
    _rangeCapabilityScope = scope;
    _lastTzOffsetSeconds = null;
    _lastStatsRangeApiVersion = null;
  }

  final Map<String, String> _rangeEpochByScope = {};

  String get _rangeScope {
    final identity = nasMqttActive
        ? 'wifi:${_wifiBinding!.deviceId}'
        : ble.connectedDeviceId == null
            ? null
            : 'ble:${ble.connectedDeviceId}';
    if (identity != null) _lastRangeScope = identity;
    return _lastRangeScope;
  }

  String _rangeKeyFor(String scope, StatisticsQuery query) =>
      '$scope|${_rangeEpochByScope[scope] ?? ''}|2|${query.cacheKey}';

  String _rangeKey(StatisticsQuery query) => _rangeKeyFor(_rangeScope, query);

  String? _statisticsPeerRangeKey(String scope, StatisticsQuery query) {
    final peerScope = _statisticsPeerScopeByScope[scope];
    return peerScope == null ? null : _rangeKeyFor(peerScope, query);
  }

  Map<String, dynamic>? statisticsRangeFor(StatisticsQuery query) {
    final scope = _rangeScope;
    final own = _statisticsRangeByKey[_rangeKeyFor(scope, query)];
    if (own != null) return own;
    final peerKey = _statisticsPeerRangeKey(scope, query);
    return peerKey == null ? null : _statisticsRangeByKey[peerKey];
  }

  DateTime? statisticsRangeUpdatedAtFor(StatisticsQuery query) {
    final scope = _rangeScope;
    final ownKey = _rangeKeyFor(scope, query);
    final own = _statisticsRangeUpdatedAt[ownKey];
    if (own != null) return own;
    final peerKey = _statisticsPeerRangeKey(scope, query);
    return peerKey == null ? null : _statisticsRangeUpdatedAt[peerKey];
  }

  bool get connected => ble.isConnected || nasMqttActive;
  bool get _connectionBootstrapInProgress =>
      _connectionBootstrapAttempt != null;
  bool get bluetoothBootstrapInProgress => _connectionBootstrapInProgress;
  bool get bluetoothControlReady =>
      _bluetoothControlReady &&
      ble.isConnected &&
      !_connectionBootstrapInProgress &&
      !deviceOtaBusy &&
      ble.appVersionCompatible &&
      status != null &&
      settings != null;
  bool get deviceOtaBusy => ble.deviceOtaBusy;
  bool get appVersionCompatible =>
      nasMqttActive ? _nasVersionCompatible : ble.appVersionCompatible;

  /// 离线只读是独立的页面模式，不能由一次短暂断连自动开启控制能力。
  bool get offlineViewing => _offlineViewing;
  bool get statusInvalid => _statusInvalid;
  bool get profileMatches => status != null && status!.activeProfile == profile;
  bool get hasUnsavedSettings => _settingsDraft?.isDirty ?? false;
  bool get hasInterruptibleTask => hasInterruptibleOperation(status);

  Map<String, dynamic>? statisticsFor(String range) =>
      _statisticsByRange[range];
  bool statisticsIsCachedFor(String range) =>
      _statisticsCachedRanges.contains(range);
  DateTime? statisticsCacheUpdatedAtFor(String range) =>
      _statisticsCacheUpdatedAt[range];
  bool statisticsLoadingFor(String range) =>
      _statisticsLoadingRanges.contains(range);
  bool statisticsFailedFor(String range) =>
      _statisticsFailedRanges.contains(range);
  bool statisticsHasMoreEventsFor(String range) =>
      _statisticsByRange[range]?['eventsHasMore'] == true;
  int statisticsNextEventOffsetFor(String range) {
    final value = _statisticsByRange[range]?['eventsNextOffset'];
    if (value is num) return value.toInt();
    final events = _statisticsByRange[range]?['events'];
    return events is List ? events.length : 0;
  }

  int? statisticsNextEventCursorFor(String range) {
    final value = _statisticsByRange[range]?['eventsNextCursor'];
    return value is num && value.toInt() > 0 ? value.toInt() : null;
  }

  Future<void> loadMoreStatisticsEvents(String range) async {
    if (!statisticsHasMoreEventsFor(range)) return;
    final cursor = statisticsNextEventCursorFor(range);
    await refreshStatistics(
      range,
      eventOffset: cursor == null ? statisticsNextEventOffsetFor(range) : 0,
      eventBeforeId: cursor,
    );
  }

  /// 通用原始事件查询入口；页面可传入自然日、自定义时间段和事件筛选条件。
  Future<DeviceEventPage> queryDeviceEvents(DeviceEventQuery query) async {
    if (_offlineViewing) throw StateError('离线模式仅支持查看缓存');
    if (!ble.isConnected) throw StateError('请先连接 MimiVent 设备');
    final selectedProfile = profile;
    final generation = _sessionGeneration;
    final result = await repository.queryEvents(selectedProfile, query);
    if (_disposed ||
        !ble.isConnected ||
        generation != _sessionGeneration ||
        selectedProfile != profile) {
      throw StateError('蓝牙会话已变化，事件查询结果已丢弃');
    }
    return result;
  }

  /// 清除当前设备会话的错误提示，例如用户主动发起重新连接时。
  void clearError() {
    if (lastError == null) return;
    lastError = null;
    _notifyIfAlive();
  }

  /// BLE 链路连上但迟迟拿不到 /api/status 的时刻。用于把"正在同步"变成
  /// 用户能理解的"设备无响应"，而不是无限转圈。
  DateTime? _bleConnectedSince;

  void _onBleChanged() {
    if (_disposed) return;
    final bleConnected = ble.isConnected;
    if (bleConnected) {
      _bleConnectedSince ??= DateTime.now();
    } else {
      _bleConnectedSince = null;
    }
    final linkChanged = bleConnected != _lastBleConnected;
    _lastBleConnected = bleConnected;
    if (!bleConnected && linkChanged) {
      if (ble.lastError == '蓝牙连接已断开') {
        lastError = ble.lastError;
      }
      // 让断开前正在进行的状态读取失效，避免异步结果重新写入旧会话。
      _sessionGeneration++;
      wifiGattCacheStale = false;
      // BLE 扫描/广播变化也会触发 listener。只在真实断链时清理会话；
      // NAS MQTT 仍在线时保留其状态和设置，切换过程中不让控制页闪空。
      if (!nasMqttActive) {
        status = null;
        statistics = null;
        for (final range in _statisticsByRange.keys) {
          _statisticsCachedRanges.add(range);
          final updatedAt = _statisticsCacheUpdatedAt[range];
          if (updatedAt != null) {
            _statisticsByRange[range]!['_cacheUpdatedAt'] =
                updatedAt.millisecondsSinceEpoch;
          }
        }
        _statisticsLoadingRanges.clear();
        _statisticsFailedRanges.clear();
        _statisticsRequests.clear();
        settings = null;
        _settingsDraft = null;
      }
      _statusInvalid = false;
    }
    _notifyIfAlive();
  }

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  Future<void> scan() => ble.scan();

  /// 恢复用户上次选择的页面环境，再开始扫描，避免重开 App 时错用正式环境。
  Future<void> openApp({bool scanIfNeeded = true}) async {
    await _loadSelectedProfile();
    await _ensureStatisticsCache();
    if (_disposed || _offlineViewing) return;
    if (scanIfNeeded && !ble.isConnected && !ble.isScanning) await scan();
  }

  /// 取消扫描和旧连接尝试，再读取缓存；离线操作不会排队留待下次连接执行。
  Future<void> enterOfflineViewing() async {
    await _loadSelectedProfile();
    if (_disposed) return;
    _offlineViewing = true;
    lastError = null;
    _notifyIfAlive();
    await closeBluetoothSession();
    await _ensureStatisticsCache();
    await _persistOfflineViewing();
    _notifyIfAlive();
  }

  /// 返回连接页；扫描只由用户明确的连接动作或在线启动流程发起。
  Future<void> leaveOfflineViewing() async {
    _offlineViewing = false;
    await _persistOfflineViewing();
    _notifyIfAlive();
  }

  Future<void> _persistOfflineViewing() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      await preferences.setBool(_offlineViewingKey, _offlineViewing);
    } catch (error) {
      diagnostics?.warning('离线模式', '保存查看模式失败：$error');
    }
  }

  /// 启动恢复与用户点击离线入口可能并发，合并为同一次缓存读取。
  Future<void> _ensureStatisticsCache() {
    final pending = _statisticsCacheRestoring;
    if (pending != null) return pending;
    if (_statisticsCacheLoaded || _disposed) return Future.value();
    final restoring = _restoreStatisticsCache().whenComplete(() {
      _statisticsCacheRestoring = null;
    });
    _statisticsCacheRestoring = restoring;
    return restoring;
  }

  /// 从本地恢复各时间范围最近一次成功的统计，供首屏先显示缓存再做 BLE 刷新。
  Future<void> _restoreStatisticsCache() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      for (final range in const [
        'today',
        'yesterday',
        'threeDays',
        'sevenDays'
      ]) {
        if (_statisticsByRange.containsKey(range)) continue;
        final raw = preferences.getString('$_statisticsCacheKeyPrefix$range');
        if (raw == null) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic>) continue;
          final payload = decoded['data'];
          if (payload is! Map) continue;
          final data = StatisticsEventCache.keepCompatibleSnapshot(
            Map<String, dynamic>.from(payload),
          );
          final updatedAtMs = decoded['updatedAt'];
          // 没有可用时间或汇总字段的快照不能伪装成“今天为 0”。
          if (updatedAtMs is! int ||
              updatedAtMs <= 0 ||
              data['runtimeSeconds'] is! num ||
              data['activityCount'] is! num ||
              data['automaticCount'] is! num ||
              data['bucketSeconds'] is! List ||
              !_validNonNegativeNumbers(data['bucketSeconds'] as List)) {
            continue;
          }
          final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
          data['_cacheUpdatedAt'] = updatedAtMs;
          _statisticsCacheUpdatedAt[range] = updatedAt;
          _statisticsByRange[range] = data;
          _statisticsCachedRanges.add(range);
        } catch (error) {
          // 一个范围损坏不能阻止其余范围离线展示。
          diagnostics?.warning('统计缓存', '忽略 $range 无效快照：$error');
        }
      }
      _statisticsCacheLoaded = true;
      _notifyIfAlive();
    } catch (error) {
      _statisticsCacheLoaded = false;
      diagnostics?.warning('统计缓存', '恢复本地统计缓存失败：$error');
    }
  }

  Future<void> _persistStatisticsCache(
    String range,
    Map<String, dynamic> data,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final updatedAt = DateTime.now();
      await preferences.setString(
        '$_statisticsCacheKeyPrefix$range',
        jsonEncode({
          'updatedAt': updatedAt.millisecondsSinceEpoch,
          'data': {
            ...data,
            'eventsIdentityVersion': StatisticsEventCache.schemaVersion
          },
        }),
      );
      _statisticsCacheUpdatedAt[range] = updatedAt;
    } catch (error) {
      diagnostics?.warning('统计缓存', '保存本地统计缓存失败：$error');
    }
  }

  String _statisticsDatasetScopeKey(String scope) =>
      '$_statisticsDatasetScopePrefix${Uri.encodeComponent(scope)}';

  String _statisticsPeerScopeKey(String scope) =>
      '$_statisticsPeerScopePrefix${Uri.encodeComponent(scope)}';

  String _statisticsDatasetEpochKey(String deviceId) =>
      '$_statisticsDatasetEpochPrefix$deviceId';

  String _statisticsRangeSnapshotKey(String deviceId, StatisticsQuery query) =>
      '$_statisticsRangeCachePrefix$deviceId.${query.cacheKey}';

  Future<String?> _statisticsDatasetForScope(String scope) {
    final known = _statisticsDatasetByScope[scope];
    if (known != null) return Future.value(known);
    final pending = _statisticsDatasetLoadsByScope[scope];
    if (pending != null) return pending;
    final completion = Completer<String?>();
    _statisticsDatasetLoadsByScope[scope] = completion.future;
    unawaited(() async {
      try {
        final preferences = await SharedPreferences.getInstance();
        var datasetId =
            preferences.getString(_statisticsDatasetScopeKey(scope));
        if (datasetId == null || datasetId.isEmpty) {
          final peer = _statisticsPeerScopeByScope[scope] ??
              preferences.getString(_statisticsPeerScopeKey(scope));
          if (peer != null && peer.isNotEmpty) {
            _statisticsPeerScopeByScope[scope] = peer;
            datasetId = preferences.getString(_statisticsDatasetScopeKey(peer));
          }
        }
        if (datasetId != null && datasetId.isNotEmpty) {
          _statisticsDatasetByScope[scope] = datasetId;
          await preferences.setString(
              _statisticsDatasetScopeKey(scope), datasetId);
        }
        completion.complete(datasetId);
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        _statisticsDatasetLoadsByScope.remove(scope);
      }
    }());
    return completion.future;
  }

  Future<void> _registerStatisticsScopePeer(
      String bleScope, String wifiScope) async {
    _statisticsPeerScopeByScope[bleScope] = wifiScope;
    _statisticsPeerScopeByScope[wifiScope] = bleScope;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_statisticsPeerScopeKey(bleScope), wifiScope);
      await preferences.setString(_statisticsPeerScopeKey(wifiScope), bleScope);
      final bleDataset = _statisticsDatasetByScope[bleScope] ??
          preferences.getString(_statisticsDatasetScopeKey(bleScope));
      final wifiDataset = _statisticsDatasetByScope[wifiScope] ??
          preferences.getString(_statisticsDatasetScopeKey(wifiScope));
      final dataset = bleDataset ?? wifiDataset;
      if (dataset != null && dataset.isNotEmpty) {
        _statisticsDatasetByScope[bleScope] = dataset;
        _statisticsDatasetByScope[wifiScope] = dataset;
        await preferences.setString(
            _statisticsDatasetScopeKey(bleScope), dataset);
        await preferences.setString(
            _statisticsDatasetScopeKey(wifiScope), dataset);
      }
    } catch (error) {
      diagnostics?.warning('统计缓存', '保存 BLE 与 NAS 设备映射失败：$error');
    }
  }

  /// 从 NAS 切回 BLE 前确认两个连接身份对应同一设备，使统计页立即复用对端缓存。
  /// 已有映射时不增加 BLE 往返；首次建立映射失败不影响控制通道切换。
  Future<void> prepareBluetoothStatisticsCacheScope() async {
    final binding = _wifiBinding;
    final bleDeviceId = ble.connectedDeviceId;
    if (binding == null || bleDeviceId == null || !ble.isConnected) return;
    final bleScope = 'ble:$bleDeviceId';
    final wifiScope = 'wifi:${binding.deviceId}';
    if (_statisticsPeerScopeByScope[bleScope] == wifiScope) return;

    try {
      final preferences = await SharedPreferences.getInstance();
      final savedPeer =
          preferences.getString(_statisticsPeerScopeKey(bleScope));
      if (savedPeer == wifiScope) {
        _statisticsPeerScopeByScope[bleScope] = wifiScope;
        _statisticsPeerScopeByScope[wifiScope] = bleScope;
        return;
      }
    } catch (error) {
      diagnostics?.info('统计缓存', '读取 BLE/NAS 缓存映射失败，尝试重新确认：$error');
    }

    try {
      final identity = await ble.requestWifi({'op': 'wifi.status'}).timeout(
          const Duration(seconds: 2));
      final body = jsonDecode(identity.body);
      if (identity.statusCode == 200 &&
          body is Map<String, dynamic> &&
          body['deviceId'] == binding.deviceId) {
        await _registerStatisticsScopePeer(bleScope, wifiScope);
      } else {
        diagnostics?.info('统计缓存', 'BLE 与 NAS 设备身份未匹配，切回时跳过缓存共享');
      }
    } catch (error) {
      diagnostics?.info('统计缓存', '无法建立 BLE/NAS 缓存映射，仍继续蓝牙切换：$error');
    }
  }

  /// 先按当前连接身份找出统计数据集，再恢复匹配的协议 v2 快照。
  /// BLE 地址、NAS 绑定 ID 与统计 deviceId 不同，必须使用已验证的映射。
  Future<void> _restoreStatisticsRangeCache(
      StatisticsQuery query, String scope) async {
    final currentKey = _rangeKey(query);
    if (_statisticsRangeByKey.containsKey(currentKey)) return;
    try {
      if (_disposed || scope != _rangeScope) return;
      final datasetId = await _statisticsDatasetForScope(scope);
      if (datasetId == null || datasetId.isEmpty) return;
      final preferences = await SharedPreferences.getInstance();
      _statisticsDatasetByScope[scope] = datasetId;
      final raw =
          preferences.getString(_statisticsRangeSnapshotKey(datasetId, query));
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['cacheKey'] != query.cacheKey ||
          decoded['deviceId'] != datasetId ||
          decoded['from'] != query.from ||
          decoded['tzOffsetSeconds'] != query.tzOffsetSeconds ||
          decoded['updatedAt'] is! int ||
          decoded['dataEpoch'] is! String ||
          decoded['data'] is! Map) {
        return;
      }
      final data = Map<String, dynamic>.from(decoded['data'] as Map);
      final epoch = decoded['dataEpoch'] as String;
      if (data['apiVersion'] != 2 ||
          data['deviceId'] != datasetId ||
          data['dataEpoch'] != epoch ||
          epoch.isEmpty) {
        return;
      }
      final knownEpoch = _rangeEpochByScope[scope] ??
          preferences.getString(_statisticsDatasetEpochKey(datasetId));
      if (knownEpoch != null && knownEpoch != epoch) return;
      final updatedAtMs = decoded['updatedAt'] as int;
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
      data['_cacheUpdatedAt'] = updatedAtMs;
      _rangeEpochByScope[scope] = epoch;
      final key = _rangeKey(query);
      _statisticsRangeByKey[key] = data;
      _statisticsRangeUpdatedAt[key] = updatedAt;
      _notifyIfAlive();
    } catch (error) {
      diagnostics?.warning('统计缓存', '恢复范围快照失败：$error');
    }
  }

  Future<void> _persistStatisticsRangeCache(
    StatisticsQuery query,
    String scope,
    String deviceId,
    Map<String, dynamic> data, {
    required DateTime updatedAt,
  }) async {
    final epoch = data['dataEpoch']?.toString();
    if (deviceId.isEmpty || epoch == null || epoch.isEmpty) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final snapshotKey = _statisticsRangeSnapshotKey(deviceId, query);
      await preferences.setString(_statisticsDatasetScopeKey(scope), deviceId);
      await preferences.setString(_statisticsDatasetEpochKey(deviceId), epoch);
      _statisticsDatasetByScope[scope] = deviceId;
      final peer = _statisticsPeerScopeByScope[scope] ??
          preferences.getString(_statisticsPeerScopeKey(scope));
      if (peer != null && peer.isNotEmpty) {
        _statisticsPeerScopeByScope[scope] = peer;
        _statisticsPeerScopeByScope[peer] = scope;
        _statisticsDatasetByScope[peer] = deviceId;
        await preferences.setString(_statisticsDatasetScopeKey(peer), deviceId);
      }
      await preferences.setString(
        snapshotKey,
        jsonEncode({
          'version': 1,
          'cacheKey': query.cacheKey,
          'from': query.from,
          'to': query.to,
          'tzOffsetSeconds': query.tzOffsetSeconds,
          'deviceId': deviceId,
          'dataEpoch': epoch,
          'updatedAt': updatedAt.millisecondsSinceEpoch,
          'data': data,
        }),
      );
      // 范围快照有固定上限，避免自定义日期查询无限增长本地偏好存储。
      final keys = preferences
          .getKeys()
          .where((key) => key.startsWith(_statisticsRangeCachePrefix))
          .toList();
      if (keys.length <= 20) return;
      final entries = <(String, int)>[];
      for (final key in keys) {
        if (key == snapshotKey) continue;
        try {
          final value = preferences.getString(key);
          final map = value == null ? null : jsonDecode(value);
          final timestamp = map is Map ? map['updatedAt'] : null;
          entries.add((key, timestamp is int ? timestamp : 0));
        } catch (_) {
          entries.add((key, 0));
        }
      }
      entries.sort((a, b) => a.$2.compareTo(b.$2));
      for (final entry in entries.take(keys.length - 20)) {
        await preferences.remove(entry.$1);
      }
    } catch (error) {
      diagnostics?.warning('统计缓存', '保存范围快照失败：$error');
    }
  }

  Future<void> _purgeStatisticsSnapshotsForEpoch(
      String deviceId, String currentEpoch) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final prefix = '$_statisticsRangeCachePrefix$deviceId.';
      for (final key
          in preferences.getKeys().where((key) => key.startsWith(prefix))) {
        try {
          final raw = preferences.getString(key);
          final value = raw == null ? null : jsonDecode(raw);
          if (value is! Map || value['dataEpoch'] != currentEpoch) {
            await preferences.remove(key);
          }
        } catch (_) {
          await preferences.remove(key);
        }
      }
    } catch (error) {
      diagnostics?.warning('统计缓存', '清理旧数据批次失败：$error');
    }
  }

  /// App 退到后台时释放 BLE，避免占用设备连接。
  Future<void> closeBluetoothSession() {
    // hidden/paused/detached 和 dispose 可能几乎同时触发；合并清理任务，
    // 避免并发 stopScan/disconnect 互相覆盖 BLE 管理器状态。
    final current = _closingBluetoothSession;
    if (current != null) return current;

    // 阻止正在等待连接/同步的旧调用在清理后继续写入状态。
    _connectAttempt++;
    final closing = _closeBluetoothSession();
    _closingBluetoothSession = closing;
    return closing.whenComplete(() {
      if (identical(_closingBluetoothSession, closing)) {
        _closingBluetoothSession = null;
      }
    });
  }

  Future<void> _closeBluetoothSession() async {
    _bluetoothControlReady = false;
    try {
      await ble.stopScan();
    } catch (_) {
      // 即使停止扫描失败，也继续断开 GATT，避免后台仍占用设备连接。
    }
    if (ble.isConnected ||
        ble.connectionStatus == BleConnectionStatus.connecting) {
      await ble.disconnect();
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    final closing = _closingBluetoothSession;
    if (closing != null) await closing;
    final attempt = ++_connectAttempt;
    await _loadSelectedProfile();
    if (_disposed || attempt != _connectAttempt) {
      throw StateError('连接请求已取消');
    }
    _connectionBootstrapAttempt = attempt;
    _bluetoothControlReady = false;
    lastError = null;
    _notifyIfAlive();
    int? sessionGeneration;
    try {
      final sameActiveDevice =
          ble.isConnected && ble.connectedDeviceId == device.remoteId.str;
      if (sameActiveDevice) {
        diagnostics?.info(
          '蓝牙连接',
          '设备链路仍然连接，复用现有 GATT 会话重新执行控制器初始化',
        );
      } else {
        await ble.connect(device);
      }
      if (_disposed || attempt != _connectAttempt) {
        throw StateError('连接请求已取消');
      }
      final generation = _sessionGeneration;
      sessionGeneration = generation;
      final selectedProfile = profile;
      DeviceStatus loadedStatus;
      try {
        loadedStatus = await repository.getStatus(selectedProfile);
        ble.setDeviceOtaBusy(false);
      } on DeviceBusyException catch (error) {
        _bluetoothControlReady = false;
        ble.setDeviceOtaBusy(true);
        status = null;
        settings = null;
        _settingsDraft = null;
        _offlineViewing = false;
        lastError = '已连接设备；设备正在升级，普通控制暂不可用。$error';
        _notifyIfAlive();
        return;
      }
      if (!_isCurrentSession(generation, selectedProfile) ||
          attempt != _connectAttempt) {
        return;
      }
      final minimumApp = loadedStatus.minimumAppVersion;
      final appVersion = await _resolveAppVersion();
      final compatible = minimumApp == null ||
          (appVersion != null && _compareVersions(appVersion, minimumApp) >= 0);
      ble.setFirmwareAppCompatible(compatible);
      if (!compatible) {
        _bluetoothControlReady = false;
        status = loadedStatus;
        settings = null;
        _settingsDraft = null;
        lastError = appVersion == null
            ? '无法读取 App 版本，设备要求 MimiVent App v$minimumApp 或更新版本。'
            : '当前 App v$appVersion 低于设备要求 v$minimumApp，请更新 App。';
        _notifyIfAlive();
        return;
      }
      try {
        await repository.syncClock(selectedProfile);
      } catch (error) {
        diagnostics?.warning('设备时间', '手机时间同步失败，统计日期暂不可用：$error');
      }
      if (!_isCurrentSession(generation, selectedProfile) ||
          attempt != _connectAttempt) return;
      final loadedSettings = await repository.getSettings(selectedProfile);
      if (!_isCurrentSession(generation, selectedProfile) ||
          attempt != _connectAttempt) {
        return;
      }
      status = loadedStatus;
      _updateWifiGattCacheState(loadedStatus);
      _statusInvalid = false;
      settings = loadedSettings;
      _settingsDraft =
          SettingsDraft(saved: loadedSettings, value: loadedSettings);
      _offlineViewing = false;
      _bluetoothControlReady = true;
      unawaited(_persistOfflineViewing());
      lastError = null;
      _notifyIfAlive();
    } catch (error, stackTrace) {
      if (_disposed ||
          attempt != _connectAttempt ||
          (sessionGeneration != null &&
              sessionGeneration != _sessionGeneration)) {
        return;
      }
      if (attempt == _connectAttempt) {
        _bluetoothControlReady = false;
        if (error is DeviceBusyException) {
          _bluetoothControlReady = false;
          ble.setDeviceOtaBusy(true);
          status = null;
          settings = null;
          _settingsDraft = null;
          lastError = '设备正在升级，普通控制暂不可用。';
          _notifyIfAlive();
          return;
        }
        if (error is FormatException) _statusInvalid = true;
        lastError = error.toString();
        diagnostics?.error('连接初始化', lastError!, stackTrace: stackTrace);
        _notifyIfAlive();
      }
      rethrow;
    } finally {
      if (_connectionBootstrapAttempt == attempt) {
        _connectionBootstrapAttempt = null;
        _notifyIfAlive();
      }
    }
  }

  Future<String?> _resolveAppVersion() async {
    final override = appVersionOverride;
    if (override != null && override.isNotEmpty) return override;
    final cached = _appVersionCache;
    if (cached != null) return cached;
    try {
      final version = (await PackageInfo.fromPlatform()).version;
      _appVersionCache = version;
      return version;
    } catch (error) {
      diagnostics?.warning('版本兼容', '读取 App 版本失败：$error');
      return null;
    }
  }

  int _compareVersions(String left, String right) {
    final a = left.split('.').map(int.tryParse).toList();
    final b = right.split('.').map(int.tryParse).toList();
    if (a.any((part) => part == null) || b.any((part) => part == null)) {
      return -1;
    }
    for (var i = 0; i < 3; i++) {
      final av = i < a.length ? a[i]! : 0;
      final bv = i < b.length ? b[i]! : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  Future<void> disconnect() async {
    _connectAttempt++;
    await ble.disconnect();
  }

  bool _isCurrentSession(int generation, TimingProfile profile) =>
      !_disposed &&
      (ble.isConnected || nasMqttActive) &&
      generation == _sessionGeneration &&
      profile == this.profile;

  Future<T> _nasSerial<T>(Future<T> Function() action,
          {bool priority = false}) =>
      _nasGatewayExecutor.run(action, priority: priority);

  Future<void> activateNasMqtt(WifiBinding binding) async {
    final generation = ++_nasMqttSessionGeneration;
    final bleDeviceId = ble.connectedDeviceId;
    _nasConfigurationDeadline = null;
    _nasExpectedProfile = null;
    _nasExpectedSettings = null;
    _wifiBinding = binding;
    _nasMqttSessionReady = false;
    nasStateStale = false;
    nasStateAgeMs = 0;
    _lastNasPendingDeviceId = binding.deviceId;
    _lastNasPendingTokenId = binding.tokenId;
    nasMqttLost = false;
    nasMqttBusy = false;
    _nasSyncFailures = 0;
    try {
      await _nasSerial(() => _refreshNasSnapshot(requireFresh: true),
          priority: true);
      if (_disposed ||
          generation != _nasMqttSessionGeneration ||
          !identical(_wifiBinding, binding)) {
        return;
      }
      if (nasStateStale) {
        throw const NasGatewayException(
          'DEVICE_MQTT_UNAVAILABLE',
          '设备尚未通过 NAS MQTT 上报实时状态，请检查设备 MQTT 配置和连接',
        );
      }
      // BLE 尚连着时，直接向固件确认 Broker 会话；单独的新鲜快照不足以
      // 证明此刻 MQTT 仍在线。未确认前绝不释放 BLE，失败可继续蓝牙控制。
      if (ble.isConnected) {
        final response = await ble.requestWifi({'op': 'wifi.mqtt.status'});
        final mqttStatus = jsonDecode(response.body);
        if (response.statusCode != 200 || mqttStatus is! Map<String, dynamic>) {
          throw const NasGatewayException(
            'DEVICE_MQTT_STATUS_UNAVAILABLE',
            '无法通过蓝牙确认设备 MQTT 连接状态，蓝牙连接保持不变',
          );
        }
        if (mqttStatus['configured'] != true ||
            mqttStatus['connected'] != true) {
          throw const NasGatewayException(
            'DEVICE_MQTT_UNAVAILABLE',
            '设备尚未连接 NAS MQTT Broker；请检查 MQTT 配置，蓝牙连接保持不变',
          );
        }
        // 只在同一条 BLE 会话里验证 WiFi 身份后建立跨通道缓存映射。
        // 这是尽力操作：读不到身份时不影响已经验证成功的 MQTT 控制切换。
        try {
          final identity = await ble.requestWifi({'op': 'wifi.status'});
          final identityBody = jsonDecode(identity.body);
          if (identity.statusCode == 200 &&
              identityBody is Map<String, dynamic> &&
              identityBody['deviceId'] == binding.deviceId &&
              bleDeviceId != null) {
            await _registerStatisticsScopePeer(
                'ble:$bleDeviceId', 'wifi:${binding.deviceId}');
          } else {
            diagnostics?.info('统计缓存', 'BLE 与 NAS 设备身份未匹配，跳过跨通道缓存共享');
          }
        } catch (error) {
          diagnostics?.info('统计缓存', '无法确认 BLE 与 NAS 设备映射：$error');
        }
      }
      // 新通道已通过网关实时状态和设备 MQTT 状态校验，先标记 NAS 会话可用，
      // 再释放 BLE，避免 BLE 断开与 NAS 会话生效之间出现双通道都不可用的空档。
      _nasMqttSessionReady = true;
      _notifyIfAlive();
      _startNasSync();
      // NAS MQTT 会话已建立：清掉上一次（可能是蓝牙）连接失败残留的错误，
      // 否则顶部会一直挂着"设备操作失败"，与实际状态不符。
      if (lastError != null) {
        lastError = null;
        _notifyIfAlive();
      }
      // 断开 BLE 只是释放连接槽的收尾动作；即使它失败，也不能撤销已验证可用的 NAS。
      if (ble.isConnected) {
        try {
          await ble.disconnect();
        } catch (error) {
          diagnostics?.warning('NAS MQTT 切换', 'NAS 已可用，但断开 BLE 收尾失败：$error');
        }
      }
    } catch (error) {
      if (_disposed ||
          generation != _nasMqttSessionGeneration ||
          !identical(_wifiBinding, binding)) {
        return;
      }
      _nasMqttSessionReady = false;
      _wifiBinding = null;
      if (error is NasGatewayException && error.code == 'WIFI_IN_USE') {
        nasMqttBusy = true;
      }
      // 用户仍有 BLE 控制可用时，通道切换失败由切换弹窗表达；不能混成设备
      // 操作失败横幅，否则看起来像刚才的蓝牙控制也失败了。
      lastError = ble.isConnected
          ? null
          : error is NasGatewayException
              ? error.message
              : error.toString();
      _notifyIfAlive();
      rethrow;
    }
  }

  Future<void> releaseNasMqttLease() async {
    final binding = _wifiBinding;
    if (binding == null || !nasMqttActive) return;
    try {
      final result = await _nasGatewayTransport
          .tryWrite(
            binding,
            path: '/api/lease',
            body: 'action=release',
            requestId: _requestId(),
          )
          .timeout(const Duration(seconds: 4));
      if (result?.statusCode != 200) {
        throw StateError('NAS 未确认释放 MQTT 控制租约');
      }
      diagnostics?.info('NAS MQTT 租约', '已释放 NAS MQTT 主控');
    } catch (error) {
      diagnostics?.warning('NAS MQTT 租约', '释放失败，等待租约过期：$error');
    }
  }

  void deactivateNasMqtt() {
    _nasMqttSessionGeneration++;
    _nasSyncTimer?.cancel();
    _nasSyncTimer = null;
    _nasFastSyncUntilMs = 0;
    _nasMqttSessionReady = false;
    _wifiBinding = null;
    _nasStatusAt = null;
    _fanRunStartedAt = null;
    nasMqttLost = false;
    nasMqttBusy = false;
    nasStateStale = false;
    nasStateAgeMs = 0;
    _nasSyncFailures = 0;
    _notifyIfAlive();
  }

  void _startNasSync() {
    _nasSyncTimer?.cancel();
    _scheduleNasSync();
  }

  void setAppForeground(bool value) {
    if (_appForeground == value) return;
    _appForeground = value;
    if (nasMqttActive) _startNasSync();
  }

  void _scheduleNasSync() {
    if (!_appForeground || !nasMqttActive || _disposed) return;
    final fastSync =
        DateTime.now().millisecondsSinceEpoch < _nasFastSyncUntilMs;
    final delay = Duration(seconds: fastSync ? 1 : 2);
    _nasSyncTimer = Timer(delay, () {
      if (!nasMqttActive || _disposed) return;
      if (pendingNasMqttAction == null && !_nasRefreshInFlight) {
        _nasRefreshInFlight = true;
        unawaited(_refreshNasSnapshot().then((_) {
          _nasSyncFailures = 0;
        }).catchError((Object error) {
          if (error is NasGatewayException && error.code == 'WIFI_IN_USE') {
            _handleNasMqttBusy(error);
            return;
          }
          _nasSyncFailures++;
          diagnostics?.warning('NAS MQTT 同步', '状态同步失败：$error');
          if (_nasSyncFailures >= 2) _handleNasMqttLost(error);
        }).whenComplete(() => _nasRefreshInFlight = false));
      }
      if (nasMqttActive) _scheduleNasSync();
    });
  }

  void _handleNasMqttLost(Object error) {
    if (!nasMqttActive) return;
    _nasMqttSessionGeneration++;
    nasMqttLost = true;
    lastError = 'NAS MQTT 状态连接已断开';
    _nasSyncTimer?.cancel();
    _nasSyncTimer = null;
    _nasFastSyncUntilMs = 0;
    _nasMqttSessionReady = false;
    _wifiBinding = null;
    _nasStatusAt = null;
    _fanRunStartedAt = null;
    status = null;
    settings = null;
    _settingsDraft = null;
    diagnostics?.warning('NAS MQTT 连接', '状态同步失败：$error');
    _notifyIfAlive();
  }

  void _handleNasMqttBusy(Object error) {
    if (!nasMqttActive) return;
    _nasMqttSessionGeneration++;
    nasMqttBusy = true;
    lastError = 'NAS MQTT 控制权已被另一台手机占用';
    _nasSyncTimer?.cancel();
    _nasSyncTimer = null;
    _nasFastSyncUntilMs = 0;
    _nasMqttSessionReady = false;
    _wifiBinding = null;
    _nasStatusAt = null;
    _fanRunStartedAt = null;
    status = null;
    settings = null;
    _settingsDraft = null;
    diagnostics?.warning('NAS MQTT 租约', 'NAS MQTT 主控已被其他手机占用：$error');
    _notifyIfAlive();
  }

  Future<void> _refreshNasSnapshot({bool requireFresh = false}) async {
    final binding = _wifiBinding;
    if (binding == null) return;
    final generation = _nasMqttSessionGeneration;
    final snapshotRevision = _nasSnapshotRevision;
    final readStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> data;
    final result = await _nasGatewayTransport.tryReadState(binding);
    if (_disposed ||
        generation != _nasMqttSessionGeneration ||
        snapshotRevision != _nasSnapshotRevision ||
        !identical(_wifiBinding, binding)) {
      return;
    }
    if (result == null) {
      throw const NasGatewayException(
          'GATEWAY_UNAVAILABLE', 'NAS 网关未启用或不可达，请改用蓝牙读取设备状态');
    }
    if (result.statusCode != 200) {
      throw NasGatewayException(
        result.body['error']?.toString() ??
            'NAS_GATEWAY_HTTP_${result.statusCode}',
        'NAS 网关暂时无法读取设备状态，请检查网关连接或改用蓝牙',
      );
    }
    data = result.body;
    if (data['deviceId'] != binding.deviceId ||
        data['tokenId'] != binding.tokenId ||
        data['bindingState'] != 'active') {
      throw const NasGatewayException(
          'GATEWAY_IDENTITY_MISMATCH', 'NAS 返回的设备或绑定身份不匹配');
    }
    final rawAge = data['stateAgeMs'];
    final reportedAgeMs = rawAge is num && rawAge >= 0
        ? rawAge
            .toInt()
            .clamp(0, const Duration(days: 1).inMilliseconds)
            .toInt()
        : 0;
    // 网关在生成响应时计算 stateAgeMs。用请求发起时的控制年龄作比较，
    // 避免 HTTP 返回延迟掩盖“状态快照早于本次控制”的事实。
    final controlAgeAtReadStart = _nasControlAppliedAtMs == 0
        ? 1 << 30
        : readStartedAtMs - _nasControlAppliedAtMs;
    final ageMs = reportedAgeMs;
    nasStateAgeMs = ageMs;
    nasStateStale = data['stale'] != false || data['stateFreshness'] != 'fresh';
    if (requireFresh && nasStateStale) {
      throw const NasGatewayException(
        'DEVICE_MQTT_UNAVAILABLE',
        '设备尚未通过 NAS MQTT 上报实时状态，请检查设备 MQTT 配置和连接',
      );
    }
    if (pendingNasMqttAction != null) return;
    // 控制刚落地时丢弃出发于控制之前的陈旧快照，避免 UI 回退再跳回。
    if (controlAgeAtReadStart >= 0 &&
        controlAgeAtReadStart < 3000 &&
        ageMs > controlAgeAtReadStart) {
      return;
    }
    final loaded = DeviceStatus.fromJson(data);
    final loadedSettings = TimingSettings.fromJson(data);
    final deadline = _nasConfigurationDeadline;
    if (deadline != null) {
      final matches = (_nasExpectedProfile == null ||
              loaded.activeProfile == _nasExpectedProfile) &&
          (_nasExpectedSettings == null ||
              loadedSettings.toFormBody() ==
                  _nasExpectedSettings!.toFormBody());
      if (!matches && DateTime.now().isBefore(deadline)) return;
      _nasConfigurationDeadline = null;
      _nasExpectedProfile = null;
      _nasExpectedSettings = null;
    }
    final wasFanOn = status?.fan == true;
    status = loaded;
    _nasStatusAt = DateTime.now().subtract(Duration(milliseconds: ageMs));
    if (loaded.fan) {
      if (!wasFanOn || _fanRunStartedAt == null) {
        _fanRunStartedAt = DateTime.now()
            .subtract(Duration(milliseconds: loaded.fanRunMs + ageMs));
      }
    } else {
      _fanRunStartedAt = null;
    }
    profile = loaded.activeProfile;
    settings = loadedSettings;
    if (_settingsDraft == null || !_settingsDraft!.isDirty) {
      _settingsDraft =
          SettingsDraft(saved: loadedSettings, value: loadedSettings);
    }
    _statusInvalid = false;
    _nasVersionCompatible = true;
    lastError = null;
    _notifyIfAlive();
  }

  String _requestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  bool _nasTransient(Object error) {
    if (error is TimeoutException || error is SocketException) return true;
    if (error is NasGatewayException) {
      return const {
        'HTTP_INCOMPLETE',
        'HTTP_FORMAT',
        'RESOURCE_BUSY',
        'RATE_LIMITED',
        'QUERY_BUSY',
      }.contains(error.code);
    }
    return false;
  }

  /// 所有 WiFi MQTT 查询串行化，限制设备查询响应与控制 ACK 争抢队列。
  Future<Map<String, dynamic>> _nasReadPath(String path,
      {bool priority = false, bool Function()? shouldRead}) {
    final generation = _nasMqttSessionGeneration;
    final queued = Stopwatch()..start();
    return _nasSerial(() async {
      if (generation != _nasMqttSessionGeneration ||
          (shouldRead != null && !shouldRead())) {
        throw _ObsoleteStatisticsQuery();
      }
      final queueMs = queued.elapsedMilliseconds;
      final request = Stopwatch()..start();
      try {
        return await _nasReadPathUnlocked(path);
      } finally {
        diagnostics?.info('NAS MQTT 耗时',
            'query path=$path queueMs=$queueMs requestMs=${request.elapsedMilliseconds}');
      }
    }, priority: priority);
  }

  Future<Map<String, dynamic>> _nasReadPathUnlocked(String path) async {
    final binding = _wifiBinding;
    if (binding == null) {
      throw StateError('NAS MQTT 控制通道不可用');
    }
    for (var attempt = 0;; attempt++) {
      try {
        return await _nasGatewayTransport.readPath(binding, path);
      } catch (error) {
        if (attempt == 0 && _nasTransient(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _nasMqttWrite(String path, String body) {
    final binding = _wifiBinding;
    final generation = _nasMqttSessionGeneration;
    final queued = Stopwatch()..start();
    // 控制保持独立串行；设备允许控制与只读查询共存，不能被统计整页传输挡住。
    return _nasControlExecutor.run(() async {
      if (generation != _nasMqttSessionGeneration ||
          !identical(binding, _wifiBinding)) {
        throw StateError('NAS MQTT 会话已变化，本次控制未发送');
      }
      final queueMs = queued.elapsedMilliseconds;
      final request = Stopwatch()..start();
      _nasWritesInFlight++;
      _notifyIfAlive();
      try {
        await _nasMqttWriteUnlocked(path, body);
      } finally {
        _nasWritesInFlight--;
        _notifyIfAlive();
        diagnostics?.info('NAS MQTT 耗时',
            'control path=$path queueMs=$queueMs requestMs=${request.elapsedMilliseconds}');
      }
    });
  }

  Future<void> _nasMqttWriteUnlocked(String path, String body) async {
    final binding = _wifiBinding;
    if (binding == null) {
      throw StateError('NAS MQTT 控制通道不可用');
    }
    final preferences = await SharedPreferences.getInstance();
    final priorRequestId =
        await NasPendingRequestStore.read(preferences, binding);
    if (priorRequestId != null) {
      final prior =
          await _nasGatewayTransport.queryRequest(binding, priorRequestId);
      if (prior?.statusCode == 200 &&
          ['applied', 'rejected'].contains(prior?.body['status'])) {
        final cleared = await NasPendingRequestStore.clear(preferences, binding,
            expectedRequestId: priorRequestId);
        if (!cleared) {
          _setPendingNasMqttRequest(
              pending: true,
              ageMs: NasPendingRequestStore.ageMs(preferences, binding),
              ageEstimated:
                  NasPendingRequestStore.isAgeEstimated(preferences, binding));
          throw StateError('上次控制已确认，但本机记录未清理；请在 NAS 页面结束确认');
        }
        _setPendingNasMqttRequest(pending: false);
        diagnostics?.info(
            'NAS MQTT 控制核对', '旧请求已确认 ${prior?.body['status']} 并清理；继续发送本次新操作');
      } else {
        final ageMs = NasPendingRequestStore.ageMs(preferences, binding);
        _setPendingNasMqttRequest(
            pending: true,
            ageMs: ageMs,
            ageEstimated:
                NasPendingRequestStore.isAgeEstimated(preferences, binding));
        if (prior == null) {
          diagnostics?.warning('NAS MQTT 控制核对',
              '查询上次 requestId 失败；pendingRequestAgeMs=${ageMs ?? 'unknown'}；原请求保留，本次新控制未发送');
          throw StateError('NAS 网关查询失败，无法确认上次控制结果；原请求已保留，本次新控制未发送');
        }
        final priorStatus = prior.body['status']?.toString();
        if (prior.statusCode == 200 && priorStatus == 'pending') {
          throw StateError('设备仍在处理上次控制；原请求已保留，本次新控制未发送');
        }
        if ((prior.statusCode == 200 && priorStatus == 'unknown') ||
            prior.statusCode == 404 ||
            prior.body['error'] == 'UNKNOWN') {
          diagnostics?.warning('NAS MQTT 控制核对',
              '设备结果 unknown；pendingRequestAgeMs=${ageMs ?? 'unknown'}；原请求保留');
          throw StateError('设备无法确认上次控制是否执行；原请求已保留，请核对设备状态后在 NAS 页面结束确认');
        }
        throw StateError(
            '查询上次控制结果失败（HTTP ${prior.statusCode}）；原请求已保留，本次新控制未发送');
      }
    }
    final requestId = _requestId();
    if (!await NasPendingRequestStore.save(preferences, binding, requestId)) {
      throw StateError('无法保存待确认请求，控制未发送');
    }
    _setPendingNasMqttRequest(pending: true, ageMs: 0);
    final result = await _nasGatewayTransport.tryWrite(binding,
        path: path, body: body, requestId: requestId);
    if (result == null) {
      final cleared = await NasPendingRequestStore.clear(preferences, binding,
          expectedRequestId: requestId);
      if (cleared) _setPendingNasMqttRequest(pending: false);
      throw StateError('NAS 网关未启用，请连接蓝牙控制设备');
    }
    if (result.statusCode != 200) {
      final code =
          result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
      final outcomeKnown = result.commandOutcomeKnown ||
          result.body['commandPublished'] == false;
      if (result.body['resultUnknown'] != true && outcomeKnown) {
        final cleared = await NasPendingRequestStore.clear(preferences, binding,
            expectedRequestId: requestId);
        if (cleared) {
          _setPendingNasMqttRequest(pending: false);
        } else {
          _setPendingNasMqttRequest(
              pending: true,
              ageMs: NasPendingRequestStore.ageMs(preferences, binding));
          diagnostics?.warning(
              'NAS MQTT 控制核对', '设备结果已明确但本机 pending 清理失败 requestId=$requestId');
        }
      }
      diagnostics?.warning(
          'NAS MQTT 控制拒绝', 'POST $path HTTP ${result.statusCode} $code');
      if (result.body['resultUnknown'] == true) {
        throw StateError('控制结果未知，已保留请求编号并阻止重复操作；请刷新状态或连接蓝牙核实');
      }
      if (result.statusCode == 409 && code == 'DEVICE_CONTROL_BUSY') {
        throw StateError('设备正在处理另一条控制请求，请刷新状态后再操作');
      }
      if (result.statusCode == 409 && code == 'COMMAND_EXPIRED') {
        throw StateError('控制指令到达过慢，设备已拒绝执行，请重试');
      }
      if (result.statusCode == 409 && code == '当前有限时任务，请先确认停止并切换') {
        throw const _ControlReplacementRequired();
      }
      if (result.statusCode == 409) {
        throw StateError('设备正在执行其他流程，请先确认“停止并切换”后再试');
      }
      if (result.statusCode == 423) {
        throw StateError('设备正在升级，暂时不能控制');
      }
      if (code.contains('RESOURCE_BUSY')) {
        throw StateError('设备正忙，请稍后重试');
      }
      if (code.contains('DEDUP_UNAVAILABLE')) {
        throw StateError('设备请求记录已满，请重启设备后再试');
      }
      throw StateError('设备未完成 NAS MQTT 控制（$code）');
    }
    final cleared = await NasPendingRequestStore.clear(preferences, binding,
        expectedRequestId: requestId);
    if (cleared) {
      _setPendingNasMqttRequest(pending: false);
    } else {
      _setPendingNasMqttRequest(
          pending: true,
          ageMs: NasPendingRequestStore.ageMs(preferences, binding));
    }
    // 写请求成功后立即返回，状态刷新排队在后台完成，避免控制按钮等待两次 TLS。
    unawaited(_refreshNasSnapshot().catchError((Object error) {
      diagnostics?.warning('NAS MQTT 状态', '写后刷新失败：$error');
    }));
  }

  void _setPendingNasMqttRequest(
      {required bool pending, int? ageMs, bool ageEstimated = false}) {
    hasPendingNasMqttRequest = pending;
    pendingNasMqttRequestAgeMs = ageMs;
    pendingNasMqttRequestAgeEstimated = pending && ageEstimated;
    _pendingNasMqttRequestCreatedAtMs =
        ageMs == null ? null : DateTime.now().millisecondsSinceEpoch - ageMs;
    _notifyIfAlive();
  }

  Future<void> refreshPendingNasMqttRequest() async {
    final deviceId = _lastNasPendingDeviceId;
    final tokenId = _lastNasPendingTokenId;
    if (deviceId == null || tokenId == null) return;
    final preferences = await SharedPreferences.getInstance();
    final current =
        preferences.getString(NasPendingRequestStore.keyFor(deviceId, tokenId));
    final legacy = preferences
        .getString(NasPendingRequestStore.legacyKeyFor(deviceId, tokenId));
    final pending = current != null || legacy != null;
    final createdAt = preferences
        .getInt(NasPendingRequestStore.createdAtKeyFor(deviceId, tokenId));
    final ageMs = !pending || createdAt == null
        ? null
        : (DateTime.now().millisecondsSinceEpoch - createdAt)
            .clamp(0, 0x7fffffffffffffff)
            .toInt();
    final ageEstimated = preferences.getBool(
            NasPendingRequestStore.estimatedAgeKeyFor(deviceId, tokenId)) ??
        false;
    _setPendingNasMqttRequest(
        pending: pending, ageMs: ageMs, ageEstimated: ageEstimated);
  }

  Future<void> refresh({int? expectedGeneration}) async {
    if (nasMqttActive) {
      await _nasSerial(_refreshNasSnapshot, priority: true);
      return;
    }
    if (_offlineViewing ||
        !ble.isConnected ||
        ble.isOtaUploading ||
        ble.isOtaVerifying ||
        _connectionBootstrapInProgress ||
        _polling) {
      return;
    }
    _polling = true;
    final generation = expectedGeneration ?? _sessionGeneration;
    final selectedProfile = profile;
    if (generation != _sessionGeneration) {
      _polling = false;
      return;
    }
    try {
      final loaded = await repository.getStatus(selectedProfile);
      if (_disposed ||
          !ble.isConnected ||
          generation != _sessionGeneration ||
          selectedProfile != profile) {
        return;
      }
      final minimumApp = loaded.minimumAppVersion;
      final appVersion = await _resolveAppVersion();
      final compatible = minimumApp == null ||
          (appVersion != null && _compareVersions(appVersion, minimumApp) >= 0);
      ble.setFirmwareAppCompatible(compatible);
      status = loaded;
      _updateWifiGattCacheState(loaded);
      ble.setDeviceOtaBusy(false);
      _statusInvalid = false;
      if (!compatible) {
        settings = null;
        _settingsDraft = null;
        lastError = appVersion == null
            ? '无法读取 App 版本，设备要求 MimiVent App v$minimumApp 或更新版本。'
            : '当前 App v$appVersion 低于设备要求 v$minimumApp，请更新 App。';
        return;
      }
      if (settings == null) {
        // OTA 自动重连由传输层建立会话，首轮恢复配置时补做校时。
        try {
          await repository.syncClock(selectedProfile);
        } catch (error) {
          diagnostics?.warning('设备时间', '重连后校时失败：$error');
        }
        if (_disposed ||
            !ble.isConnected ||
            generation != _sessionGeneration ||
            selectedProfile != profile) {
          return;
        }
        final loadedSettings = await repository.getSettings(selectedProfile);
        if (_disposed ||
            !ble.isConnected ||
            generation != _sessionGeneration ||
            selectedProfile != profile) {
          return;
        }
        settings = loadedSettings;
        _settingsDraft =
            SettingsDraft(saved: loadedSettings, value: loadedSettings);
      }
      lastError = null;
    } catch (error) {
      if (error is DeviceBusyException) {
        ble.setDeviceOtaBusy(true);
        status = null;
        settings = null;
        _settingsDraft = null;
        lastError = '设备正在升级，普通控制暂不可用。';
        return;
      }
      if (!_disposed && generation == _sessionGeneration) {
        if (error is FormatException) _statusInvalid = true;
        lastError = error.toString();
      }
    } finally {
      _polling = false;
      _notifyIfAlive();
    }
  }

  void _updateWifiGattCacheState(DeviceStatus loaded) {
    final stale = loaded.capabilities.contains('wifi.configure') &&
        !ble.hasWifiProvisioningService;
    if (stale == wifiGattCacheStale) return;
    wifiGattCacheStale = stale;
    if (stale) {
      diagnostics?.warning(
        'WiFi 配网',
        '固件支持 WiFi 配网，但当前手机未发现 WiFi GATT 服务；可能需要清除旧 BLE 服务缓存后重新连接。',
      );
    }
    _notifyIfAlive();
  }

  /// 统一范围查询。粒度由固件决定，App 不传 bucketHours。
  ///
  /// 查询键在今日刷新期间稳定；设备身份、数据批次和协议版本由控制器隔离。
  Future<void> refreshStatisticsRange(StatisticsQuery query,
      {bool priority = true, bool Function()? shouldRead}) {
    if (!query.valid ||
        _offlineViewing ||
        (!ble.isConnected && !nasMqttActive) ||
        !supportsStatisticsRange) {
      return Future<void>.value();
    }
    final key = _rangeKey(query);
    // 新的页面调用接管读取意愿；相同范围共享真正完成的 Future。
    _statisticsRangeReadGuards[key] = shouldRead ?? () => true;
    final existing = _statisticsRangeRequests[key];
    if (existing != null) return existing;
    final completion = Completer<void>();
    _statisticsRangeRequests[key] = completion.future;
    unawaited(() async {
      try {
        await _refreshStatisticsRange(query,
            priority: priority,
            shouldRead: () => _statisticsRangeReadGuards[key]?.call() ?? false);
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        if (identical(_statisticsRangeRequests[key], completion.future)) {
          _statisticsRangeRequests.remove(key);
          _statisticsRangeReadGuards.remove(key);
        }
        _notifyIfAlive();
      }
    }());
    return completion.future;
  }

  Future<void> _refreshStatisticsRange(StatisticsQuery query,
      {required bool priority, required bool Function() shouldRead}) async {
    final scope = _rangeScope;
    final epochAtStart = _rangeEpochByScope[scope];
    final generation = _sessionGeneration;
    final selectedProfile = profile;
    await _restoreStatisticsRangeCache(query, scope);
    if (_disposed) return;
    if (scope != _rangeScope) throw _ObsoleteStatisticsQuery();
    if (!shouldRead()) throw _ObsoleteStatisticsQuery();
    _notifyIfAlive();
    try {
      final Map<String, dynamic> loaded;
      if (nasMqttActive) {
        // 主数据插队：切 Tab 时图表/汇总要最先出来，事件明细可以稍后。
        loaded = await _nasReadPath(
          '/api/stats/range?from=${query.from}&to=${query.to}'
          '&tzOffsetSeconds=${query.tzOffsetSeconds}',
          priority: priority,
          shouldRead: shouldRead,
        );
      } else {
        loaded = await repository.getStatisticsRange(
          selectedProfile,
          from: query.from,
          to: query.to,
          tzOffsetSeconds: query.tzOffsetSeconds,
        );
      }
      if (generation != _sessionGeneration ||
          scope != _rangeScope ||
          (epochAtStart != _rangeEpochByScope[scope] &&
              loaded['dataEpoch']?.toString() != _rangeEpochByScope[scope])) {
        return;
      }
      if (!loaded.containsKey('apiVersion') || loaded['apiVersion'] != 2) {
        diagnostics?.warning('统计范围', '固件返回的 apiVersion 不是 2，已忽略该响应');
        return;
      }
      // 数据批次变化后，旧的按日快照不能再与新的下标混用。
      final epoch = loaded['dataEpoch']?.toString();
      final device = loaded['deviceId']?.toString();
      if (device == null || device.isEmpty || epoch == null || epoch.isEmpty) {
        diagnostics?.warning('统计范围', '响应缺少 deviceId 或 dataEpoch，未缓存该快照');
        return;
      }
      _rangeEpochByScope[scope] = epoch;
      _statisticsDatasetByScope[scope] = device;
      final stale = _statisticsRangeByKey.entries
          .where((entry) =>
              (entry.key.startsWith('$scope|') ||
                  entry.value['deviceId']?.toString() == device) &&
              entry.value['dataEpoch']?.toString() != epoch)
          .map((entry) => entry.key)
          .toList();
      for (final staleKey in stale) {
        _rangeEpochByScope[staleKey.split('|').first] = epoch;
        _statisticsRangeByKey.remove(staleKey);
        _statisticsRangeUpdatedAt.remove(staleKey);
      }
      unawaited(_purgeStatisticsSnapshotsForEpoch(device, epoch));
      final key = _rangeKey(query);
      final updatedAt = DateTime.now();
      loaded['_cacheUpdatedAt'] = updatedAt.millisecondsSinceEpoch;
      _statisticsRangeByKey[key] = loaded;
      _statisticsRangeUpdatedAt[key] = updatedAt;
      unawaited(_persistStatisticsRangeCache(query, scope, device, loaded,
          updatedAt: updatedAt));
    } catch (error) {
      if (error is _ObsoleteStatisticsQuery) {
        diagnostics?.info('统计范围', '已取消切走页面的排队查询');
      } else {
        diagnostics?.error('统计范围', '查询失败：$error');
      }
      rethrow;
    } finally {
      _notifyIfAlive();
    }
  }

  /// 范围视图的事件明细：新接口不返回事件，单独拉一页并合并进范围缓存。
  ///
  /// 只用于单日范围；多日范围按文档不提供明细。
  Future<void> refreshRangeEventPage(StatisticsQuery query,
      {int? beforeId,
      int? windowStart,
      int? windowEnd,
      bool priority = true,
      bool Function()? shouldRead}) async {
    if (_offlineViewing || (!ble.isConnected && !nasMqttActive)) return;
    if (!supportsStatisticsRange) return;
    // 多日范围默认不按整段拉（32 条一页远远不够）；
    // 点某根柱时会用 windowStart/windowEnd 只取那一段。
    if (!query.singleDay && windowStart == null) return;
    final queryFrom = windowStart ?? query.from;
    final queryTo = windowEnd ??
        (_statisticsRangeByKey[_rangeKey(query)]?['to'] as num?)?.toInt() ??
        query.to;
    final key = _rangeKey(query);
    final cached = _statisticsRangeByKey[key];
    if (cached == null) return;
    final generation = _sessionGeneration;
    try {
      final Map<String, dynamic> page;
      if (nasMqttActive) {
        final cursor = beforeId == null ? '' : '&beforeId=$beforeId';
        page = await _nasReadPath(
          '/api/events?start=$queryFrom&end=$queryTo'
          '&kind=all&limit=8$cursor',
          priority: priority,
          shouldRead: shouldRead,
        );
      } else {
        final result = await repository.queryEvents(
          profile,
          DeviceEventQuery(
            start: DateTime.fromMillisecondsSinceEpoch(queryFrom * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(queryTo * 1000),
            beforeId: beforeId,
          ),
        );
        page = {
          'events': result.events.map((event) => event.toJson()).toList(),
          'total': result.total,
          'hasMore': result.hasMore,
          'nextCursor': result.nextCursor,
        };
      }
      if (generation != _sessionGeneration ||
          key != _rangeKey(query) ||
          !identical(cached, _statisticsRangeByKey[key])) {
        return;
      }
      // 按柱窗口取到的事件单独存：整范围刷新会重写 'events'，
      // 混在一起会导致用户点开的详情在每分钟刷新时被冲掉。
      final slot = windowStart == null ? 'events' : 'intervalEvents';
      final next = page['nextCursor'];
      if (page['hasMore'] == true &&
          (next is! num || (beforeId != null && next.toInt() >= beforeId))) {
        throw const FormatException('事件分页游标没有前进，请刷新统计后重试');
      }
      final existing = cached[slot];
      final incoming = (page['events'] as List?) ?? const [];
      final merged = beforeId == null
          ? List<dynamic>.from(incoming)
          : <dynamic>[...(existing is List ? existing : const []), ...incoming];
      cached[slot] = merged;
      cached['${slot}HasMore'] = page['hasMore'] == true;
      cached['${slot}NextCursor'] = page['nextCursor'];
      cached['eventsTotal'] = page['total'];
      // 事件接口的完整性判定与统计接口同源，优先用它覆盖 detail。
      if (page['detailStatus'] != null) {
        cached['detail'] = {
          'status': page['detailStatus'],
          'complete': page['detailComplete'] == true,
          'timeUntrusted': page['timeUntrusted'] == true,
        };
      }
      final datasetId = cached['deviceId']?.toString();
      final updatedAt = DateTime.now();
      cached['_cacheUpdatedAt'] = updatedAt.millisecondsSinceEpoch;
      _statisticsRangeUpdatedAt[key] = updatedAt;
      if (datasetId != null && datasetId.isNotEmpty) {
        unawaited(_persistStatisticsRangeCache(
          query,
          _rangeScope,
          datasetId,
          cached,
          updatedAt: updatedAt,
        ));
      }
      _notifyIfAlive();
    } catch (error) {
      if (error is _ObsoleteStatisticsQuery) {
        diagnostics?.info('统计范围', '已取消切走页面的事件查询');
      } else {
        diagnostics?.error('统计范围', '事件明细查询失败：$error');
      }
      rethrow;
    }
  }

  /// 切换数据批次或断开连接时作废范围缓存。
  void clearStatisticsRangeCache() {
    if (_statisticsRangeByKey.isEmpty && _statisticsRangeRequests.isEmpty) {
      return;
    }
    _statisticsRangeByKey.clear();
    _statisticsRangeUpdatedAt.clear();
    _rangeEpochByScope.clear();
    _statisticsRangeRequests.clear();
    _statisticsRangeReadGuards.clear();
    _notifyIfAlive();
  }

  Future<void> refreshStatistics(String range,
      {int? expectedGeneration,
      int eventOffset = 0,
      int? eventBeforeId}) async {
    if (_offlineViewing || (!ble.isConnected && !nasMqttActive)) return;
    if (nasMqttActive && !_nasStatsSerialized) {
      await _nasSerial(() async {
        _nasStatsSerialized = true;
        try {
          await refreshStatistics(range,
              expectedGeneration: expectedGeneration,
              eventOffset: eventOffset,
              eventBeforeId: eventBeforeId);
        } finally {
          _nasStatsSerialized = false;
        }
      });
      return;
    }
    final generation = expectedGeneration ?? _sessionGeneration;
    if (generation != _sessionGeneration) return;
    if (!_statisticsRequests.add(range)) return;
    final selectedProfile = profile;
    var restartAfterDatasetChange = false;
    _statisticsLoadingRanges.add(range);
    _statisticsFailedRanges.remove(range);
    _notifyIfAlive();
    try {
      final Map<String, dynamic> loaded;
      if (nasMqttActive) {
        if (eventOffset == 0 && eventBeforeId == null) {
          loaded = await _nasReadPath('/api/stats?mode=$range&limit=4');
          _validateStatisticsSnapshot(range, loaded);
        } else {
          final previous = _statisticsByRange[range];
          final start = _intValue(previous?['eventsStart']);
          final end = _intValue(previous?['eventsEnd']);
          final epoch = previous?['eventsDataEpoch']?.toString();
          if (start <= 0 || end <= start) return;
          final cursor =
              eventBeforeId == null ? '' : '&beforeId=$eventBeforeId';
          final query = 'start=$start&end=$end&offset=$eventOffset&limit=4'
              '&kind=all$cursor${epoch == null ? '' : '&dataEpoch=${Uri.encodeQueryComponent(epoch)}'}';
          final page = await _nasReadPath('/api/events?$query');
          loaded = {
            'events': page['events'],
            'eventsOffset': page['offset'],
            'eventsNextOffset': page['nextOffset'],
            'eventsNextCursor': page['nextCursor'],
            'eventsTotal': page['total'],
            'eventsHasMore': page['hasMore'],
            'eventsTruncated': page['eventsTruncated'],
            'eventsStart': page['start'],
            'eventsEnd': page['end'],
            'eventsDeviceId': page['deviceId'],
            'eventsDataEpoch': page['dataEpoch'],
          };
        }
      } else if (eventOffset == 0 && eventBeforeId == null) {
        loaded = await repository.getStatistics(selectedProfile, range);
        _validateStatisticsSnapshot(range, loaded);
        if (range == 'today' || range == 'yesterday') {
          // 统一用自然日原始事件查询，兼容旧固件的滚动 24 小时统计事件列表。
          final eventPage = await repository.queryEvents(
            selectedProfile,
            _eventQueryForRange(
              range,
              offset: 0,
              previous: null,
            ),
          );
          loaded.addAll({
            'events': eventPage.events.map((event) => event.toJson()).toList(),
            'eventsOffset': eventPage.offset,
            'eventsNextOffset': eventPage.nextOffset,
            'eventsNextCursor': eventPage.nextCursor ?? 0,
            'eventsTotal': eventPage.total,
            'eventsHasMore': eventPage.hasMore,
            'eventsTruncated': eventPage.eventsTruncated,
            'eventsStart': eventPage.start,
            'eventsEnd': eventPage.end,
            'eventsDeviceId': eventPage.deviceId,
            'eventsDataEpoch': eventPage.dataEpoch,
          });
        }
      } else {
        // 统计汇总只在首屏读取；继续翻页时走通用原始事件接口，减少 BLE 传输。
        final page = await repository.queryEvents(
          selectedProfile,
          _eventQueryForRange(
            range,
            offset: eventOffset,
            previous: _statisticsByRange[range],
            beforeId: eventBeforeId,
          ),
        );
        loaded = {
          'events': page.events.map((event) => event.toJson()).toList(),
          'eventsOffset': page.offset,
          'eventsNextOffset': page.nextOffset,
          'eventsNextCursor': page.nextCursor ?? 0,
          'eventsTotal': page.total,
          'eventsHasMore': page.hasMore,
          'eventsTruncated': page.eventsTruncated,
          'eventsStart': page.start,
          'eventsEnd': page.end,
          'eventsDeviceId': page.deviceId,
          'eventsDataEpoch': page.dataEpoch,
        };
      }
      if (_disposed ||
          (!ble.isConnected && !nasMqttActive) ||
          generation != _sessionGeneration ||
          selectedProfile != profile) return;
      await _invalidateOlderStatisticsDatasets(
          loaded, generation, selectedProfile);
      if (!_isCurrentSession(generation, selectedProfile)) return;
      final previous = _statisticsByRange[range];
      final merged = _mergeStatisticsPage(
        previous,
        loaded,
        offset: eventOffset,
        beforeId: eventBeforeId,
      );
      statistics = merged;
      _statisticsByRange[range] = merged;
      _statisticsCachedRanges.remove(range);
      merged.remove('_cacheUpdatedAt');
      _statisticsCacheUpdatedAt[range] = DateTime.now();
      unawaited(_persistStatisticsCache(range, merged));
      lastError = null;
    } catch (error) {
      if (!_disposed && generation == _sessionGeneration) {
        if (error.toString().contains('DATASET_CHANGED')) {
          final previous = _statisticsByRange[range];
          if (previous != null) {
            final cleared = Map<String, dynamic>.from(previous)
              ..remove('events')
              ..['eventsTotal'] = 0
              ..['eventsNextOffset'] = 0
              ..['eventsNextCursor'] = 0
              ..['eventsHasMore'] = false;
            _statisticsByRange[range] = cleared;
            statistics = cleared;
          }
          restartAfterDatasetChange = true;
        }
        _statisticsFailedRanges.add(range);
        diagnostics?.warning('设备统计', '读取统计失败：$error');
      }
    } finally {
      _statisticsRequests.remove(range);
      _statisticsLoadingRanges.remove(range);
      _notifyIfAlive();
    }
    if (restartAfterDatasetChange &&
        !_disposed &&
        (ble.isConnected || nasMqttActive)) {
      // 旧游标属于已清除的数据批次；从当前数据集首屏重新开始。
      unawaited(refreshStatistics(range, expectedGeneration: generation));
    }
  }

  /// 新数据批次到达后，其余日期的旧快照也失效，避免切换 Tab 复活旧统计。
  Future<void> _invalidateOlderStatisticsDatasets(Map<String, dynamic> incoming,
      int generation, TimingProfile selectedProfile) async {
    final epoch = incoming['dataEpoch'] ?? incoming['eventsDataEpoch'];
    final device = incoming['deviceId'] ?? incoming['eventsDeviceId'];
    if (epoch is! String || epoch.isEmpty) return;
    final stale = _statisticsByRange.entries.where((entry) {
      final old = entry.value;
      final oldEpoch = old['dataEpoch'] ?? old['eventsDataEpoch'];
      final oldDevice = old['deviceId'] ?? old['eventsDeviceId'];
      if (oldEpoch is! String || oldEpoch.isEmpty) {
        return incoming['statisticsSchema'] == 4;
      }
      return oldEpoch != epoch ||
          (device is String && oldDevice is String && device != oldDevice);
    }).toList();
    if (stale.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    for (final entry in stale) {
      if (!_isCurrentSession(generation, selectedProfile)) return;
      // 等待持久化期间，同一范围可能已被另一响应替换。
      if (!identical(_statisticsByRange[entry.key], entry.value)) continue;
      _statisticsByRange.remove(entry.key);
      _statisticsCachedRanges.remove(entry.key);
      _statisticsCacheUpdatedAt.remove(entry.key);
      await preferences.remove('$_statisticsCacheKeyPrefix${entry.key}');
    }
  }

  /// 固件按新到旧返回原始事件。分页时拼接原始记录，刷新首屏时保留已加载的旧页。
  /// 分组展示留给 App UI，这里不改变固件事件的语义或顺序。
  Map<String, dynamic> _mergeStatisticsPage(
      Map<String, dynamic>? previous, Map<String, dynamic> page,
      {required int offset, int? beforeId}) {
    // 翻页响应只有事件数据；先继承汇总字段，再用本页字段覆盖。
    final next = <String, dynamic>{...?previous, ...page};
    final freshEvents = _rawEventList(page['events']);
    final oldEvents = _rawEventList(previous?['events']);
    List<Map<String, dynamic>> mergedEvents;

    final pageStart = _intValue(page['eventsStart']);
    final oldStart = _intValue(previous?['eventsStart']);
    final sameWindow = pageStart == 0 || oldStart == 0 || pageStart == oldStart;
    final incomingTotalValue = page['eventsTotal'];
    final incomingTotal =
        incomingTotalValue is num ? incomingTotalValue.toInt() : -1;
    final discardPrevious = StatisticsEventCache.shouldDiscardPrevious(
      previous: oldEvents,
      incoming: freshEvents,
      incomingTotal: incomingTotal,
      sameWindow: sameWindow,
      firstPage: offset == 0 && beforeId == null,
      previousDataEpoch: previous?['eventsDataEpoch'] is String
          ? previous!['eventsDataEpoch'] as String
          : null,
      incomingDataEpoch: page['eventsDataEpoch'] is String
          ? page['eventsDataEpoch'] as String
          : null,
      previousDeviceId: previous?['eventsDeviceId'] is String
          ? previous!['eventsDeviceId'] as String
          : null,
      incomingDeviceId: page['eventsDeviceId'] is String
          ? page['eventsDeviceId'] as String
          : null,
    );
    final retainedOldEvents =
        sameWindow && !discardPrevious ? oldEvents : <Map<String, dynamic>>[];
    if ((offset > 0 || beforeId != null) && previous != null) {
      if (retainedOldEvents.every((event) => event['id'] is num) &&
          freshEvents.every((event) => event['id'] is num)) {
        mergedEvents = _mergeUniqueEvents(retainedOldEvents, freshEvents);
      } else {
        mergedEvents =
            _dedupeLegacyEvents([...retainedOldEvents, ...freshEvents]);
        mergedEvents.sort(
            (a, b) => _intValue(b['time']).compareTo(_intValue(a['time'])));
      }
    } else if (discardPrevious) {
      // 新 dataEpoch、ID 回退或总量收缩意味着设备已经重建数据集；
      // 首屏只使用新响应，不能在后续分支把旧缓存重新拼回来。
      mergedEvents = StatisticsEventCache.mergeFirstPage(
        previous: retainedOldEvents,
        incoming: freshEvents,
        discardPrevious: true,
      );
    } else if (oldEvents.isEmpty) {
      mergedEvents = freshEvents;
    } else if (!sameWindow) {
      mergedEvents = freshEvents;
    } else if (freshEvents.every((event) => event['id'] is num) &&
        oldEvents.every((event) => event['id'] is num)) {
      mergedEvents = _mergeUniqueEvents(oldEvents, freshEvents);
    } else {
      // 旧固件没有事件 ID 时，用重叠记录切开新旧页，避免整页重叠重复拼接。
      final oldFirstKey = _eventKey(oldEvents.first);
      final overlapIndex =
          freshEvents.indexWhere((event) => _eventKey(event) == oldFirstKey);
      mergedEvents = overlapIndex >= 0
          ? [...freshEvents.take(overlapIndex + 1), ...oldEvents.skip(1)]
          : [...freshEvents, ...oldEvents];
      mergedEvents = _dedupeLegacyEvents(mergedEvents);
      mergedEvents
          .sort((a, b) => _intValue(b['time']).compareTo(_intValue(a['time'])));
    }

    final totalValue = page['eventsTotal'];
    final total = totalValue is num ? totalValue.toInt() : mergedEvents.length;
    final hasMore =
        mergedEvents.length < total && page['eventsHasMore'] == true;
    next['events'] = mergedEvents;
    next['eventsIdentityVersion'] = StatisticsEventCache.schemaVersion;
    next['eventsOffset'] = 0;
    next['eventsNextOffset'] = mergedEvents.length;
    final ids = mergedEvents
        .map((event) => event['id'])
        .whereType<num>()
        .map((id) => id.toInt())
        .toList();
    next['eventsNextCursor'] =
        hasMore && ids.isNotEmpty ? ids.reduce((a, b) => a < b ? a : b) : 0;
    next['eventsTotal'] = total;
    next['eventsHasMore'] = hasMore;
    return next;
  }

  List<Map<String, dynamic>> _mergeUniqueEvents(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> incoming,
  ) {
    final byId = <int, Map<String, dynamic>>{};
    for (final event in existing) {
      final id = event['id'];
      if (id is num) byId[id.toInt()] = event;
    }
    // 新响应优先，活动中的事件时长可随刷新更新。
    for (final event in incoming) {
      final id = event['id'];
      if (id is num) byId[id.toInt()] = event;
    }
    final ids = byId.keys.toList()..sort((a, b) => b.compareTo(a));
    return ids.map((id) => byId[id]!).toList();
  }

  List<Map<String, dynamic>> _dedupeLegacyEvents(
    List<Map<String, dynamic>> events,
  ) {
    final seen = <String>{};
    return events.where((event) => seen.add(_eventKey(event))).toList();
  }

  List<Map<String, dynamic>> _rawEventList(Object? value) => value is List
      ? value
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList()
      : <Map<String, dynamic>>[];

  void _validateStatisticsSnapshot(
    String range,
    Map<String, dynamic> snapshot,
  ) {
    for (final key in const [
      'runtimeSeconds',
      'activityCount',
      'automaticCount',
    ]) {
      final value = snapshot[key];
      if (value is! num || value < 0 || value != value.toInt()) {
        throw FormatException('统计响应字段 $key 缺失或无效');
      }
    }
    final buckets = snapshot['bucketSeconds'];
    final expectedBucketCount = switch (range) {
      'today' => 24,
      'yesterday' => 12,
      'threeDays' => 9,
      'sevenDays' => 7,
      _ => 0,
    };
    if (buckets is! List ||
        buckets.length != expectedBucketCount ||
        !_validNonNegativeNumbers(buckets)) {
      throw const FormatException('统计响应的分桶数据缺失或无效');
    }
    final days = snapshot['days'];
    if (days != null &&
        (days is! List ||
            days.any((day) =>
                day is! Map ||
                day['date'] is! num ||
                day['runtimeSeconds'] is! num ||
                day['activityCount'] is! num ||
                day['automaticCount'] is! num))) {
      throw const FormatException('统计响应的每日汇总数据无效');
    }
  }

  bool _validNonNegativeNumbers(List values) => values.every(
        (value) => value is num && value >= 0 && value == value.toInt(),
      );

  String _eventKey(Map<String, dynamic> event) =>
      '${event['time']}|${event['kind']}|${event['state']}|${event['durationSeconds']}';

  int _intValue(Object? value) => value is num ? value.toInt() : 0;

  DeviceEventQuery _eventQueryForRange(
    String range, {
    required int offset,
    required Map<String, dynamic>? previous,
    int? beforeId,
  }) {
    final now = DateTime.now();
    final storedStart = _intValue(previous?['eventsStart']);
    final storedEnd = _intValue(previous?['eventsEnd']);
    if (storedStart > 0 && storedEnd > storedStart) {
      return DeviceEventQuery(
        start:
            DateTime.fromMillisecondsSinceEpoch(storedStart * 1000).toLocal(),
        end: DateTime.fromMillisecondsSinceEpoch(storedEnd * 1000).toLocal(),
        offset: offset,
        beforeId: beforeId,
        dataEpoch: previous?['eventsDataEpoch'] as String?,
      );
    }
    if (range == 'today') {
      return DeviceEventQuery(
        start: DateTime(now.year, now.month, now.day),
        end: now.add(const Duration(seconds: 1)),
        offset: offset,
        beforeId: beforeId,
        dataEpoch: previous?['eventsDataEpoch'] as String?,
      );
    }
    if (range == 'yesterday') {
      return DeviceEventQuery.forLocalDay(
        now.subtract(const Duration(days: 1)),
        offset: offset,
        beforeId: beforeId,
        dataEpoch: previous?['eventsDataEpoch'] as String?,
      );
    }
    throw ArgumentError.value(range, 'range', '该区间不展示原始事件列表');
  }

  Future<void> loadSettings({int? expectedGeneration}) async {
    if (nasMqttActive) {
      final generation = _nasMqttSessionGeneration;
      await _nasSerial(() async {
        // MQTT 状态快照已经包含当前生效设置；本地网络页面不得再直连设备 HTTPS。
        await _refreshNasSnapshot();
        if (_disposed ||
            generation != _nasMqttSessionGeneration ||
            !nasMqttActive) {
          return;
        }
        final loaded = settings;
        if (loaded == null) {
          throw const NasGatewayException(
              'SETTINGS_UNAVAILABLE', 'NAS 状态快照没有可用的设备设置');
        }
        settings = loaded;
        _settingsDraft = SettingsDraft(saved: loaded, value: loaded);
        _notifyIfAlive();
      }, priority: true);
      return;
    }
    if (_offlineViewing || !ble.isConnected) return;
    final generation = expectedGeneration ?? _sessionGeneration;
    if (generation != _sessionGeneration) return;
    final selectedProfile = profile;
    try {
      final loaded = await repository.getSettings(selectedProfile);
      if (_disposed ||
          !ble.isConnected ||
          generation != _sessionGeneration ||
          selectedProfile != profile) {
        return;
      }
      settings = loaded;
      _settingsDraft = SettingsDraft(saved: loaded, value: loaded);
      lastError = null;
    } catch (error) {
      if (!_disposed && generation == _sessionGeneration) {
        if (error is FormatException) {
          // 无效配置不能继续以旧快照编辑并保存，防止覆盖设备端真实配置。
          settings = null;
          _settingsDraft = null;
        }
        lastError = error.toString();
      }
    }
    _notifyIfAlive();
  }

  Future<void> switchProfile(TimingProfile next, {bool force = false}) async {
    if (next == profile && !force) return;
    if (busy) throw StateError('操作正在执行，请稍后重试');
    if (nasMqttActive) {
      busy = true;
      _beginPending('切换环境');
      try {
        await _nasMqttWrite(
            '/api/auto', 'profile=${next.wireValue}&switchProfile=1&replace=1');
        // ACK 已确认设备切换成功；一起更新页面与状态，防止短暂环境不一致。
        final loaded = TimingSettings.fromJson(
            await _nasReadPath('/api/status', priority: true));
        profile = next;
        status = status?.copyWith(
            activeProfile: next,
            viewProfile: next,
            mode: 'auto',
            phase: 'armed',
            fan: false,
            remainingMs: 0,
            startupCooldownMs: loaded.startupCooldownMs,
            leaveConfirmMs: loaded.leaveConfirmMs,
            autoExhaustMs: loaded.autoExhaustMs,
            manualExhaustMs: loaded.manualExhaustMs,
            pauseMs: loaded.pauseMs);
        settings = loaded;
        _settingsDraft = SettingsDraft(saved: loaded, value: loaded);
        _guardNasConfiguration(next, loaded);
        await _persistSelectedProfile();
      } finally {
        busy = false;
        _endPending();
      }
      return;
    }
    if (!ble.isConnected) throw StateError('蓝牙未连接，请先连接设备');
    await _perform((generation) async {
      // 固件收到 switch=1 后立即取消旧流程并切换到目标环境的自动感应。
      await repository.setAuto(next, replace: true, switchProfile: true);
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      profile = next;
      await _persistSelectedProfile();
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      final loadedStatus = await repository.getStatus(profile);
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      final loadedSettings = await repository.getSettings(profile);
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      status = loadedStatus;
      settings = loadedSettings;
      _settingsDraft =
          SettingsDraft(saved: loadedSettings, value: loadedSettings);
      _notifyIfAlive();
    }, allowMismatch: true);
  }

  /// 将设备切换到 App 当前选中的环境；即使两者页面选择相同，也允许修正设备状态。
  Future<void> switchDeviceToSelectedProfile() async {
    if (nasMqttActive) {
      await switchProfile(profile, force: true);
      return;
    }
    if (busy) throw StateError('操作正在执行，请稍后重试');
    if (!ble.isConnected) throw StateError('蓝牙未连接，请先连接设备');
    await _perform((generation) async {
      await repository.setAuto(profile, replace: true, switchProfile: true);
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      final loadedStatus = await repository.getStatus(profile);
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      final loadedSettings = await repository.getSettings(profile);
      if (_disposed || !ble.isConnected || generation != _sessionGeneration) {
        throw StateError('蓝牙会话已变化，请重新读取设备状态');
      }
      status = loadedStatus;
      settings = loadedSettings;
      _settingsDraft =
          SettingsDraft(saved: loadedSettings, value: loadedSettings);
    }, allowMismatch: true);
  }

  void _beginPending(String label) {
    lastError = null;
    pendingNasMqttAction = label;
    // 使控制开始前发出的状态读取失效，不能让迟到的旧响应回滚乐观状态。
    _nasSnapshotRevision++;
    _nasControlAppliedAtMs = DateTime.now().millisecondsSinceEpoch;
    _notifyIfAlive();
  }

  void _endPending() {
    if (pendingNasMqttAction == null) return;
    // 控制期间发出的读取也可能在 ACK 后才返回；让它们失效，随后立即补读。
    _nasSnapshotRevision++;
    pendingNasMqttAction = null;
    _notifyIfAlive();
    _boostNasSyncAfterControl();
  }

  /// 控制请求结束后短暂加快缓存读取，尽快确认设备最终状态。
  /// 设备状态仍由 MQTT 主动上报；这里仅缩短 App 读取 NAS 缓存的间隔。
  void _boostNasSyncAfterControl() {
    if (!nasMqttActive || !_appForeground || _disposed) return;
    _nasFastSyncUntilMs = DateTime.now().millisecondsSinceEpoch +
        const Duration(seconds: 5).inMilliseconds;
    _nasSyncTimer?.cancel();
    _scheduleNasSync();
  }

  void _applyWifiOptimistic({
    required String mode,
    required String phase,
    required bool fan,
    int? remainingMs,
    int? durationMs,
  }) {
    // 标记控制起点：此刻之前出发的读取结果都已经过时。
    _nasControlAppliedAtMs = DateTime.now().millisecondsSinceEpoch;
    // 请求可能仍在等待 ACK；pending 保护由调用方 finally 中的 _endPending 负责清理。
    // 快照在 ACK 前返回时仍应被 pendingNasMqttAction 拦住。
    final current = status;
    if (current == null) {
      _notifyIfAlive();
      return;
    }
    final wasFanOn = current.fan;
    if (fan) {
      if (!wasFanOn || _fanRunStartedAt == null) {
        _fanRunStartedAt = DateTime.now();
      }
    } else {
      _fanRunStartedAt = null;
    }
    status = current.copyWith(
      mode: mode,
      phase: phase,
      fan: fan,
      remainingMs: remainingMs ?? 0,
      durationMs: durationMs ?? 0,
      phaseDurationMs: durationMs ?? 0,
      // 停止/切换时不能回退到上一次采样的基础运行时长（否则会先闪 3 秒再归零）；
      // 设备确认停止后，运行时长直接归零，后续状态采样再校正。
      fanRunMs: 0,
    );
    // 乐观状态从收到 ACK 的这一刻开始插值，不能沿用上一次状态的时间戳。
    _nasStatusAt = DateTime.now();
    _notifyIfAlive();
  }

  Future<void> setAuto({bool replace = false}) async {
    if (nasMqttActive) {
      _beginPending('恢复自动感应');
      // 先落本地状态再发请求：两阶段往返要 1.2-1.9 秒，等回来再切 UI
      // 会让卡片迟滞一整秒。失败时用服务端快照校正。
      _applyWifiOptimistic(mode: 'auto', phase: 'armed', fan: false);
      try {
        await _nasMqttWrite('/api/auto',
            'profile=${profile.wireValue}&switchProfile=1&replace=${replace ? 1 : 0}');
      } catch (_) {
        unawaited(_refreshNasSnapshot().catchError((_) {}));
        rethrow;
      } finally {
        _endPending();
      }
      return;
    }
    final generation = _sessionGeneration;
    await _perform((_) => repository.setAuto(profile, replace: replace));
    await refresh(expectedGeneration: generation);
  }

  /// 执行不需要额外两步确认的控制意图，并返回类型化结果供界面呈现。
  Future<OperationResult> executeOperation(ControlOperation operation,
      {bool replace = false}) async {
    try {
      switch (operation) {
        case ControlOperation.automatic:
          await setAuto(replace: replace);
          break;
        case ControlOperation.exhaust:
          await exhaust(replace: replace);
          break;
        case ControlOperation.pause:
          await pause(replace: replace);
          break;
        case ControlOperation.forceExhaust:
          await forceTest(replace: replace);
          break;
        case ControlOperation.persistentOff:
          return OperationRejected(operation, '持续关闭需要二次确认');
      }
      return OperationSucceeded(operation);
    } on _ControlReplacementRequired {
      return OperationNeedsReplacement(operation);
    } catch (error) {
      return OperationRejected(operation, error.toString());
    }
  }

  Future<void> exhaust({bool replace = false}) async {
    if (nasMqttActive) {
      final duration = settings?.manualExhaustMs ?? 180000;
      _beginPending('启动临时排风');
      _applyWifiOptimistic(
          mode: 'timed_on',
          phase: 'exhausting',
          fan: true,
          remainingMs: duration,
          durationMs: duration);
      try {
        await _nasMqttWrite('/api/timed',
            'profile=${profile.wireValue}&mode=on&replace=${replace ? 1 : 0}');
      } catch (_) {
        unawaited(_refreshNasSnapshot().catchError((_) {}));
        rethrow;
      } finally {
        _endPending();
      }
      return;
    }
    await _perform((generation) async {
      await repository.startTimed(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  /// 乐观更新：点下控制按钮的瞬间就把本地状态切到目标模式，
  /// 让卡片立刻高亮，不必等 1-2 秒的 prepare/execute 两阶段往返。
  /// 请求失败时由调用方刷新校正；请求成功时服务端返回的真实值会覆盖它。
  void applyOptimisticMode(String mode, {int? remainingMs}) {
    final current = status;
    if (current == null) return;
    status = current.copyWith(
      mode: mode,
      phase: mode == 'auto'
          ? 'armed'
          : (current.phase == 'startup_cooldown' ? current.phase : 'running'),
      remainingMs: remainingMs ?? current.remainingMs,
      fanRunMs: mode == 'auto' ? 0 : current.fanRunMs,
      fan: mode != 'auto',
    );
    if (mode == 'auto') {
      _fanRunStartedAt = null;
    } else {
      _fanRunStartedAt ??= DateTime.now();
    }
    _notifyIfAlive();
  }

  Future<void> pause({bool replace = false}) async {
    if (nasMqttActive) {
      final duration = settings?.pauseMs ?? 600000;
      _beginPending('启动临时暂停');
      _applyWifiOptimistic(
          mode: 'timed_off',
          phase: 'armed',
          fan: false,
          remainingMs: duration,
          durationMs: duration);
      try {
        await _nasMqttWrite('/api/timed',
            'profile=${profile.wireValue}&mode=off&replace=${replace ? 1 : 0}');
      } catch (_) {
        unawaited(_refreshNasSnapshot().catchError((_) {}));
        rethrow;
      } finally {
        _endPending();
      }
      return;
    }
    await _perform((generation) async {
      await repository.startPause(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  Future<void> forceTest({bool replace = false}) async {
    if (nasMqttActive) {
      final duration = settings?.manualExhaustMs ?? 180000;
      _beginPending('启动强制排风');
      _applyWifiOptimistic(
          mode: 'force_test',
          phase: 'exhausting',
          fan: true,
          remainingMs: duration,
          durationMs: duration);
      try {
        await _nasMqttWrite('/api/test-fan',
            'profile=${profile.wireValue}&replace=${replace ? 1 : 0}');
      } catch (_) {
        unawaited(_refreshNasSnapshot().catchError((_) {}));
        rethrow;
      } finally {
        _endPending();
      }
      return;
    }
    await _perform((generation) async {
      await repository.startFanTest(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  /// 把持续关闭的 prepare/confirm 两条命令绑定在同一 BLE 会话中。
  Future<void> enableLockOff({bool replace = false}) async {
    if (nasMqttActive) {
      _beginPending('持续关闭');
      try {
        await _nasMqttWrite('/api/lockoff',
            'profile=${profile.wireValue}&stage=prepare&replace=${replace ? 1 : 0}');
        await _nasMqttWrite('/api/lockoff',
            'profile=${profile.wireValue}&stage=confirm&replace=${replace ? 1 : 0}');
        _applyWifiOptimistic(mode: 'lock_off', phase: 'armed', fan: false);
      } finally {
        _endPending();
      }
      return;
    }
    await _perform((generation) async {
      await repository.armLockOff(profile);
      if (!_isCurrentSession(generation, profile)) {
        throw StateError('蓝牙会话已变化，持续关闭未完成；请重新连接');
      }
      await repository.confirmLockOff(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  Future<void> cancelLockOff() async {
    if (_offlineViewing || !connected) {
      throw StateError('离线模式无法操作设备，请先连接蓝牙');
    }
    if (nasMqttActive) {
      await _nasMqttWrite('/api/lockoff',
          'profile=${profile.wireValue}&stage=cancel&replace=1');
      return;
    }
    await repository.cancelLockOff(profile);
  }

  /// 页面选择跟随设备当前环境，不向设备发送切换命令。
  Future<void> followDeviceProfile() async {
    if (_offlineViewing) return;
    final active = status?.activeProfile;
    if (active == null) return;
    final generation = _sessionGeneration;
    profile = active;
    await _persistSelectedProfile();
    if (!_isCurrentSession(generation, active)) return;
    await loadSettings(expectedGeneration: generation);
    await refresh(expectedGeneration: generation);
  }

  Future<void> _loadSelectedProfile() {
    if (_initialized || _disposed) return Future.value();
    return _preferencesLoading ??= _restoreAppPreferences().whenComplete(() {
      _preferencesLoading = null;
    });
  }

  Future<void> _restoreAppPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (_disposed) return;
    profile = preferences.getString(_profileKey) == 'dev'
        ? TimingProfile.dev
        : TimingProfile.production;
    _offlineViewing = preferences.getBool(_offlineViewingKey) ?? false;
    _initialized = true;
    _notifyIfAlive();
  }

  Future<void> _persistSelectedProfile() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_profileKey, profile.wireValue);
  }

  Future<void> updateSetting(String key, int value) async {
    if (_offlineViewing || !connected) return;
    final current = _settingsDraft;
    if (current == null) return;
    _settingsDraft = current.update(key, value);
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final draft = draftSettings;
    if (draft == null) throw StateError('时序配置尚未加载');
    if (!profileMatches) throw StateError('环境与设备不一致，请先切换到正确环境');
    if (nasMqttActive) {
      await _saveNasSettings(draft, '保存时间设置');
      return;
    }
    await _perform((generation) async {
      await repository.saveSettings(profile, draft);
      if (!_isCurrentSession(generation, profile)) {
        throw StateError('蓝牙会话已变化，配置保存结果未同步');
      }
      settings = draft;
      _settingsDraft = _settingsDraft?.markSaved(draft);
      await refresh(expectedGeneration: generation);
    });
  }

  Future<void> resetSettings() async {
    if (!profileMatches) throw StateError('环境与设备不一致，请先切换到正确环境');
    if (nasMqttActive) {
      // 与 SettingsStore.cpp 的 production/dev 默认时序保持一致。
      final defaults = profile == TimingProfile.dev
          ? const TimingSettings(
              startupCooldownMs: 5000,
              leaveConfirmMs: 0,
              autoExhaustMs: 10000,
              manualExhaustMs: 10000,
              pauseMs: 10000)
          : const TimingSettings(
              startupCooldownMs: 30000,
              leaveConfirmMs: 30000,
              autoExhaustMs: 120000,
              manualExhaustMs: 60000,
              pauseMs: 300000);
      await _saveNasSettings(defaults, '重置时间设置');
      return;
    }
    await _perform((generation) async {
      await repository.resetSettings(profile);
      await loadSettings(expectedGeneration: generation);
      await refresh(expectedGeneration: generation);
    });
  }

  void _guardNasConfiguration(TimingProfile selected, TimingSettings loaded) {
    _nasExpectedProfile = selected;
    _nasExpectedSettings = loaded;
    _nasConfigurationDeadline = DateTime.now().add(const Duration(seconds: 15));
  }

  Future<void> _saveNasSettings(TimingSettings value, String label) async {
    if (busy) throw StateError('操作正在执行，请稍后重试');
    busy = true;
    _beginPending(label);
    try {
      await _nasMqttWrite('/api/settings',
          'profile=${profile.wireValue}&${value.toFormBody()}');
      settings = value;
      _settingsDraft = SettingsDraft(saved: value, value: value);
      status = status?.copyWith(
          startupCooldownMs: value.startupCooldownMs,
          leaveConfirmMs: value.leaveConfirmMs,
          autoExhaustMs: value.autoExhaustMs,
          manualExhaustMs: value.manualExhaustMs,
          pauseMs: value.pauseMs);
      _guardNasConfiguration(profile, value);
    } finally {
      busy = false;
      _endPending();
    }
  }

  Future<void> _perform(Future<void> Function(int generation) action,
      {bool allowMismatch = false}) async {
    if (_disposed) throw StateError('控制器已关闭');
    if (_offlineViewing) throw StateError('离线模式无法操作设备，请先连接蓝牙');
    if (busy) throw StateError('操作正在执行，请稍后重试');
    if (!ble.isConnected) throw StateError('蓝牙未连接，请先连接设备');
    if (_statusInvalid) {
      throw StateError('设备状态数据无效，控制已暂停；请重新连接设备');
    }
    if (!allowMismatch && !profileMatches && status != null) {
      throw Exception('环境与设备不一致，请先切换到正确环境');
    }
    final generation = _sessionGeneration;
    busy = true;
    _notifyIfAlive();
    try {
      await action(generation);
      if (_disposed || generation != _sessionGeneration || !ble.isConnected) {
        throw StateError('蓝牙会话已变化，操作结果未同步；请重新读取设备状态');
      }
      lastError = null;
    } catch (error) {
      if (!_disposed && generation == _sessionGeneration) {
        lastError = error.toString();
      }
      rethrow;
    } finally {
      busy = false;
      _notifyIfAlive();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connectAttempt++;
    _sessionGeneration++;
    _pollTimer?.cancel();
    _nasSyncTimer?.cancel();
    _nasGatewayTransport.dispose();
    ble.removeListener(_onBleChanged);
    unawaited(closeBluetoothSession());
    ble.dispose();
    super.dispose();
  }
}

class _ControlReplacementRequired implements Exception {
  const _ControlReplacementRequired();
}

class _ObsoleteStatisticsQuery extends StateError {
  _ObsoleteStatisticsQuery() : super('统计页面已切换，已取消尚未发送的查询');
}
