import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimivent_app/features/firmware_update/ota_task_controller.dart';
import 'package:mimivent_app/transport/device_transport.dart';

void main() {
  group('OtaTaskController', () {
    test('persists firmware identity, device binding and install intent',
        () async {
      SharedPreferences.setMockInitialValues({});
      final controller = OtaTaskController(_FakeFirmwareTransport());

      await controller.saveFirmware(
        path: '/app/firmware.bin',
        name: 'firmware.bin',
        taskId: 'task-1',
        version: '0.4.0',
        sha256: 'abc123',
        length: 4096,
        statisticsSchema: 3,
      );
      await controller.bindDevice('device-1');
      await controller.markInstallRequested(
          legacyProtocol: true, legacyRemoteId: 'remote-1');
      final stored = await controller.loadPendingFirmware();

      expect(stored?.taskId, 'task-1');
      expect(stored?.sha256, 'abc123');
      expect(stored?.statisticsSchema, 3);
      expect(stored?.deviceStableId, 'device-1');
      expect(stored?.installRequested, isTrue);
      expect(stored?.legacyProtocol, isTrue);
      expect(stored?.legacyRemoteId, 'remote-1');

      await controller.clearInstallIntent();
      final cleared = await controller.loadPendingFirmware();
      expect(cleared?.installRequested, isFalse);
      expect(cleared?.legacyProtocol, isFalse);
      expect(cleared?.legacyRemoteId, isNull);
    });

    test('queries V2 task state after capabilities negotiation', () async {
      final transport = _FakeFirmwareTransport()
        ..capabilities = 'CAPS|2|resume=1'
        ..taskStatus = 'PAUSED|16384|90000|0.4.0|sha|task|device';
      final controller = OtaTaskController(transport);

      await controller.queryCapabilities();
      final snapshot = await controller.refresh(legacy: false);

      expect(snapshot.raw, transport.taskStatus);
      expect(snapshot.canAbandon, isTrue);
      expect(transport.calls, ['capabilities', 'query']);
    });

    test('uses the legacy status read path for old firmware', () async {
      final transport = _FakeFirmwareTransport()
        ..capabilities = 'ERROR|COMMAND'
        ..legacyStatus = 'IDLE';
      final controller = OtaTaskController(transport);

      await controller.queryCapabilities();
      final snapshot = await controller.refresh(legacy: true);

      expect(snapshot.phase.name, 'idle');
      expect(transport.calls, ['capabilities', 'legacy-status']);
    });

    test('pauses before returning and refreshes the device-confirmed offset',
        () async {
      final transport = _FakeFirmwareTransport()
        ..taskStatus = 'PAUSED|16384|90000|0.4.0|sha|task|device';
      final controller = OtaTaskController(transport);

      await controller.pause(taskId: 'task', legacy: false);

      expect(transport.calls, ['pause:task', 'query']);
      expect(controller.snapshot.durableOffset, 16384);
    });

    test('records install as non-cancellable and abandon as idle', () async {
      final transport = _FakeFirmwareTransport();
      final controller = OtaTaskController(transport)
        ..record('VERIFIED|0.4.0|sha|task|device');

      await controller.install(taskId: 'task', allowDowngrade: false);
      expect(controller.snapshot.phase.name, 'installing');
      expect(transport.calls, ['install:task:false']);

      await controller.abandon(taskId: 'task');
      expect(controller.snapshot.phase.name, 'idle');
      expect(transport.calls.last, 'abandon:task');
    });

    test('keeps a verification timeout as a pending result, not a failure',
        () async {
      final transport = _FakeFirmwareTransport()
        ..uploadOutcome = OtaUploadOutcome.resultPending;
      final controller = OtaTaskController(transport);

      final outcome = await controller.upload(
        deviceId: 'device',
        taskId: 'task',
        firmwareVersion: '0.4.0',
        imageLength: 4,
        sha256: 'sha',
        packageLength: 4,
        packageSha256: 'pkg-sha',
        compressedPackage: true,
        deltaPackage: false,
        baseVersion: '',
        baseImageLength: 0,
        baseSha256: '',
        allowDowngrade: false,
        legacy: false,
        image: (_, __) async* {},
        onProgress: (_, __) {},
      );

      expect(outcome, OtaUploadOutcome.resultPending);
      expect(controller.snapshot.phase.name, 'verifying');
      expect(controller.snapshot.taskId, 'task');
    });
  });
}

class _FakeFirmwareTransport implements FirmwareUpdateTransport {
  String capabilities = 'CAPS|2';
  String taskStatus = 'IDLE';
  String legacyStatus = 'IDLE';
  OtaUploadOutcome uploadOutcome = OtaUploadOutcome.verifiedAwaitingInstall;
  final List<String> calls = [];

  @override
  bool get isConnected => true;

  @override
  bool get isOtaUploading => false;

  @override
  bool get isOtaVerifying => false;

  @override
  bool get isOtaExclusive => false;

  @override
  bool get deviceOtaBusy => false;

  @override
  bool get appVersionCompatible => true;

  @override
  void setDeviceOtaBusy(bool value) {}

  @override
  void setFirmwareAppCompatible(bool value) {}

  @override
  String? get connectedDeviceId => 'device';

  @override
  Future<String> queryOtaCapabilities() async {
    calls.add('capabilities');
    return capabilities;
  }

  @override
  Future<String> queryOtaTask() async {
    calls.add('query');
    return taskStatus;
  }

  @override
  Future<String> readOtaStatus() async {
    calls.add('legacy-status');
    return legacyStatus;
  }

  @override
  Future<void> pauseOtaTask({required String taskId}) async {
    calls.add('pause:$taskId');
  }

  @override
  Future<void> abortOtaTask() async => calls.add('abort');

  @override
  Future<void> installVerifiedFirmware({
    required String taskId,
    required bool allowDowngrade,
  }) async =>
      calls.add('install:$taskId:$allowDowngrade');

  @override
  Future<void> abandonOtaTask({required String taskId}) async =>
      calls.add('abandon:$taskId');

  @override
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
  }) async =>
      uploadOutcome;

  @override
  Future<DeviceResponse> send(DeviceRequest request) async =>
      const DeviceResponse(statusCode: 200, body: '{}');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
