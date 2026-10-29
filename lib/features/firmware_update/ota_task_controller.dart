import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../transport/device_transport.dart';
import 'ota_task_snapshot.dart';

class OtaPendingFirmware {
  const OtaPendingFirmware({
    required this.path,
    required this.name,
    required this.taskId,
    required this.version,
    required this.sha256,
    required this.length,
    this.statisticsSchema,
    this.deviceStableId,
    this.installRequested = false,
    this.legacyProtocol = false,
    this.legacyRemoteId,
  });

  final String path;
  final String name;
  final String taskId;
  final String version;
  final String sha256;
  final int length;
  final int? statisticsSchema;
  final String? deviceStableId;
  final bool installRequested;
  final bool legacyProtocol;
  final String? legacyRemoteId;

  OtaPendingFirmware copyWith({
    String? path,
    String? name,
    String? taskId,
    String? version,
    String? sha256,
    int? length,
    int? statisticsSchema,
    String? deviceStableId,
    bool? installRequested,
    bool? legacyProtocol,
    String? legacyRemoteId,
    bool clearLegacyRemoteId = false,
  }) =>
      OtaPendingFirmware(
        path: path ?? this.path,
        name: name ?? this.name,
        taskId: taskId ?? this.taskId,
        version: version ?? this.version,
        sha256: sha256 ?? this.sha256,
        length: length ?? this.length,
        statisticsSchema: statisticsSchema ?? this.statisticsSchema,
        deviceStableId: deviceStableId ?? this.deviceStableId,
        installRequested: installRequested ?? this.installRequested,
        legacyProtocol: legacyProtocol ?? this.legacyProtocol,
        legacyRemoteId:
            clearLegacyRemoteId ? null : legacyRemoteId ?? this.legacyRemoteId,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'taskId': taskId,
        'version': version,
        'sha256': sha256,
        'length': length,
        'statisticsSchema': statisticsSchema,
        'deviceStableId': deviceStableId,
        'installRequested': installRequested,
        'legacyProtocol': legacyProtocol,
        'legacyRemoteId': legacyRemoteId,
      };
}

/// OTA 页面使用的任务控制器：集中协商协议、恢复设备阶段并执行有状态命令。
/// 统一维护本地固件身份与安装意图；传输偏移仍只能由设备响应确定。
class OtaTaskController {
  OtaTaskController(this.transport);

  final FirmwareUpdateTransport transport;
  String capabilities = 'UNKNOWN';
  OtaTaskSnapshot snapshot =
      const OtaTaskSnapshot(phase: OtaTaskPhase.unknown, raw: 'UNKNOWN');

  static const _prefix = 'ota.pending.';
  static const _recordKey = '${_prefix}record';

