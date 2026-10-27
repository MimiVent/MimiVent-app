import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/mimivent_api.dart';
import '../ble/mimivent_ble_manager.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../features/control/control_operation.dart';
import 'ble_device_repository.dart';
import 'device_repository.dart';
import 'settings_draft.dart';
import 'models.dart';

class MimiVentController extends ChangeNotifier {
  MimiVentController(
      {MimiVentBleManager? bleManager,
      DeviceRepository? deviceRepository,
      this.diagnostics})
      : ble = bleManager ?? MimiVentBleManager(diagnostics: diagnostics) {
    // 默认 Repository 与扫描/连接共用同一个 BLE 实例；测试可注入替身。
    repository = deviceRepository ??
        BleDeviceRepository(MimiVentApi(ble, diagnostics: diagnostics));
    ble.addListener(_onBleChanged);
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ble.isConnected && !busy && !_polling) refresh();
    });
  }

  final MimiVentBleManager ble;
  final AppDiagnosticsLog? diagnostics;
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
  bool _disposed = false;
  int _sessionGeneration = 0;
  int _connectAttempt = 0;
  Future<void>? _closingBluetoothSession;
  static const _profileKey = 'mimivent.selected_profile';
  static const _statisticsCacheKeyPrefix = 'mimivent.statistics.cache.';
  String? lastError;

  bool get connected => ble.isConnected;
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

  Future<void> loadMoreStatisticsEvents(String range) async {
    if (!statisticsHasMoreEventsFor(range)) return;
    await refreshStatistics(range,
        eventOffset: statisticsNextEventOffsetFor(range));
  }

  /// 通用原始事件查询入口；页面可传入自然日、自定义时间段和事件筛选条件。
  Future<DeviceEventPage> queryDeviceEvents(DeviceEventQuery query) async {
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
    if (!_initialized) {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      profile = preferences.getString(_profileKey) == 'dev'
          ? TimingProfile.dev
          : TimingProfile.production;
      _initialized = true;
      _notifyIfAlive();
    }
    if (!_statisticsCacheLoaded) await _restoreStatisticsCache();
    if (!ble.isConnected && !ble.isScanning) await scan();
  }

  /// 从本地恢复各时间范围最近一次成功的统计，供首屏先显示缓存再做 BLE 刷新。
  Future<void> _restoreStatisticsCache() async {
    _statisticsCacheLoaded = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      for (final range in const [
        'today',
        'yesterday',
        'threeDays',
        'sevenDays'
      ]) {
        if (_statisticsByRange.containsKey(range)) continue;
        final raw = preferences.getString('$_statisticsCacheKeyPrefix$range');
        if (raw == null) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final payload = decoded['data'];
        if (payload is! Map) continue;
        final data = Map<String, dynamic>.from(payload);
        final updatedAtMs = decoded['updatedAt'];
        if (updatedAtMs is int && updatedAtMs > 0) {
          final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
          data['_cacheUpdatedAt'] = updatedAtMs;
          _statisticsCacheUpdatedAt[range] = updatedAt;
        }
        _statisticsByRange[range] = data;
        _statisticsCachedRanges.add(range);
      }
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
          'data': data,
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
      try {
        await repository.syncClock(selectedProfile);
      } catch (error) {
        diagnostics?.warning('设备时间', '手机时间同步失败，统计日期暂不可用：$error');
      }
      if (!_isCurrentSession(generation, selectedProfile) ||
          attempt != _connectAttempt) return;
      // 状态先确认设备真实环境，再读取对应页面环境的时序，避免并发读取错配。
      final loadedStatus = await repository.getStatus(selectedProfile);
      if (!_isCurrentSession(generation, selectedProfile) ||
          attempt != _connectAttempt) {
        return;
      }
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
        if (error is FormatException) _statusInvalid = true;
        lastError = error.toString();
        _notifyIfAlive();
      }
      rethrow;
    }
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
    if (!ble.isConnected || _polling) return;
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
      status = loaded;
      _statusInvalid = false;
      lastError = null;
    } catch (error) {
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
      {int? expectedGeneration, int eventOffset = 0}) async {
    if (!ble.isConnected) return;
    final generation = expectedGeneration ?? _sessionGeneration;
    if (generation != _sessionGeneration) return;
    if (!_statisticsRequests.add(range)) return;
    final selectedProfile = profile;
    _statisticsLoadingRanges.add(range);
    _statisticsFailedRanges.remove(range);
    _notifyIfAlive();
    try {
      final Map<String, dynamic> loaded;
      if (eventOffset == 0) {
        loaded = await repository.getStatistics(selectedProfile, range);
      } else {
        // 统计汇总只在首屏读取；继续翻页时走通用原始事件接口，减少 BLE 传输。
        final page = await repository.queryEvents(
          selectedProfile,
          _eventQueryForRange(range, offset: eventOffset),
        );
        loaded = {
          'events': page.events.map((event) => event.toJson()).toList(),
          'eventsOffset': page.offset,
          'eventsNextOffset': page.nextOffset,
          'eventsTotal': page.total,
          'eventsHasMore': page.hasMore,
        };
      }
      if (_disposed ||
          !ble.isConnected ||
          generation != _sessionGeneration ||
          selectedProfile != profile) return;
      final previous = _statisticsByRange[range];
      final merged = _mergeStatisticsPage(previous, loaded, eventOffset);
      statistics = merged;
      _statisticsByRange[range] = merged;
      _statisticsCachedRanges.remove(range);
      merged.remove('_cacheUpdatedAt');
      _statisticsCacheUpdatedAt[range] = DateTime.now();
      unawaited(_persistStatisticsCache(range, merged));
      lastError = null;
    } catch (error) {
      if (!_disposed && generation == _sessionGeneration) {
        _statisticsFailedRanges.add(range);
        diagnostics?.warning('设备统计', '读取统计失败：$error');
      }
    } finally {
      _statisticsRequests.remove(range);
      _statisticsLoadingRanges.remove(range);
      _notifyIfAlive();
    }
  }

  /// 固件按新到旧返回原始事件。分页时拼接原始记录，刷新首屏时保留已加载的旧页。
  /// 分组展示留给 App UI，这里不改变固件事件的语义或顺序。
  Map<String, dynamic> _mergeStatisticsPage(
    Map<String, dynamic>? previous,
    Map<String, dynamic> page,
    int offset,
  ) {
    final next = Map<String, dynamic>.from(page);
    final freshEvents = _rawEventList(page['events']);
    final oldEvents = _rawEventList(previous?['events']);
    List<Map<String, dynamic>> mergedEvents;

    if (offset > 0 && previous != null) {
      mergedEvents = [...oldEvents, ...freshEvents];
    } else if (oldEvents.isEmpty) {
      mergedEvents = freshEvents;
    } else {
      // 找到新首屏与旧列表的重叠点，避免每分钟刷新时重复显示已有原始事件。
      final oldFirstKey = _eventKey(oldEvents.first);
      final overlapIndex =
          freshEvents.indexWhere((event) => _eventKey(event) == oldFirstKey);
      mergedEvents = overlapIndex >= 0
          ? [...freshEvents, ...oldEvents.skip(1)]
          : [...freshEvents, ...oldEvents];
    }

    final totalValue = page['eventsTotal'];
    final total = totalValue is num ? totalValue.toInt() : mergedEvents.length;
    final hasMore =
        mergedEvents.length < total && page['eventsHasMore'] == true;
    next['events'] = mergedEvents;
    next['eventsOffset'] = 0;
    next['eventsNextOffset'] = mergedEvents.length;
    next['eventsTotal'] = total;
    next['eventsHasMore'] = hasMore;
    return next;
  }

  List<Map<String, dynamic>> _rawEventList(Object? value) => value is List
      ? value
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList()
      : <Map<String, dynamic>>[];

  String _eventKey(Map<String, dynamic> event) =>
      '${event['time']}|${event['kind']}|${event['state']}|${event['durationSeconds']}';

  DeviceEventQuery _eventQueryForRange(String range, {required int offset}) {
    final now = DateTime.now();
    if (range == 'today') {
      return DeviceEventQuery(
        start: now.subtract(const Duration(hours: 24)),
        end: now,
        offset: offset,
      );
    }
    if (range == 'yesterday') {
      return DeviceEventQuery.forLocalDay(
        now.subtract(const Duration(days: 1)),
        offset: offset,
      );
    }
    throw ArgumentError.value(range, 'range', '该区间不展示原始事件列表');
  }

  Future<void> loadSettings({int? expectedGeneration}) async {
    if (!ble.isConnected) return;
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

  Future<void> cancelLockOff() => repository.cancelLockOff(profile);

  /// 页面选择跟随设备当前环境，不向设备发送切换命令。
  Future<void> followDeviceProfile() async {
    final active = status?.activeProfile;
    if (active == null) return;
    final generation = _sessionGeneration;
    profile = active;
    await _persistSelectedProfile();
    if (!_isCurrentSession(generation, active)) return;
    await loadSettings(expectedGeneration: generation);
    await refresh(expectedGeneration: generation);
  }

  Future<void> _loadSelectedProfile() async {
    if (_initialized) return;
    final preferences = await SharedPreferences.getInstance();
    profile = preferences.getString(_profileKey) == 'dev'
        ? TimingProfile.dev
        : TimingProfile.production;
    _initialized = true;
  }

  Future<void> _persistSelectedProfile() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_profileKey, profile.wireValue);
  }

  Future<void> updateSetting(String key, int value) async {
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
