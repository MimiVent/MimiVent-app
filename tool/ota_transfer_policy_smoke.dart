import 'package:mimivent_app/transport/ota_transfer_policy.dart';
import 'package:mimivent_app/features/firmware_update/ota_task_snapshot.dart';

void main() {
  assert(otaWindowSizeForCredits(0, 4) == 0);
  assert(otaWindowSizeForCredits(2, 4) == 2);
  assert(otaWindowSizeForCredits(9, 4) == 4);
  assert(otaTransferLength(
          imageLength: 1000,
          packageLength: 200,
          compressedPackage: false,
          deltaPackage: true) ==
      200);
  assert(matchesInstalledImageInfo(
    response: 'INFO|0.5.0|2048|AABBCC|profile|3|112233445566',
    targetVersion: '0.5.0',
    targetSha256: 'aabbcc',
    deviceStableId: '112233445566',
  ));
  assert(!matchesInstalledImageInfo(
    response: 'INFO|0.5.0|2048|wrong|profile|3|112233445566',
    targetVersion: '0.5.0',
    targetSha256: 'aabbcc',
    deviceStableId: '112233445566',
  ));
}
