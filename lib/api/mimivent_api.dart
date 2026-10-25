import 'package:flutter/foundation.dart';

import '../app/app_identity.dart';
import '../ble/mimivent_ble_manager.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import '../data/models.dart';

/// 把应用内操作映射到固件已有的 /api/* 控制接口。
class MimiVentApi {
  MimiVentApi(this._ble, {this.diagnostics});

  final MimiVentBleManager _ble;
  final AppDiagnosticsLog? diagnostics;
  String? _lastLoggedFirmware;
  final Map<String, DateTime> _lastReadFailureAt = {};
  String? _lastStatusSignature;
  DateTime? _lastStatusSummaryAt;

  Future<Map<String, dynamic>> _request({
    required String method,
    required String path,
    required TimingProfile profile,
    Map<String, String> query = const {},
    String body = '',
  }) async {
    try {
      final response = await _ble.request(
        method: method,
        path: path,
        query: {'profile': profile.wireValue, ...query},
        body: body,
      );
      final json = decodeJsonObject(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final raw = json['error']?.toString() ?? 'HTTP ${response.statusCode}';
        final message = _friendlyError(raw);
        if (method == 'GET') {
          _logReadFailure(path, message);
        } else {
          diagnostics?.warning('设备接口', '$method $path 失败：$message');
        }
        throw DeviceApiException(message);
      }
      _lastReadFailureAt.remove(path);
      if (method != 'GET') {
        diagnostics?.info('设备接口', '$method $path 执行成功');
      }
      return json;
    } on DeviceApiException {
      rethrow;
    } catch (error) {
      if (method == 'GET') {
        _logReadFailure(path, error);
      } else {
        diagnostics?.error('设备接口', '$method $path 通信失败：$error');
      }
      rethrow;
    }
  }

  /// 状态每秒轮询；相同读取错误最多每 30 秒记一次，避免日志被重复错误刷满。
  void _logReadFailure(String path, Object error) {
    final now = DateTime.now();
    final previous = _lastReadFailureAt[path];
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 30)) {
      return;
    }
    _lastReadFailureAt[path] = now;
    diagnostics?.error('设备读取', 'GET $path 失败：$error');
  }

  String _friendlyError(String raw) {
    switch (raw) {
      case 'PROFILE_MISMATCH':
        return '设备环境已变化，请先同步或切换环境';
      case 'PIR_HIGH':
        return '检测到活动，已阻止临时排风';
      case 'STARTUP_COOLDOWN':
        return '设备仍在开机冷静期';
      default:
        return raw;
    }
  }

  Future<DeviceStatus> getStatus(TimingProfile profile) async {
    final json = await _request(
      method: 'GET',
      path: '/api/status',
      profile: profile,
    );
    late final DeviceStatus status;
    try {
      status = DeviceStatus.fromJson(json);
      if (status.viewProfile != profile) {
        throw FormatException(
          '设备状态环境不匹配：请求 ${profile.wireValue}，'
          '收到 ${status.viewProfile.wireValue}',
        );
      }
    } catch (error) {
      diagnostics?.error('设备状态', '响应数据校验失败：$error');
      rethrow;
    }
    final firmware = status.firmware;
    if (firmware != _lastLoggedFirmware) {
      if (kDebugMode) {
        debugPrint(
            '[${AppIdentity.productName}][BLE] /api/status returned firmware=$firmware');
      }
      diagnostics?.info('设备信息', '已读取固件版本 v$firmware');
      _lastLoggedFirmware = firmware;
    }
    _logStatusSummary(status);
    return status;
  }

  Future<TimingSettings> getSettings(TimingProfile profile) async {
    final json = await _request(
      method: 'GET',
      path: '/api/settings',
      profile: profile,
    );
    try {
      final responseProfile = json['profile'];
      if (responseProfile != profile.wireValue) {
        throw FormatException(
          '设备配置环境不匹配：期望 ${profile.wireValue}，收到 $responseProfile',
        );
      }
      return TimingSettings.fromJson(json);
    } catch (error) {
      diagnostics?.error('设备配置', '响应数据校验失败：$error');
      rethrow;
    }
  }

  /// 状态轮询忽略倒计时等每秒变化字段，只在状态变化或每 30 秒记摘要。
  void _logStatusSummary(DeviceStatus status) {
    final signature = [
      status.fan,
      status.pir,
      status.mode,
      status.phase,
      status.activeProfile.wireValue,
      status.viewProfile.wireValue,
    ].join('|');
    final changed = signature != _lastStatusSignature;
    final now = DateTime.now();
    final summaryDue = _lastStatusSummaryAt == null ||
        now.difference(_lastStatusSummaryAt!) >= const Duration(seconds: 30);
    if (!changed && !summaryDue) return;

    final reason = changed ? '状态变化' : '定期摘要';
    diagnostics?.info(
      '设备状态',
      '$reason：风机=${status.fan ? '运行' : '停止'}，'
          'PIR=${status.pir ? 'HIGH' : 'LOW'}，模式=${status.mode}，'
          '阶段=${status.phase}，设备环境=${status.activeProfile.label}，'
          '查看环境=${status.viewProfile.label}',
    );
    _lastStatusSignature = signature;
    _lastStatusSummaryAt = now;
  }

  Future<void> saveSettings(
      TimingProfile profile, TimingSettings settings) async {
    await _request(
      method: 'POST',
      path: '/api/settings',
      profile: profile,
      body: settings.toFormBody(),
    );
  }

  Future<void> resetSettings(TimingProfile profile) async {
    await _request(
        method: 'POST', path: '/api/settings/reset', profile: profile);
  }

  Future<void> setAuto(TimingProfile profile,
      {bool replace = false, bool switchProfile = false}) async {
    await _request(
      method: 'POST',
      path: '/api/auto',
      profile: profile,
      query: {
        if (replace) 'replace': '1',
        if (switchProfile) 'switch': '1',
      },
    );
  }

  Future<void> startTimed(TimingProfile profile, {bool replace = false}) async {
    await _request(
        method: 'POST',
        path: '/api/timed',
        profile: profile,
        query: {
          'mode': 'on',
          if (replace) 'replace': '1',
        });
  }

  Future<void> startPause(TimingProfile profile, {bool replace = false}) async {
    await _request(
        method: 'POST',
        path: '/api/timed',
        profile: profile,
        query: {
          'mode': 'off',
          if (replace) 'replace': '1',
        });
  }

  Future<void> startFanTest(TimingProfile profile,
      {bool replace = false}) async {
    await _request(
      method: 'POST',
      path: '/api/test-fan',
      profile: profile,
      query: {if (replace) 'replace': '1'},
    );
  }

  Future<void> armLockOff(TimingProfile profile) async {
    await _request(
        method: 'POST',
        path: '/api/lockoff',
        profile: profile,
        query: {'stage': 'prepare'});
  }

  Future<void> confirmLockOff(TimingProfile profile,
      {bool replace = false}) async {
    await _request(
      method: 'POST',
      path: '/api/lockoff',
      profile: profile,
      query: {'stage': 'confirm', if (replace) 'replace': '1'},
    );
  }

  Future<void> cancelLockOff(TimingProfile profile) async {
    await _request(
        method: 'POST',
        path: '/api/lockoff',
        profile: profile,
        query: {'stage': 'cancel'});
  }
}

class DeviceApiException implements Exception {
  const DeviceApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
