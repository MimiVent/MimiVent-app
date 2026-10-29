/// OTA wire status 映射到 App 共用阶段，页面不得用一次连接异常推断升级失败。
enum OtaTaskPhase {
  idle,
  ready,
  uploading,
  paused,
  verifying,
  readyToInstall,
  installing,
  installed,
  failed,
  unknown,
}

/// 只有设备重连后返回的运行镜像身份全部匹配，才能确认旧协议升级结果。
bool matchesInstalledImageInfo({
  required String? response,
  required String targetVersion,
  required String targetSha256,
  required String deviceStableId,
}) {
  if (response == null) return false;
  final fields = response.split('|');
  return fields.length >= 7 &&
      fields[0] == 'INFO' &&
      fields[1] == targetVersion &&
      fields[3].toLowerCase() == targetSha256.toLowerCase() &&
      fields[6] == deviceStableId;
}

class OtaTaskSnapshot {
  const OtaTaskSnapshot({
    required this.phase,
    required this.raw,
    this.receivedOffset,
    this.durableOffset,
    this.imageLength,
    this.version,
    this.sha256,
    this.taskId,
    this.deviceId,
    this.reason,
  });

  final OtaTaskPhase phase;
  final String raw;
  final int? receivedOffset;
  final int? durableOffset;
  final int? imageLength;
  final String? version;
  final String? sha256;
  final String? taskId;
  final String? deviceId;
  final String? reason;

  bool get canAbandon =>
      phase == OtaTaskPhase.paused ||
      phase == OtaTaskPhase.readyToInstall ||
      phase == OtaTaskPhase.installed ||
      (phase == OtaTaskPhase.failed && reason == 'BOOT_ROLLBACK');

  factory OtaTaskSnapshot.parse(String status) {
    final fields = status.split('|');
    int? number(int index) =>
        fields.length > index ? int.tryParse(fields[index]) : null;
    String? value(int index) =>
        fields.length > index && fields[index].isNotEmpty
            ? fields[index]
            : null;

    if (status == 'IDLE') {
      return OtaTaskSnapshot(phase: OtaTaskPhase.idle, raw: status);
    }
    if (status == 'READY' || status.startsWith('READY|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.ready,
        raw: status,
        version: value(1),
        imageLength: number(2),
        receivedOffset: number(3),
        taskId: value(4),
        deviceId: value(5),
      );
    }
    if (status.startsWith('RESUMED|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.uploading,
        raw: status,
        version: value(1),
        imageLength: number(2),
        receivedOffset: number(3),
        taskId: value(4),
        deviceId: value(5),
      );
    }
    if (status.startsWith('UPLOADING|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.uploading,
        raw: status,
        receivedOffset: number(1),
        durableOffset: number(2),
        imageLength: number(3),
        version: value(4),
        sha256: value(5),
        taskId: value(6),
        deviceId: value(7),
      );
    }
    if (status.startsWith('PAUSED|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.paused,
        raw: status,
        receivedOffset: number(1),
        durableOffset: number(1),
        imageLength: number(2),
        version: value(3),
        sha256: value(4),
        taskId: value(5),
        deviceId: value(6),
        reason: value(7),
      );
    }
    if (status.startsWith('VERIFIED|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.readyToInstall,
        raw: status,
        version: value(1),
        sha256: value(2),
        taskId: value(3),
        deviceId: value(4),
      );
    }
    if (status.startsWith('INSTALLING|') || status.startsWith('DONE|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.installing,
        raw: status,
        version: value(1),
        taskId: value(2),
      );
    }
    if (status.startsWith('INSTALLED|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.installed,
        raw: status,
        version: value(1),
        sha256: value(2),
        taskId: value(3),
        deviceId: value(4),
      );
    }
    if (status.startsWith('ERROR|BOOT_ROLLBACK|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.failed,
        raw: status,
        reason: 'BOOT_ROLLBACK',
        taskId: value(2),
        version: value(3),
        sha256: value(4),
      );
    }
    if (status.startsWith('ERROR|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.failed,
        raw: status,
        reason: status.substring('ERROR|'.length),
      );
    }
    if (status.startsWith('VERIFYING|')) {
      return OtaTaskSnapshot(
        phase: OtaTaskPhase.verifying,
        raw: status,
        taskId: value(1),
      );
    }
    return OtaTaskSnapshot(phase: OtaTaskPhase.unknown, raw: status);
  }
}
