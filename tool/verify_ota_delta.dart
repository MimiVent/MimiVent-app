import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:mimivent_app/features/firmware_update/ota_delta_package.dart';
import 'package:mimivent_app/features/firmware_update/ota_package.dart';

/// Cross-check a .mvdelta produced by the firmware repository's Python tool.
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
        'usage: dart run tool/verify_ota_delta.dart <base.bin> <target.bin> <patch.mvdelta>');
    exitCode = 64;
    return;
  }
  final base = await File(args[0]).readAsBytes();
  final target = await File(args[1]).readAsBytes();
  final patchBytes = await File(args[2]).readAsBytes();
  final patch = OtaDeltaPackage.parse(Uint8List.fromList(patchBytes));
  _expect(patch.baseLength == base.length, 'base length mismatch');
  _expect(patch.targetLength == target.length, 'target length mismatch');
  _expect(patch.baseSha256 == sha256.convert(base).toString(),
      'base SHA-256 mismatch');
  _expect(patch.targetSha256 == sha256.convert(target).toString(),
      'target SHA-256 mismatch');

  final rebuilt = BytesBuilder(copy: false);
  final view = ByteData.sublistView(patch.bytes);
  var cursor = OtaDeltaPackage.headerSize;
  for (var index = 0;
      index <
          (target.length + OtaDeltaPackage.blockSize - 1) ~/
              OtaDeltaPackage.blockSize;
      index++) {
    final recordOffset = cursor;
    final type = patch.bytes[cursor];
    final targetOffset = view.getUint32(cursor + 4, Endian.little);
    final outputLength = view.getUint32(cursor + 8, Endian.little);
    final sourceOffset = view.getUint32(cursor + 12, Endian.little);
    final payloadLength = view.getUint32(cursor + 16, Endian.little);
    final expectedCrc = view.getUint32(cursor + 20, Endian.little);
    cursor += OtaDeltaPackage.recordHeaderSize;
    late final List<int> output;
    if (type == 0) {
      output = base.sublist(sourceOffset, sourceOffset + outputLength);
    } else {
      final payload = patch.bytes.sublist(cursor, cursor + payloadLength);
      output = type == 1 ? ZLibDecoder(raw: true).convert(payload) : payload;
      cursor += payloadLength;
    }
    _expect(
        targetOffset == rebuilt.length, 'record $index target offset mismatch');
    _expect(
        output.length == outputLength, 'record $index output length mismatch');
    _expect(_crc32(output) == expectedCrc,
        'record $index CRC mismatch at $recordOffset');
    rebuilt.add(output);
  }
  final reconstructed = rebuilt.takeBytes();
  _expect(listEquals(reconstructed, target),
      'reconstructed image differs from target');

  _mustReject(() =>
      OtaDeltaPackage.parse(Uint8List.fromList(patchBytes)..[188] ^= 0xff));
  _mustReject(() => OtaDeltaPackage.parse(
      Uint8List.fromList(patchBytes.sublist(0, patchBytes.length - 1))));

  final fullPackage = OtaPackage.build(
    image: Uint8List.fromList(target),
    version: patch.targetVersion,
    partitionProfile: patch.partitionProfile,
    signature: Uint8List.fromList(List<int>.filled(OtaPackage.signatureSize, 0xA5)),
  );
  final saving = fullPackage.bytes.length - patchBytes.length;
  final percentage =
      fullPackage.bytes.isEmpty ? 0.0 : saving * 100 / fullPackage.bytes.length;
  stdout.writeln('cross-language delta validation: PASS');
  stdout.writeln('base=${base.length} target=${target.length}');
  stdout.writeln(
      'delta=${patchBytes.length} compressed-full=${fullPackage.bytes.length}');
  stdout.writeln(
      'delta savings=$saving bytes (${percentage.toStringAsFixed(1)}%)');
}

void _mustReject(void Function() action) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError('corrupt or truncated delta package was accepted');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

bool listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
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