  Future<OtaPendingFirmware?> loadPendingFirmware() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_recordKey);
    if (encoded != null) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic> &&
            decoded['path'] is String &&
            decoded['name'] is String &&
            decoded['taskId'] is String &&
            decoded['version'] is String &&
            decoded['sha256'] is String &&
            decoded['length'] is int) {
          return OtaPendingFirmware(
            path: decoded['path'] as String,
            name: decoded['name'] as String,
            taskId: decoded['taskId'] as String,
            version: decoded['version'] as String,
            sha256: decoded['sha256'] as String,
            length: decoded['length'] as int,
            statisticsSchema: decoded['statisticsSchema'] as int?,
            deviceStableId: decoded['deviceStableId'] as String?,
            installRequested: decoded['installRequested'] as bool? ?? false,
            legacyProtocol: decoded['legacyProtocol'] as bool? ?? false,
            legacyRemoteId: decoded['legacyRemoteId'] as String?,
          );
        }
      } on Object {
        // 损坏记录尝试回读旧键；文件长度与 SHA-256 仍会在恢复时复核。
      }
    }
    // 兼容控制器改为单记录前已保存的分散键。
    final path = preferences.getString('${_prefix}path');
    final name = preferences.getString('${_prefix}name');
    final taskId = preferences.getString('${_prefix}taskId');
    final version = preferences.getString('${_prefix}version');
    final sha = preferences.getString('${_prefix}sha256');
    final length = preferences.getInt('${_prefix}length');
    if (path == null ||
        name == null ||
        taskId == null ||
        version == null ||
        sha == null ||
        length == null) return null;
    return OtaPendingFirmware(
      path: path,
      name: name,
      taskId: taskId,
      version: version,
      sha256: sha,
      length: length,
      statisticsSchema: preferences.getInt('${_prefix}statisticsSchema'),
      deviceStableId: preferences.getString('${_prefix}deviceStableId'),
      installRequested:
          preferences.getBool('${_prefix}installRequested') ?? false,
      legacyProtocol: preferences.getBool('${_prefix}legacyProtocol') ?? false,
      legacyRemoteId: preferences.getString('${_prefix}legacyRemoteId'),
    );
  }

  Future<void> saveFirmware({
    required String path,
    required String name,
    required String taskId,
    required String version,
    required String sha256,
    required int length,
    int? statisticsSchema,
  }) async {
    final old = await loadPendingFirmware();
    final record = OtaPendingFirmware(
      path: path,
      name: name,
      taskId: taskId,
      version: version,
      sha256: sha256,
      length: length,
      statisticsSchema: statisticsSchema,
      deviceStableId: old?.sha256 == sha256 ? old?.deviceStableId : null,
    );
    await _saveRecord(record);
  }

  Future<void> saveTaskId(String taskId) async {
    final record = await loadPendingFirmware();
    if (record == null) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('${_prefix}taskId', taskId);
      return;
    }
    await _saveRecord(record.copyWith(taskId: taskId));
  }

  Future<void> bindDevice(String? stableId) async {
    if (stableId == null) return;
    final record = await loadPendingFirmware();
    if (record == null) return;
    await _saveRecord(record.copyWith(deviceStableId: stableId));
  }

  Future<void> markInstallRequested({
    bool legacyProtocol = false,
    String? legacyRemoteId,
  }) async {
    final record = await loadPendingFirmware();
    if (record == null) return;
    await _saveRecord(record.copyWith(
      installRequested: true,
      legacyProtocol: legacyProtocol,
      legacyRemoteId: legacyRemoteId,
    ));
  }

  Future<void> clearInstallIntent() async {
    final record = await loadPendingFirmware();
    final preferences = await SharedPreferences.getInstance();
    if (record != null) {
      await _saveRecord(record.copyWith(
        installRequested: false,
        legacyProtocol: false,
        clearLegacyRemoteId: true,
      ));
    }
    await preferences.remove('${_prefix}installRequested');
    await preferences.remove('${_prefix}legacyProtocol');
    await preferences.remove('${_prefix}legacyRemoteId');
  }

  Future<void> clearPendingFirmware() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_recordKey);
    for (final key in [
      'path',
      'name',
      'taskId',
      'version',
      'sha256',
      'length',
      'statisticsSchema',
      'deviceStableId',
      'installRequested',
      'legacyProtocol',
      'legacyRemoteId',
    ]) {
      await preferences.remove('$_prefix$key');
    }
  }

  Future<void> _saveRecord(OtaPendingFirmware record) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_recordKey, jsonEncode(record.toJson()));
  }

  bool get legacyProtocol => capabilities.startsWith('ERROR|COMMAND');

  Future<String> queryCapabilities() async {
    capabilities = await transport.queryOtaCapabilities();
    return capabilities;
  }

  Future<String> queryDeviceInfo() => transport.queryOtaDeviceInfo();

  Future<OtaTaskSnapshot> refresh({required bool legacy}) async {
    final raw = legacy
        ? await transport.readOtaStatus()
        : await transport.queryOtaTask();
    snapshot = OtaTaskSnapshot.parse(raw);
    return snapshot;
  }

  void record(String raw) => snapshot = OtaTaskSnapshot.parse(raw);

  Future<void> pause({required String taskId, required bool legacy}) async {
    if (legacy) {
      await transport.abortOtaTask();
      return;
    }
    await transport.pauseOtaTask(taskId: taskId);
    snapshot = OtaTaskSnapshot.parse(await transport.queryOtaTask());
  }

  Future<void> install({
    required String taskId,
    required bool allowDowngrade,
  }) async {
    await transport.installVerifiedFirmware(
      taskId: taskId,
      allowDowngrade: allowDowngrade,
    );
    snapshot =
        OtaTaskSnapshot.parse('INSTALLING|${snapshot.version ?? ''}|$taskId');
  }

  Future<void> abandon({required String taskId}) async {
    await transport.abandonOtaTask(taskId: taskId);
    snapshot = OtaTaskSnapshot.parse('IDLE');
  }

  Future<OtaUploadOutcome> upload({
    required String deviceId,
    required String taskId,
    required String firmwareVersion,
    required int imageLength,
    required String sha256,
    required int packageLength,
    required String packageSha256,
    required bool compressedPackage,
    required bool deltaPackage,
    required String baseVersion,
    required int baseImageLength,
    required String baseSha256,
    required bool allowDowngrade,
    required bool legacy,
    void Function(OtaTransferStage stage)? onStage,
    Future<void> Function()? onLegacyInstallCommit,
    required Stream<List<int>> Function(int offset, int maxLength) image,
    required void Function(int sentBytes, int totalBytes) onProgress,
  }) async {
    snapshot = OtaTaskSnapshot.parse(
        'UPLOADING|0|0|$imageLength|$firmwareVersion|$sha256|$taskId|$deviceId');
    try {
      final outcome = await transport.uploadFirmware(
        deviceId: deviceId,
        taskId: taskId,
        firmwareVersion: firmwareVersion,
        imageLength: imageLength,
        sha256: sha256,
        packageLength: packageLength,
        packageSha256: packageSha256,
        compressedPackage: compressedPackage,
        deltaPackage: deltaPackage,
        baseVersion: baseVersion,
        baseImageLength: baseImageLength,
        baseSha256: baseSha256,
        allowDowngrade: allowDowngrade,
        legacyProtocol: legacy,
        onStage: onStage,
        onLegacyInstallCommit: onLegacyInstallCommit,
        image: image,
        onProgress: (sentBytes, totalBytes) {
          snapshot = OtaTaskSnapshot(
            phase: OtaTaskPhase.uploading,
            raw:
                'UPLOADING|$sentBytes||$totalBytes|$firmwareVersion|$sha256|$taskId|$deviceId',
            receivedOffset: sentBytes,
            imageLength: totalBytes,
            version: firmwareVersion,
            sha256: sha256,
            taskId: taskId,
            deviceId: deviceId,
          );
          onProgress(sentBytes, totalBytes);
        },
      );
      snapshot = switch (outcome) {
        OtaUploadOutcome.paused => OtaTaskSnapshot(
            phase: OtaTaskPhase.paused,
            raw: 'PAUSED',
            imageLength: imageLength,
            version: firmwareVersion,
            sha256: sha256,
            taskId: taskId,
            deviceId: deviceId,
          ),
        OtaUploadOutcome.verifiedAwaitingInstall => OtaTaskSnapshot(
            phase: OtaTaskPhase.readyToInstall,
            raw: 'VERIFIED|$firmwareVersion|$sha256|$taskId|$deviceId',
            version: firmwareVersion,
            sha256: sha256,
            taskId: taskId,
            deviceId: deviceId,
          ),
        OtaUploadOutcome.legacyInstallStarted =>
          OtaTaskSnapshot.parse('DONE|$firmwareVersion'),
        OtaUploadOutcome.resultPending => OtaTaskSnapshot(
            phase: OtaTaskPhase.verifying,
            raw: 'VERIFYING|$taskId',
            imageLength: imageLength,
            version: firmwareVersion,
            sha256: sha256,
            taskId: taskId,
            deviceId: deviceId,
          ),
      };
      return outcome;
    } catch (error) {
      snapshot = OtaTaskSnapshot(
        phase: OtaTaskPhase.failed,
        raw: 'ERROR|$error',
        reason: error.toString(),
      );
      rethrow;
    }
  }
}
