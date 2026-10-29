import 'package:flutter/foundation.dart';

/// 设备业务 API 的传输无关请求。
/// BLE、局域网 HTTP 和未来远程 HTTP 适配器只负责编码/传输，不实现控制规则。
class DeviceRequest {
  const DeviceRequest({
    required this.method,
    required this.path,
    this.query = const {},
    this.body = '',
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final String body;
}

class DeviceResponse {
  const DeviceResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

abstract interface class DeviceTransport {
  Future<DeviceResponse> send(DeviceRequest request);
}

enum OtaUploadOutcome {
  verifiedAwaitingInstall,
  paused,
  legacyInstallStarted,
  resultPending,
}

enum OtaTransferStage { erasing, uploading, verifying }

class DeviceBusyException implements Exception {
  const DeviceBusyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 固件升级是大文件流，和普通 JSON RPC 分开抽象，避免走 BLE 通知分片。
abstract interface class OtaTransport {
  Future<OtaUploadOutcome> uploadFirmware({
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
    required bool legacyProtocol,
    void Function(OtaTransferStage stage)? onStage,
    Future<void> Function()? onLegacyInstallCommit,
    required Stream<List<int>> Function(int offset, int maxLength) image,
    required void Function(int sentBytes, int totalBytes) onProgress,
  });

  Future<void> installVerifiedFirmware({
    required String taskId,
    required bool allowDowngrade,
  });

  Future<String> queryOtaTask();

  Future<String> queryOtaCapabilities();

  Future<String> queryOtaDeviceInfo();

  Future<void> pauseOtaTask({required String taskId});

  Future<void> abortOtaTask();

  Future<void> abandonOtaTask({required String taskId});
}

/// 固件升级页面依赖的传输无关设备会话；BLE 与后续 Wi-Fi OTA 可分别实现。
abstract interface class FirmwareUpdateTransport
    implements DeviceTransport, OtaTransport, Listenable {
  bool get isConnected;

  bool get isOtaUploading;

  bool get isOtaVerifying;

  bool get isOtaExclusive;

  bool get deviceOtaBusy;

  bool get appVersionCompatible;

  void setDeviceOtaBusy(bool value);

  void setFirmwareAppCompatible(bool value);

  String? get connectedDeviceId;

  Future<String> readOtaStatus();
}
