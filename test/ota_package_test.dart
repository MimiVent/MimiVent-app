import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/firmware_update/ota_package.dart';

void main() {
  test('packages independent 4 KiB deflate blocks and identifies the image',
      () {
    final image = Uint8List.fromList(List<int>.generate(
      OtaPackage.blockSize + 173,
      (index) => index % 251 < 180 ? 0x41 : index % 256,
    ));
    final package = OtaPackage.build(
      image: image,
      version: '0.4.1',
      partitionProfile: 'statistics-v2-ota-v1',
      signature:
          Uint8List.fromList(List<int>.filled(OtaPackage.signatureSize, 0xA5)),
    );
    final data = ByteData.sublistView(package.bytes);
    expect(package.bytes.sublist(0, 8), OtaPackage.magic);
    expect(data.getUint16(8, Endian.little), 2);
    expect(data.getUint32(16, Endian.little), image.length);
    expect(data.getUint32(20, Endian.little), OtaPackage.blockSize);
    expect(data.getUint32(24, Endian.little), 2);
    expect(package.imageSha256, isNotEmpty);
    expect(package.packageSha256, isNotEmpty);
    final parsed = OtaPackage.parseContainer(package.bytes);
    expect(parsed.packageSha256, package.packageSha256);

    final directoryEnd = data.getUint32(12, Endian.little);
    var packageOffset = directoryEnd;
    var imageOffset = 0;
    for (var index = 0; index < 2; index++) {
      final descriptor = packageOffset;
      final rawLength = data.getUint32(descriptor, Endian.little);
      final storedLength = data.getUint32(descriptor + 4, Endian.little);
      final codec = package.bytes[descriptor + 8];
      packageOffset += OtaPackage.descriptorSize;
      final stored =
          package.bytes.sublist(packageOffset, packageOffset + storedLength);
      final decoded =
          codec == 1 ? ZLibDecoder(raw: true).convert(stored) : stored;
      expect(decoded, image.sublist(imageOffset, imageOffset + rawLength));
      imageOffset += rawLength;
      packageOffset += storedLength;
    }
    expect(imageOffset, image.length);
    expect(packageOffset, package.bytes.length);
  });

  test('rejects an empty image container before page-level inspection', () {
    final header = Uint8List(OtaPackage.fixedHeaderSize);
    header.setRange(0, OtaPackage.magic.length, OtaPackage.magic);
    final data = ByteData.sublistView(header)
      ..setUint16(8, 2, Endian.little)
      ..setUint32(12, OtaPackage.fixedHeaderSize, Endian.little)
      ..setUint32(16, 0, Endian.little)
      ..setUint32(20, OtaPackage.blockSize, Endian.little)
      ..setUint32(24, 0, Endian.little)
      ..setUint8(60, 5)
      ..setUint8(76, 4);
    header.setRange(61, 66, '0.4.1'.codeUnits);
    header.setRange(77, 81, 'test'.codeUnits);
    header.fillRange(128, OtaPackage.fixedHeaderSize, 0xA5);
    data.setUint32(124, _crc32(header.sublist(0, 124)), Endian.little);

    expect(() => OtaPackage.parseContainer(header), throwsFormatException);
  });
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
