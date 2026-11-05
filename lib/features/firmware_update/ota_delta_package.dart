import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ota_package.dart';
import 'ota_deflate.dart';

/// `.mvdelta` v1: target-ordered COPY/raw/independent raw-deflate records.
class OtaDeltaPackage {
  const OtaDeltaPackage({
    required this.bytes,
    required this.baseLength,
    required this.baseVersion,
    required this.baseSha256,
    required this.targetLength,
    required this.targetVersion,
    required this.targetSha256,
    required this.partitionProfile,
    required this.statisticsSchema,
    this.minReadableStorageSchema,
  });

  static const int headerSize = 576;
  static const int signatureSize = 384;
  static const int recordHeaderSize = 24;
  static const int blockSize = 4096;
  static const List<int> magic = [0x4d, 0x56, 0x44, 0x4c, 0x54, 0x31, 0, 0];

  final Uint8List bytes;
  final int baseLength;
  final String baseVersion;
  final String baseSha256;
  final int targetLength;
  final String targetVersion;
  final String targetSha256;
  final String partitionProfile;
  final int statisticsSchema;
  final int? minReadableStorageSchema;
  String get packageSha256 => sha256.convert(bytes).toString();

  static OtaDeltaPackage parse(Uint8List bytes) {
    if (bytes.length < headerSize) throw const FormatException('差分包头不完整');
    final view = ByteData.sublistView(bytes);
    final header = Uint8List.sublistView(bytes, 0, headerSize);
    final baseVersionLength = bytes[88];
    final targetVersionLength = bytes[104];
    final profileLength = bytes[120];
    if (!_bytesEqual(bytes, 0, magic) ||
        view.getUint16(8, Endian.little) != 2 ||
        view.getUint16(10, Endian.little) != headerSize ||
        view.getUint32(156, Endian.little) != blockSize ||
        view.getUint16(160, Endian.little) != recordHeaderSize ||
        baseVersionLength == 0 ||
        baseVersionLength > 15 ||
        targetVersionLength == 0 ||
        targetVersionLength > 15 ||
        profileLength == 0 ||
        profileLength > 32 ||
        view.getUint32(188, Endian.little) !=
            _crc32(Uint8List.sublistView(header, 0, 188)) ||
        bytes.sublist(192, 192 + signatureSize).every((byte) => byte == 0)) {
      throw const FormatException('差分包格式或头校验无效');
    }
    final baseLength = view.getUint32(12, Endian.little);
    final targetLength = view.getUint32(16, Endian.little);
    final recordCount = view.getUint32(20, Endian.little);
    if (baseLength < OtaPackage.minimumImageSize ||
        baseLength > OtaPackage.maximumImageSize ||
        targetLength < OtaPackage.minimumImageSize ||
        targetLength > OtaPackage.maximumImageSize ||
        recordCount != (targetLength + blockSize - 1) ~/ blockSize) {
      throw const FormatException('差分包镜像长度或记录数量无效');
    }
    final baseVersion = ascii.decode(bytes.sublist(89, 89 + baseVersionLength));
    final targetVersion =
        ascii.decode(bytes.sublist(105, 105 + targetVersionLength));
    final profile = ascii.decode(bytes.sublist(121, 121 + profileLength));
    var cursor = headerSize;
    var targetOffset = 0;
    for (var index = 0; index < recordCount; index++) {
      if (cursor + recordHeaderSize > bytes.length) {
        throw const FormatException('差分记录头不完整');
      }
      final type = bytes[cursor];
      final recordTargetOffset = view.getUint32(cursor + 4, Endian.little);
      final outputLength = view.getUint32(cursor + 8, Endian.little);
      final sourceOffset = view.getUint32(cursor + 12, Endian.little);
      final payloadLength = view.getUint32(cursor + 16, Endian.little);
      final expectedLength = (targetLength - targetOffset).clamp(0, blockSize);
      if (recordTargetOffset != targetOffset ||
          outputLength != expectedLength ||
          (type != 0 && type != 1 && type != 2) ||
          (type == 0 &&
              (payloadLength != 0 ||
                  sourceOffset + outputLength > baseLength)) ||
          (type != 0 && (payloadLength == 0 || payloadLength > blockSize))) {
        throw const FormatException('差分记录范围无效');
      }
      cursor += recordHeaderSize;
      if (type != 0) {
        if (cursor + payloadLength > bytes.length) {
          throw const FormatException('差分记录数据不完整');
        }
        final stored =
            Uint8List.sublistView(bytes, cursor, cursor + payloadLength);
        final raw = type == 1
            ? inflateRawDeflateBounded(
                stored,
                maximumOutputBytes: outputLength,
              )
            : stored;
        if (raw.length != outputLength ||
            _crc32(raw) != view.getUint32(cursor - 4, Endian.little)) {
          throw const FormatException('差分数据块校验失败');
        }
        cursor += payloadLength;
      }
      targetOffset += outputLength;
    }
    if (cursor != bytes.length || targetOffset != targetLength) {
      throw const FormatException('差分包尾部或目标长度无效');
    }
    return OtaDeltaPackage(
      bytes: bytes,
      baseLength: baseLength,
      baseVersion: baseVersion,
      baseSha256: _hex(bytes, 24),
      targetLength: targetLength,
      targetVersion: targetVersion,
      targetSha256: _hex(bytes, 56),
      partitionProfile: profile,
      statisticsSchema: view.getUint16(153, Endian.little),
      minReadableStorageSchema: view.getUint16(162, Endian.little) == 0
          ? null : view.getUint16(162, Endian.little),
    );
  }

  static String _hex(List<int> bytes, int offset) => bytes
      .sublist(offset, offset + 32)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();

  static bool _bytesEqual(List<int> source, int offset, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (source[offset + i] != expected[i]) return false;
    }
    return true;
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
}
