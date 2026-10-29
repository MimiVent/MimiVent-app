import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/mimivent_api.dart';
import '../ble/mimivent_ble_manager.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../features/control/control_operation.dart';
import 'ble_device_repository.dart';
import 'device_repository.dart';
import 'settings_draft.dart';
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
      if (ble.isConnected &&
          !_offlineViewing &&
          !ble.isOtaUploading &&
          !ble.isOtaVerifying &&
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
  Map<String, dynamic>? statistics;
  final Map<String, Map<String, dynamic>> _statisticsByRange = {};
  final Set<String> _statisticsLoadingRanges = {};
  final Set<String> _statisticsFailedRanges = {};
  final Set<String> _statisticsRequests = {};
  final Set<String> _statisticsCachedRanges = {};
  final Map<String, DateTime> _statisticsCacheUpdatedAt = {};
  TimingSettings? settings;
  SettingsDraft? _settingsDraft;
  TimingSettings? get draftSettings => _settingsDraft?.value;
  TimingProfile profile = TimingProfile.production;
  Timer? _pollTimer;
  bool busy = false;
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
  Future<void>? _closingBluetoothSession;
  String? _appVersionCache;
  static const _profileKey = 'mimivent.selected_profile';
  static const _offlineViewingKey = 'mimivent.offline_viewing';
  static const _statisticsCacheKeyPrefix = 'mimivent.statistics.cache.';
  String? lastError;

  bool get connected => ble.isConnected;
  bool get deviceOtaBusy => ble.deviceOtaBusy;
  bool get appVersionCompatible => ble.appVersionCompatible;

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

  void _onBleChanged() {
    if (_disposed) return;
    if (!ble.isConnected) {
      if (ble.lastError == '蓝牙连接已断开') {
        lastError = ble.lastError;
      }
      // 让断开前正在进行的状态读取失效，避免异步结果重新写入旧会话。
      _sessionGeneration++;
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
    lastError = null;
    _notifyIfAlive();
    int? sessionGeneration;
    try {
      await ble.connect(device);
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
      _statusInvalid = false;
      settings = loadedSettings;
      _settingsDraft =
          SettingsDraft(saved: loadedSettings, value: loadedSettings);
      _offlineViewing = false;
      unawaited(_persistOfflineViewing());
      lastError = null;
      _notifyIfAlive();
    } catch (error) {
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
        _notifyIfAlive();
      }
      rethrow;
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
      ble.isConnected &&
      generation == _sessionGeneration &&
      profile == this.profile;

  Future<void> refresh({int? expectedGeneration}) async {
    if (_offlineViewing ||
        !ble.isConnected ||
        ble.isOtaUploading ||
        ble.isOtaVerifying ||
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

  Future<void> refreshStatistics(String range,
      {int? expectedGeneration,
      int eventOffset = 0,
      int? eventBeforeId}) async {
    if (_offlineViewing || !ble.isConnected) return;
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
      if (eventOffset == 0 && eventBeforeId == null) {
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
          !ble.isConnected ||
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
    if (restartAfterDatasetChange && !_disposed && ble.isConnected) {
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

  Future<void> setAuto({bool replace = false}) async {
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
    await _perform((generation) async {
      await repository.startTimed(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  Future<void> pause({bool replace = false}) async {
    await _perform((generation) async {
      await repository.startPause(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  Future<void> forceTest({bool replace = false}) async {
    await _perform((generation) async {
      await repository.startFanTest(profile, replace: replace);
      await refresh(expectedGeneration: generation);
    });
  }

  /// 把持续关闭的 prepare/confirm 两条命令绑定在同一 BLE 会话中。
  Future<void> enableLockOff({bool replace = false}) async {
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
    ble.removeListener(_onBleChanged);
    unawaited(closeBluetoothSession());
    ble.dispose();
    super.dispose();
  }
}
