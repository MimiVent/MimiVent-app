import 'dart:async';

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
  TimingSettings? settings;
  SettingsDraft? _settingsDraft;
  TimingSettings? get draftSettings => _settingsDraft?.value;
  TimingProfile profile = TimingProfile.production;
  Timer? _pollTimer;
  bool busy = false;
  bool _polling = false;
  bool _statusInvalid = false;
  bool _initialized = false;
  bool _disposed = false;
  int _sessionGeneration = 0;
  int _connectAttempt = 0;
  Future<void>? _closingBluetoothSession;
  static const _profileKey = 'mimivent.selected_profile';
  String? lastError;

  bool get connected => ble.isConnected;
  bool get statusInvalid => _statusInvalid;
  bool get profileMatches => status != null && status!.activeProfile == profile;
  bool get hasUnsavedSettings => _settingsDraft?.isDirty ?? false;
  bool get hasInterruptibleTask => hasInterruptibleOperation(status);

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
    if (!ble.isConnected && !ble.isScanning) await scan();
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
