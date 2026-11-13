import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ota_deflate.dart';

/// `.mvota` v2：签名固定头、顺序分块记录、独立 raw-deflate 数据块。
/// 每块最大 4 KiB，与设备低内存 OTA 接收端一致；不可压缩时存原始块。
class OtaPackage {
  const OtaPackage({
    required this.bytes,
    required this.imageLength,
    required this.imageSha256,
    required this.packageSha256,
    required this.version,
    required this.partitionProfile,
    required this.decodedImage,
  });

  static const int blockSize = 4 * 1024;
  static const int minimumImageSize = 1024;
  static const int maximumImageSize = 1769472;
  static const int fixedHeaderSize = 512;
  static const int signatureSize = 384;
  static const int descriptorSize = 16;
  static const List<int> magic = [0x4d, 0x56, 0x4f, 0x54, 0x41, 0x32, 0, 0];

  final Uint8List bytes;
  final int imageLength;
  final String imageSha256;
  final String packageSha256;
  final String version;
  final String partitionProfile;
  final Uint8List decodedImage;

  static OtaPackage build({
    required Uint8List image,
    required String version,
    required String partitionProfile,
    required Uint8List signature,
  }) {
    final versionBytes = ascii.encode(version);
    final profileBytes = ascii.encode(partitionProfile);
    if (image.isEmpty ||
        versionBytes.isEmpty ||
        versionBytes.length > 15 ||
        profileBytes.isEmpty ||
        profileBytes.length > 32 ||
        signature.length != signatureSize) {
      throw const FormatException('OTA 包元数据超出格式限制');
    }
    final count = (image.length + blockSize - 1) ~/ blockSize;
    const headerLength = fixedHeaderSize;
    final records = BytesBuilder(copy: false);
    for (var offset = 0; offset < image.length; offset += blockSize) {
      final end = (offset + blockSize).clamp(0, image.length);
      final raw = Uint8List.sublistView(image, offset, end);
      final deflated =
          Uint8List.fromList(ZLibEncoder(raw: true, level: 6).convert(raw));
      final compressed = deflated.length < raw.length;
      final stored = compressed ? deflated : Uint8List.fromList(raw);
      final descriptor = ByteData(descriptorSize)
        ..setUint32(0, raw.length, Endian.little)
        ..setUint32(4, stored.length, Endian.little)
        ..setUint8(8, compressed ? 1 : 0)
        ..setUint32(12, _crc32(raw), Endian.little);
      records
        ..add(descriptor.buffer.asUint8List())
        ..add(stored);
    }

    final header = Uint8List(fixedHeaderSize);
    header.setRange(0, magic.length, magic);
    final data = ByteData.sublistView(header)
      ..setUint16(8, 2, Endian.little)
      ..setUint32(12, headerLength, Endian.little)
      ..setUint32(16, image.length, Endian.little)
      ..setUint32(20, blockSize, Endian.little)
      ..setUint32(24, count, Endian.little)
      ..setUint8(60, versionBytes.length)
      ..setUint8(76, profileBytes.length);
    header.setRange(28, 60, sha256.convert(image).bytes);
    header.setRange(61, 61 + versionBytes.length, versionBytes);
    header.setRange(77, 77 + profileBytes.length, profileBytes);
    header.setRange(128, fixedHeaderSize, signature);
    data.setUint32(
        124, _crc32(Uint8List.sublistView(header, 0, 124)), Endian.little);
    final builder = BytesBuilder(copy: false)
      ..add(header)
      ..add(records.toBytes());
    final bytes = builder.takeBytes();
    return OtaPackage(
      bytes: bytes,
      imageLength: image.length,
      imageSha256: sha256.convert(image).toString(),
      packageSha256: sha256.convert(bytes).toString(),
      version: version,
      partitionProfile: partitionProfile,
      decodedImage: image,
    );
  }

