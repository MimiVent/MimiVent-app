import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/firmware_update/ota_task_snapshot.dart';

void main() {
  group('legacy install identity verification', () {
    const digest = 'aabbcc';
    const deviceId = '112233445566';

    test('requires matching target version, digest, and device identity', () {
      expect(
        matchesInstalledImageInfo(
          response: 'INFO|0.5.0|2048|AABBCC|profile|3|$deviceId',
          targetVersion: '0.5.0',
          targetSha256: digest,
          deviceStableId: deviceId,
        ),
        isTrue,
      );
      expect(
        matchesInstalledImageInfo(
          response: 'INFO|0.5.0|2048|wrong|profile|3|$deviceId',
          targetVersion: '0.5.0',
          targetSha256: digest,
          deviceStableId: deviceId,
        ),
        isFalse,
      );
      expect(
        matchesInstalledImageInfo(
          response: 'INFO|0.5.0|2048|$digest|profile|3|other-device',
          targetVersion: '0.5.0',
          targetSha256: digest,
          deviceStableId: deviceId,
        ),
        isFalse,
      );
      expect(
        matchesInstalledImageInfo(
          response: null,
          targetVersion: '0.5.0',
          targetSha256: digest,
          deviceStableId: deviceId,
        ),
        isFalse,
      );
    });
  });

  group('OTA task status mapping', () {
    test('distinguishes written and durable offsets while uploading', () {
      final snapshot = OtaTaskSnapshot.parse(
          'UPLOADING|32768|16384|90000|0.4.0|sha|task|device');

      expect(snapshot.phase, OtaTaskPhase.uploading);
      expect(snapshot.receivedOffset, 32768);
      expect(snapshot.durableOffset, 16384);
      expect(snapshot.imageLength, 90000);
      expect(snapshot.canAbandon, isFalse);
    });

    test('paused and verified tasks can be abandoned but install cannot', () {
      expect(
          OtaTaskSnapshot.parse('PAUSED|16384|90000|0.4.0|sha|task|device')
              .canAbandon,
          isTrue);
      expect(OtaTaskSnapshot.parse('VERIFIED|0.4.0|sha|task|device').phase,
          OtaTaskPhase.readyToInstall);
      expect(
          OtaTaskSnapshot.parse('INSTALLING|0.4.0|task').canAbandon, isFalse);
      expect(
          OtaTaskSnapshot.parse('INSTALLED|0.4.0|sha|task|device').canAbandon,
          isTrue);
    });

    test('does not treat an acknowledged legacy DONE as final installation',
        () {
      final snapshot = OtaTaskSnapshot.parse('DONE|0.4.0');

      expect(snapshot.phase, OtaTaskPhase.installing);
      expect(snapshot.canAbandon, isFalse);
    });

    test('keeps unknown statuses explicit', () {
      expect(OtaTaskSnapshot.parse('FUTURE|2').phase, OtaTaskPhase.unknown);
      expect(OtaTaskSnapshot.parse('ERROR|HASH').reason, 'HASH');
    });

    test(
        'keeps rollback identity so the rejected task can be explicitly abandoned',
        () {
      final snapshot =
          OtaTaskSnapshot.parse('ERROR|BOOT_ROLLBACK|task-1|1.2.3|abc');
      expect(snapshot.phase, OtaTaskPhase.failed);
      expect(snapshot.reason, 'BOOT_ROLLBACK');
      expect(snapshot.taskId, 'task-1');
      expect(snapshot.canAbandon, isTrue);
    });
  });
}
