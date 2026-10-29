import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/firmware_update/ota_delta_package.dart';
import 'package:mimivent_app/features/firmware_update/ota_package.dart';

void main() {
  test('rejects base and target images outside OTA partition limits', () {
    for (final invalidLength in [
      OtaPackage.minimumImageSize - 1,
      OtaPackage.maximumImageSize + 1,
    ]) {
      expect(
        () => OtaDeltaPackage.parse(_deltaHeader(
          baseLength: invalidLength,
          targetLength: OtaPackage.minimumImageSize,
        )),
        throwsFormatException,
      );
      expect(
        () => OtaDeltaPackage.parse(_deltaHeader(
          baseLength: OtaPackage.minimumImageSize,
          targetLength: invalidLength,
        )),
        throwsFormatException,
      );
    }
  });
}

Uint8List _deltaHeader({required int baseLength, required int targetLength}) {
  final bytes = Uint8List(OtaDeltaPackage.headerSize);
  bytes.setRange(0, OtaDeltaPackage.magic.length, OtaDeltaPackage.magic);
  final data = ByteData.sublistView(bytes)
    ..setUint16(8, 2, Endian.little)
    ..setUint16(10, OtaDeltaPackage.headerSize, Endian.little)
    ..setUint32(12, baseLength, Endian.little)
    ..setUint32(16, targetLength, Endian.little)
    ..setUint32(20, 1, Endian.little)
    ..setUint16(153, 3, Endian.little)
    ..setUint32(156, OtaDeltaPackage.blockSize, Endian.little)
    ..setUint16(160, OtaDeltaPackage.recordHeaderSize, Endian.little)
    ..setUint8(88, 5)
    ..setUint8(104, 5)
    ..setUint8(120, 4);
  bytes.setRange(89, 94, '1.2.3'.codeUnits);
  bytes.setRange(105, 110, '1.2.4'.codeUnits);
  bytes.setRange(121, 125, 'test'.codeUnits);
  bytes.fillRange(192, bytes.length, 0xA5);
  data.setUint32(188, _crc32(bytes.sublist(0, 188)), Endian.little);
  return bytes;
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