  static OtaPackage parse(
    Uint8List bytes, {
    Uint8List? expectedImage,
    String? expectedVersion,
    String? expectedPartitionProfile,
  }) {
    if (bytes.length < fixedHeaderSize) {
      throw const FormatException('OTA 包头不完整');
    }
    final header = Uint8List.sublistView(bytes, 0, fixedHeaderSize);
    final view = ByteData.sublistView(bytes);
    final versionLength = bytes[60];
    final profileLength = bytes[76];
    if (!_sameBytes(bytes, 0, magic) ||
        view.getUint16(8, Endian.little) != 2 ||
        view.getUint32(12, Endian.little) != fixedHeaderSize ||
        (expectedImage != null &&
            view.getUint32(16, Endian.little) != expectedImage.length) ||
        view.getUint32(20, Endian.little) != blockSize ||
        versionLength == 0 ||
        versionLength > 15 ||
        profileLength == 0 ||
        profileLength > 32 ||
        (expectedVersion != null &&
            ascii.decode(bytes.sublist(61, 61 + versionLength)) !=
                expectedVersion) ||
        (expectedPartitionProfile != null &&
            ascii.decode(bytes.sublist(77, 77 + profileLength)) !=
                expectedPartitionProfile) ||
        bytes.sublist(128, fixedHeaderSize).every((byte) => byte == 0) ||
        view.getUint32(124, Endian.little) !=
            _crc32(Uint8List.sublistView(header, 0, 124))) {
      throw const FormatException('OTA 包头身份或校验不匹配');
    }
    final count = view.getUint32(24, Endian.little);
    final imageLength = view.getUint32(16, Endian.little);
    if (imageLength < minimumImageSize ||
        imageLength > maximumImageSize ||
        count != (imageLength + blockSize - 1) ~/ blockSize) {
      throw const FormatException('OTA 包分块数量不匹配');
    }
    final imageBuilder = BytesBuilder(copy: false);
    var offset = fixedHeaderSize;
    for (var index = 0; index < count; index++) {
      if (offset + descriptorSize > bytes.length) {
        throw const FormatException('OTA 分块描述符不完整');
      }
      final rawLength = view.getUint32(offset, Endian.little);
      final storedLength = view.getUint32(offset + 4, Endian.little);
      final codec = bytes[offset + 8];
      final blockCrc = view.getUint32(offset + 12, Endian.little);
      offset += descriptorSize;
      if (rawLength == 0 ||
          rawLength > blockSize ||
          storedLength == 0 ||
          rawLength != (imageLength - index * blockSize).clamp(0, blockSize) ||
          storedLength > blockSize ||
          offset + storedLength > bytes.length ||
          codec > 1) {
        throw const FormatException('OTA 分块长度或编码无效');
      }
      final stored =
          Uint8List.sublistView(bytes, offset, offset + storedLength);
      final raw = codec == 1
          ? inflateRawDeflateBounded(
              stored,
              maximumOutputBytes: rawLength,
            )
          : stored;
      if (raw.length != rawLength || _crc32(raw) != blockCrc) {
        throw const FormatException('OTA 分块校验失败');
      }
      imageBuilder.add(raw);
      offset += storedLength;
    }
    final decodedImage = imageBuilder.takeBytes();
    final expectedDigest =
        expectedImage == null ? null : sha256.convert(expectedImage).bytes;
    if (offset != bytes.length ||
        decodedImage.length != imageLength ||
        !_sameBytes(bytes, 28, sha256.convert(decodedImage).bytes) ||
        (expectedImage != null &&
            sha256.convert(decodedImage).toString() !=
                sha256.convert(expectedImage).toString()) ||
        (expectedDigest != null && !_sameBytes(bytes, 28, expectedDigest))) {
      throw const FormatException('OTA 包镜像内容不匹配');
    }
    return OtaPackage(
      bytes: bytes,
      imageLength: decodedImage.length,
      imageSha256: sha256.convert(decodedImage).toString(),
      packageSha256: sha256.convert(bytes).toString(),
      version: ascii.decode(bytes.sublist(61, 61 + versionLength)),
      partitionProfile: ascii.decode(bytes.sublist(77, 77 + profileLength)),
      decodedImage: decodedImage,
    );
  }

  /// 只验证容器格式和镜像摘要；发布者签名由设备端使用可信公钥验证。
  static OtaPackage parseContainer(Uint8List bytes) => parse(bytes);

  Future<File> writeTo(File file) async {
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >>> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static bool _sameBytes(List<int> source, int offset, List<int> expected) {
    if (offset + expected.length > source.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (source[offset + i] != expected[i]) return false;
    }
    return true;
  }
}
