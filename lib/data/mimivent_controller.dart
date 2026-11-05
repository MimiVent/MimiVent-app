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
import '../features/wifi_control/wifi_binding.dart';
import '../features/wifi_control/wifi_read_transport.dart';
import '../features/wifi_control/wifi_serial_executor.dart';
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
      this.diagnostics})
      : ble = bleManager ?? MimiVentBleManager(diagnostics: diagnostics) {
    // 默认 Repository 与扫描/连接共用同一个 BLE 实例；测试可注入替身。
    repository = deviceRepository ??
        BleDeviceRepository(MimiVentApi(ble, diagnostics: diagnostics));
    ble.addListener(_onBleChanged);
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (wifiActive && (status?.fan == true || displayRemainingMs > 0)) {
        _notifyIfAlive();
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

  /// 两次 WiFi 状态采样之间本地插值，让运行时间每秒推进。
  int get displayFanRunMs {
    final current = status;
    if (current == null) return 0;
    if (!wifiActive || !current.fan) return current.fanRunMs;
    final started = _fanRunStartedAt;
    if (started == null) return current.fanRunMs;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    return elapsed > 0 ? elapsed : 0;
  }

  /// 两次 WiFi 状态采样之间本地推进倒计时，避免倒计时每 3–6 秒才跳一次。
  int get displayRemainingMs {
    final current = status;
    if (current == null) return 0;
    final remaining = current.remainingMs;
    if (!wifiActive || _wifiStatusAt == null || remaining <= 0)
      return remaining;
    final elapsed = DateTime.now().difference(_wifiStatusAt!).inMilliseconds;
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
  final Set<String> _statisticsRangeRequests = {};
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
  Future<void>? _closingBluetoothSession;
  String? _appVersionCache;
  static const _profileKey = 'mimivent.selected_profile';
  static const _offlineViewingKey = 'mimivent.offline_viewing';
  static const _statisticsCacheKeyPrefix = 'mimivent.statistics.cache.';
  String? lastError;
  WifiBinding? _wifiBinding;
  WifiReadTransport? _wifiTransport;
  bool _wifiVersionCompatible = true;
  final _wifiExecutor = WifiSerialExecutor();
  Timer? _wifiHealthTimer;
  Timer? _wifiSyncTimer;
  bool _wifiHealthInFlight = false;
  bool wifiLost = false;
  bool wifiBusy = false;
  String? pendingWifiAction;
  int _wifiHealthFailures = 0;
  bool _wifiStatsSerialized = false;
  int _wifiSyncFailures = 0;
  bool _appForeground = true;
  DateTime? _wifiStatusAt;
  DateTime? _fanRunStartedAt;

  bool get wifiActive => _wifiBinding != null;

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
    final identity = wifiActive
        ? 'wifi:${_wifiBinding!.deviceId}'
        : ble.connectedDeviceId == null ? null : 'ble:${ble.connectedDeviceId}';
    if (identity != null) _lastRangeScope = identity;
    return _lastRangeScope;
  }

  String _rangeKey(StatisticsQuery query) =>
      '$_rangeScope|${_rangeEpochByScope[_rangeScope] ?? ''}|2|${query.cacheKey}';

  Map<String, dynamic>? statisticsRangeFor(StatisticsQuery query) =>
      _statisticsRangeByKey[_rangeKey(query)];

  bool get connected => ble.isConnected || wifiActive;
  bool get _connectionBootstrapInProgress =>
      _connectionBootstrapAttempt != null;
  bool get deviceOtaBusy => ble.deviceOtaBusy;
  bool get appVersionCompatible =>
      wifiActive ? _wifiVersionCompatible : ble.appVersionCompatible;

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
    if (ble.isConnected) {
      _bleConnectedSince ??= DateTime.now();
    } else {
      _bleConnectedSince = null;
    }
    if (!ble.isConnected) {
      if (ble.lastError == '蓝牙连接已断开') {
        lastError = ble.lastError;
      }
      // 让断开前正在进行的状态读取失效，避免异步结果重新写入旧会话。
      _sessionGeneration++;
      status = null;
      wifiGattCacheStale = false;
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
      _statusInvalid = false;
      settings = null;
      _settingsDraft = null;
    }
    _notifyIfAlive();
  }

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  Future<void> scan() => ble.scan();

  /// 恢复用户上次选择的页面环境，再开始扫描，避免重开 App 时错用正式环境。
  Future<void> openApp() async {
    await _loadSelectedProfile();
    await _ensureStatisticsCache();
    if (_disposed || _offlineViewing) return;
    if (!ble.isConnected && !ble.isScanning) await scan();
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
        if (error is DeviceBusyException) {
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
      (ble.isConnected || wifiActive) &&
      generation == _sessionGeneration &&
      profile == this.profile;

  Future<T> _wifiSerial<T>(Future<T> Function() action,
      {bool priority = false}) => _wifiExecutor.run(action, priority: priority);

  Future<void> activateWifi(WifiBinding binding) async {
    _wifiBinding = binding;
    _wifiTransport = WifiReadTransport();
    wifiLost = false;
    wifiBusy = false;
    _wifiSyncFailures = 0;
    try {
      await _wifiSerial(_refreshWifi, priority: true);
      // WiFi 已成为控制通道时主动断开 BLE，释放设备广播/连接槽，避免第二台手机连不上。
      if (ble.isConnected) {
        await ble.disconnect();
      }
      _startWifiHealth();
      _startWifiSync();
      // WiFi 会话已建立：清掉上一次（可能是蓝牙）连接失败残留的错误，
      // 否则顶部会一直挂着"设备操作失败"，与实际状态不符。
      if (lastError != null) {
        lastError = null;
        _notifyIfAlive();
      }
    } catch (error) {
      _wifiBinding = null;
      _wifiTransport = null;
      if (error is WifiReadException && error.code == 'WIFI_IN_USE') {
        wifiBusy = true;
      }
      lastError = error is WifiReadException ? error.message : error.toString();
      _notifyIfAlive();
      rethrow;
    }
  }

  Future<void> releaseWifiLease() async {
    final binding = _wifiBinding;
    final transport = _wifiTransport;
    if (binding == null || transport == null || !wifiActive) return;
    try {
      await transport.releaseLease(binding).timeout(const Duration(seconds: 2));
      diagnostics?.info('WiFi 租约', '已释放 WiFi 主控');
    } catch (error) {
      diagnostics?.warning('WiFi 租约', '释放失败，等待租约过期：$error');
    }
  }

  void deactivateWifi() {
    _wifiHealthTimer?.cancel();
    _wifiHealthTimer = null;
    _wifiSyncTimer?.cancel();
    _wifiSyncTimer = null;
    _wifiBinding = null;
    _wifiTransport = null;
    _wifiStatusAt = null;
    _fanRunStartedAt = null;
    wifiLost = false;
    wifiBusy = false;
    _wifiSyncFailures = 0;
    _notifyIfAlive();
  }

  void _startWifiHealth() {
    // 用户优先：不再后台轮询，避免健康检查占用单 HTTPS 连接阻塞控制。
    // 断线由写操作/手动刷新/启动探测发现，或回到前台时重新探测。
    _wifiHealthTimer?.cancel();
    _wifiHealthTimer = null;
    _wifiHealthFailures = 0;
  }

  void _startWifiSync() {
    _wifiSyncTimer?.cancel();
    _scheduleWifiSync();
  }

  void setAppForeground(bool value) {
    if (_appForeground == value) return;
    _appForeground = value;
    if (wifiActive) _startWifiSync();
  }

  void _scheduleWifiSync() {
    final delay = _appForeground
        ? 3000 + Random().nextInt(2000)
        : 8000 + Random().nextInt(4000);
    _wifiSyncTimer = Timer(Duration(milliseconds: delay), () {
      if (!wifiActive || _disposed) return;
      if (pendingWifiAction == null) {
        unawaited(_wifiSerial(_refreshWifi).then((_) {
          _wifiSyncFailures = 0;
        }).catchError((Object error) {
          if (error is WifiReadException && error.code == 'WIFI_IN_USE') {
            _handleWifiBusy(error);
            return;
          }
          _wifiSyncFailures++;
          diagnostics?.warning('WiFi 同步', '状态同步失败：$error');
          if (_wifiSyncFailures >= 2) _handleWifiLost(error);
        }));
      }
      if (wifiActive) _scheduleWifiSync();
    });
  }

  void _scheduleWifiHealth() {
    // 多手机场景加抖动，避免两台手机在同一秒同时重试造成单连接互踢。
    final jitter = 12000 + Random().nextInt(6000);
    _wifiHealthTimer = Timer(Duration(milliseconds: jitter), () {
      if (!wifiActive || _disposed) return;
      if (_wifiHealthInFlight) {
        _scheduleWifiHealth();
        return;
      }
      _wifiHealthInFlight = true;
      unawaited(
          _wifiSerial(_refreshWifi, priority: true).catchError((Object error) {
        _wifiHealthFailures++;
        if (_wifiHealthFailures >= 2) {
          _handleWifiLost(error);
        } else {
          diagnostics?.warning('WiFi 连接', '健康检查失败，等待下次重试：$error');
        }
      }).whenComplete(() {
        _wifiHealthInFlight = false;
        if (wifiActive) _scheduleWifiHealth();
      }));
    });
  }

  void _handleWifiLost(Object error) {
    if (!wifiActive) return;
    wifiLost = true;
    lastError = 'WiFi 连接已断开';
    _wifiHealthTimer?.cancel();
    _wifiHealthTimer = null;
    _wifiSyncTimer?.cancel();
    _wifiSyncTimer = null;
    _wifiBinding = null;
    _wifiTransport = null;
    _wifiStatusAt = null;
    _fanRunStartedAt = null;
    status = null;
    settings = null;
    _settingsDraft = null;
    diagnostics?.warning('WiFi 连接', '状态同步失败：$error');
    _notifyIfAlive();
  }

  void _handleWifiBusy(Object error) {
    if (!wifiActive) return;
    wifiBusy = true;
    lastError = 'WiFi 正被另一台手机控制';
    _wifiHealthTimer?.cancel();
    _wifiHealthTimer = null;
    _wifiSyncTimer?.cancel();
    _wifiSyncTimer = null;
    _wifiBinding = null;
    _wifiTransport = null;
    _wifiStatusAt = null;
    _fanRunStartedAt = null;
    status = null;
    settings = null;
    _settingsDraft = null;
    diagnostics?.warning('WiFi 租约', 'WiFi 已被其他手机占用：$error');
    _notifyIfAlive();
  }

  Future<void> _refreshWifi() async {
    final binding = _wifiBinding;
    final transport = _wifiTransport;
    if (binding == null || transport == null) return;
    Map<String, dynamic> data;
    for (var attempt = 0;; attempt++) {
      try {
        data = await transport.read(binding);
        break;
      } catch (error) {
        if (attempt == 0 && _wifiTransient(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        rethrow;
      }
    }
    if (pendingWifiAction != null) return;
    final loaded = DeviceStatus.fromJson(data);
    final loadedSettings = TimingSettings.fromJson(data);
    final wasFanOn = status?.fan == true;
    status = loaded;
    _wifiStatusAt = DateTime.now();
    if (loaded.fan) {
      if (!wasFanOn || _fanRunStartedAt == null) {
        _fanRunStartedAt =
            DateTime.now().subtract(Duration(milliseconds: loaded.fanRunMs));
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
    _wifiVersionCompatible = true;
    _wifiHealthFailures = 0;
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

  bool _wifiTransient(Object error) {
    if (error is TimeoutException || error is SocketException) return true;
    if (error is WifiReadException) {
      return const {
        'HTTP_INCOMPLETE',
        'HTTP_FORMAT',
        'RESOURCE_BUSY',
        'RATE_LIMITED',
      }.contains(error.code);
    }
    return false;
  }

  /// 所有 WiFi 读取串行化：一次 TLS 会话在设备上约占 18 KB 堆，
  /// 并发读取会让设备在握手阶段内存不足而断链。
  Future<Map<String, dynamic>> _wifiReadPath(String path,
      {bool priority = false}) {
    return _wifiSerial(() => _wifiReadPathUnlocked(path), priority: priority);
  }

  Future<Map<String, dynamic>> _wifiReadPathUnlocked(String path) async {
    final binding = _wifiBinding;
    final transport = _wifiTransport;
    if (binding == null || transport == null) {
      throw StateError('WiFi 控制通道不可用');
    }
    for (var attempt = 0;; attempt++) {
      try {
        return await transport.readPath(binding, path);
      } catch (error) {
        if (attempt == 0 && _wifiTransient(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _wifiWrite(String path, String body) =>
      _wifiSerial(() => _wifiWriteUnlocked(path, body), priority: true);

  Future<void> _wifiWriteUnlocked(String path, String body) async {
    // WiFi 控制期间释放 BLE 连接，避免占用设备唯一的 BLE 槽导致第二台手机无法连接。
    if (ble.isConnected) {
      await ble.disconnect();
    }
    final binding = _wifiBinding;
    final transport = _wifiTransport;
    if (binding == null || transport == null) {
      throw StateError('WiFi 控制通道不可用');
    }
    final requestId = _requestId();
    WifiHttpResult result;
    for (var attempt = 0;; attempt++) {
      try {
        result = await transport.write(binding,
            path: path, body: body, requestId: requestId);
        break;
      } catch (error) {
        if (attempt == 0 && _wifiTransient(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        if (error is WifiReadException && error.code == 'WIFI_IN_USE') {
          _handleWifiBusy(error);
          rethrow;
        }
        throw StateError('WiFi 写请求失败：$error');
      }
    }
    if (result.statusCode != 200) {
      final code =
          result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
      diagnostics?.warning(
          'WiFi 控制拒绝', 'POST $path HTTP ${result.statusCode} $code');
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
      throw StateError('设备未完成 WiFi 控制（$code）');
    }
    // 写请求成功后立即返回，状态刷新排队在后台完成，避免控制按钮等待两次 TLS。
    unawaited(
        _wifiSerial(_refreshWifi, priority: true).catchError((Object error) {
      diagnostics?.warning('WiFi 状态', '写后刷新失败：$error');
    }));
  }

  Future<void> refresh({int? expectedGeneration}) async {
    if (wifiActive) {
      await _wifiSerial(_refreshWifi, priority: true);
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
  Future<void> refreshStatisticsRange(StatisticsQuery query) async {
    if (!query.valid) return;
    if (_offlineViewing || (!ble.isConnected && !wifiActive)) return;
    if (!supportsStatisticsRange) return;
    final scope = _rangeScope;
    final epochAtStart = _rangeEpochByScope[scope];
    final key = _rangeKey(query);
    if (!_statisticsRangeRequests.add(key)) return;
    final generation = _sessionGeneration;
    final selectedProfile = profile;
    _notifyIfAlive();
    try {
      final Map<String, dynamic> loaded;
      if (wifiActive) {
        // 主数据插队：切 Tab 时图表/汇总要最先出来，事件明细可以稍后。
        loaded = await _wifiReadPath(
          '/api/stats/range?from=${query.from}&to=${query.to}'
          '&tzOffsetSeconds=${query.tzOffsetSeconds}',
          priority: true,
        );
      } else {
        loaded = await repository.getStatisticsRange(
          selectedProfile,
          from: query.from,
          to: query.to,
          tzOffsetSeconds: query.tzOffsetSeconds,
        );
      }
      if (generation != _sessionGeneration || scope != _rangeScope ||
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
      if (epoch != null && epoch.isNotEmpty) {
        _rangeEpochByScope[scope] = epoch;
        final stale = _statisticsRangeByKey.entries
            .where((entry) => (entry.key.startsWith('$scope|') ||
                    (device != null && entry.value['deviceId']?.toString() == device)) &&
                entry.value['dataEpoch']?.toString() != epoch)
            .map((entry) => entry.key)
            .toList();
        for (final staleKey in stale) {
          _rangeEpochByScope[staleKey.split('|').first] = epoch;
          _statisticsRangeByKey.remove(staleKey);
        }
      }
      _statisticsRangeByKey[_rangeKey(query)] = loaded;
    } catch (error) {
      diagnostics?.error('统计范围', '查询失败：$error');
    } finally {
      _statisticsRangeRequests.remove(key);
      _notifyIfAlive();
    }
  }

  /// 范围视图的事件明细：新接口不返回事件，单独拉一页并合并进范围缓存。
  ///
  /// 只用于单日范围；多日范围按文档不提供明细。
  Future<void> refreshRangeEventPage(StatisticsQuery query,
      {int? beforeId, int? windowStart, int? windowEnd}) async {
    if (_offlineViewing || (!ble.isConnected && !wifiActive)) return;
    if (!supportsStatisticsRange) return;
    // 多日范围默认不按整段拉（32 条一页远远不够）；
    // 点某根柱时会用 windowStart/windowEnd 只取那一段。
    if (!query.singleDay && windowStart == null) return;
    final queryFrom = windowStart ?? query.from;
    final queryTo = windowEnd ?? query.to;
    final key = _rangeKey(query);
    final cached = _statisticsRangeByKey[key];
    if (cached == null) return;
    final generation = _sessionGeneration;
    try {
      final Map<String, dynamic> page;
      if (wifiActive) {
        final cursor = beforeId == null ? '' : '&beforeId=$beforeId';
        page = await _wifiReadPath(
          '/api/events?start=$queryFrom&end=$queryTo'
          '&kind=all&limit=32$cursor',
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
      if (generation != _sessionGeneration || key != _rangeKey(query) ||
          !identical(cached, _statisticsRangeByKey[key])) {
        return;
      }
      // 按柱窗口取到的事件单独存：整范围刷新会重写 'events'，
      // 混在一起会导致用户点开的详情在每分钟刷新时被冲掉。
      final slot = windowStart == null ? 'events' : 'intervalEvents';
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
      _notifyIfAlive();
    } catch (error) {
      diagnostics?.error('统计范围', '事件明细查询失败：$error');
    }
  }

  /// 切换数据批次或断开连接时作废范围缓存。
  void clearStatisticsRangeCache() {
    if (_statisticsRangeByKey.isEmpty && _statisticsRangeRequests.isEmpty) return;
    _statisticsRangeByKey.clear();
    _rangeEpochByScope.clear();
    _statisticsRangeRequests.clear();
    _notifyIfAlive();
  }

  Future<void> refreshStatistics(String range,
      {int? expectedGeneration,
      int eventOffset = 0,
      int? eventBeforeId}) async {
    if (_offlineViewing || (!ble.isConnected && !wifiActive)) return;
    if (wifiActive && !_wifiStatsSerialized) {
      await _wifiSerial(() async {
        _wifiStatsSerialized = true;
        try {
          await refreshStatistics(range,
              expectedGeneration: expectedGeneration,
              eventOffset: eventOffset,
              eventBeforeId: eventBeforeId);
        } finally {
          _wifiStatsSerialized = false;
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
      if (wifiActive) {
        if (eventOffset == 0 && eventBeforeId == null) {
          loaded = await _wifiReadPath('/api/stats?mode=$range');
          _validateStatisticsSnapshot(range, loaded);
        } else {
          final previous = _statisticsByRange[range];
          final start = _intValue(previous?['eventsStart']);
          final end = _intValue(previous?['eventsEnd']);
          final epoch = previous?['eventsDataEpoch']?.toString();
          if (start <= 0 || end <= start) return;
          final cursor =
              eventBeforeId == null ? '' : '&beforeId=$eventBeforeId';
          final query = 'start=$start&end=$end&offset=$eventOffset&limit=32'
              '&kind=all$cursor${epoch == null ? '' : '&dataEpoch=${Uri.encodeQueryComponent(epoch)}'}';
          final page = await _wifiReadPath('/api/events?$query');
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
          (!ble.isConnected && !wifiActive) ||
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
        (ble.isConnected || wifiActive)) {
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
    if (wifiActive) {
      await _wifiSerial(() async {
        final binding = _wifiBinding!;
        final data = await _wifiTransport!
            .readPath(binding, '/api/settings?profile=${profile.wireValue}');
        final loaded = TimingSettings.fromJson(data);
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

  Future<void> switchProfile(TimingProfile next) async {
    if (next == profile) return;
    if (busy) throw StateError('操作正在执行，请稍后重试');
    if (wifiActive) {
      _beginPending('切换环境');
      try {
        await _wifiWrite(
            '/api/auto', 'profile=${next.wireValue}&switchProfile=1&replace=1');
        profile = next;
        await _persistSelectedProfile();
        await _refreshWifi();
      } finally {
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
    pendingWifiAction = label;
    _notifyIfAlive();
  }

  void _endPending() {
    if (pendingWifiAction == null) return;
    pendingWifiAction = null;
    _notifyIfAlive();
  }

  void _applyWifiOptimistic({
    required String mode,
    required String phase,
    required bool fan,
    int? remainingMs,
    int? durationMs,
  }) {
    // 控制已经在设备上成功；先撤掉 pending 遮罩，再同时更新状态，
    // 避免遮罩仍显示“正在排风”时底层计时器已经跑起来。
    pendingWifiAction = null;
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
    _wifiStatusAt = DateTime.now();
    _notifyIfAlive();
  }

  Future<void> setAuto({bool replace = false}) async {
    if (wifiActive) {
      _beginPending('恢复自动感应');
      try {
        await _wifiWrite('/api/auto',
            'profile=${profile.wireValue}&switchProfile=1&replace=${replace ? 1 : 0}');
        _applyWifiOptimistic(mode: 'auto', phase: 'armed', fan: false);
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
    } catch (error) {
      return OperationRejected(operation, error.toString());
    }
  }

  Future<void> exhaust({bool replace = false}) async {
    if (wifiActive) {
      final duration = settings?.manualExhaustMs ?? 180000;
      _beginPending('启动临时排风');
      try {
        await _wifiWrite('/api/timed',
            'profile=${profile.wireValue}&mode=on&replace=${replace ? 1 : 0}');
        _applyWifiOptimistic(
            mode: 'timed_on',
            phase: 'exhausting',
            fan: true,
            remainingMs: duration,
            durationMs: duration);
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

  Future<void> pause({bool replace = false}) async {
    if (wifiActive) {
      final duration = settings?.pauseMs ?? 600000;
      _beginPending('启动临时暂停');
      try {
        await _wifiWrite('/api/timed',
            'profile=${profile.wireValue}&mode=off&replace=${replace ? 1 : 0}');
        _applyWifiOptimistic(
            mode: 'timed_off',
            phase: 'armed',
            fan: false,
            remainingMs: duration,
            durationMs: duration);
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
    if (wifiActive) {
      final duration = settings?.manualExhaustMs ?? 180000;
      _beginPending('启动强制排风');
      try {
        await _wifiWrite('/api/test-fan',
            'profile=${profile.wireValue}&replace=${replace ? 1 : 0}');
        _applyWifiOptimistic(
            mode: 'force_test',
            phase: 'exhausting',
            fan: true,
            remainingMs: duration,
            durationMs: duration);
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
    if (wifiActive) {
      _beginPending('持续关闭');
      try {
        await _wifiWrite('/api/lockoff',
            'profile=${profile.wireValue}&stage=prepare&replace=${replace ? 1 : 0}');
        await _wifiWrite('/api/lockoff',
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
    if (wifiActive) {
      await _wifiWrite('/api/lockoff',
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
    if (wifiActive) {
      await _wifiWrite('/api/settings',
          'profile=${profile.wireValue}&${draft.toFormBody()}');
      settings = draft;
      _settingsDraft = _settingsDraft?.markSaved(draft);
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
    await _perform((generation) async {
      await repository.resetSettings(profile);
      await loadSettings(expectedGeneration: generation);
      await refresh(expectedGeneration: generation);
    });
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
    _wifiHealthTimer?.cancel();
    ble.removeListener(_onBleChanged);
    unawaited(closeBluetoothSession());
    ble.dispose();
    super.dispose();
  }
}

