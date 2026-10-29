import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/transport/ota_transfer_policy.dart';

void main() {
  test('zero OTA credits stop the sender instead of forcing a one-chunk window',
      () {
    expect(otaWindowSizeForCredits(0, 4), 0);
    expect(otaWindowSizeForCredits(-1, 4), 0);
    expect(otaWindowSizeForCredits(2, 4), 2);
    expect(otaWindowSizeForCredits(8, 4), 4);
  });

  test('compressed and delta progress use bytes actually sent', () {
    expect(
      otaTransferLength(
        imageLength: 1000,
        packageLength: 300,
        compressedPackage: true,
        deltaPackage: false,
      ),
      300,
    );
    expect(
      otaTransferLength(
        imageLength: 1000,
        packageLength: 200,
        compressedPackage: false,
        deltaPackage: true,
      ),
      200,
    );
    expect(
      otaTransferLength(
        imageLength: 1000,
        packageLength: 300,
        compressedPackage: false,
        deltaPackage: false,
      ),
      1000,
    );
  });
}
