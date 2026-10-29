import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/ble/ble_protocol.dart';

void main() {
  group('MimiVent BLE protocol', () {
    test('encodes request fields in the firmware wire format', () {
      final packet = BleProtocol.encodeRequest(
        method: 'POST',
        path: '/api/auto',
        profile: 'dev',
        replace: true,
        switchProfile: true,
      );

      expect(packet, 'POST\n/api/auto\ndev\n\n\n1\n1\n');
    });

    test('decodes v1 responses split across notifications with UTF-8 intact',
        () {
      final decoder = LegacyBleResponseDecoder();
      final bytes = utf8.encode('200\n{"message":"设备已连接"}\n');
      final split = bytes.length ~/ 2;

      expect(decoder.add(bytes.sublist(0, split)), isNull);
      final response = decoder.add(bytes.sublist(split));

      expect(response?.statusCode, 200);
      expect(response?.body, '{"message":"设备已连接"}');
    });

    test('encodes OTA offset and CRC in little-endian order', () {
      final frame = encodeOtaDataFrame(0x12345678, ascii.encode('123456789'));

      expect(frame.take(4), [0x78, 0x56, 0x34, 0x12]);
      expect(frame.skip(4).take(4), [0x26, 0x39, 0xF4, 0xCB]);
      expect(frame.skip(8), ascii.encode('123456789'));
    });

    test('rejects empty OTA chunks and offsets outside the wire range', () {
      expect(() => encodeOtaDataFrame(0, []), throwsArgumentError);
      expect(() => encodeOtaDataFrame(-1, [1]), throwsRangeError);
      expect(() => encodeOtaDataFrame(0x100000000, [1]), throwsRangeError);
    });

    test('parses V2 buffer credits and remains compatible with legacy ACKs',
        () {
      expect(
        parseOtaAcknowledgement('ACK|4096|8192|7',
            minimumOffset: 4096, totalBytes: 8192),
        7,
      );
      expect(
        parseOtaAcknowledgement('ACK|4096|8192',
            minimumOffset: 4096, totalBytes: 8192),
        isNull,
      );
      expect(
        () => parseOtaAcknowledgement('ACK|1024|8192|7',
            minimumOffset: 4096, totalBytes: 8192),
        throwsFormatException,
      );
      expect(
        () => parseOtaAcknowledgement('ACK|4096|8192|many',
            minimumOffset: 4096, totalBytes: 8192),
        throwsFormatException,
      );
    });

    test('waits until a split status and body are complete', () {
      final decoder = BleResponseDecoder();
      final bytes = utf8.encode('200\n{"ok":true}\n');
      final split = bytes.length ~/ 2;
      expect(
          decoder.add(
              _frame(1, 0, bytes.sublist(0, split),
                  total: bytes.length, checksumBytes: bytes),
              expectedRequestId: 1),
          isNull);
      final response = decoder.add(
        _frame(1, 1, bytes.sublist(split)),
        expectedRequestId: 1,
      );

      expect(response?.statusCode, 200);
      expect(response?.body, '{"ok":true}');
    });

    test('decodes a complete response delivered in one notification', () {
      final bytes = utf8.encode('409\n{"error":"PIR_HIGH"}\n');
      final response = BleResponseDecoder().add(
        _frame(1, 0, bytes, total: bytes.length),
        expectedRequestId: 1,
      );

      expect(response?.statusCode, 409);
      expect(response?.body, '{"error":"PIR_HIGH"}');
    });

    test('preserves Chinese UTF-8 text split across BLE notifications', () {
      final decoder = BleResponseDecoder();
      final bytes = utf8.encode('409\n{"error":"检测到活动"}\n');
      expect(
        decoder.add(
            _frame(1, 0, bytes.sublist(0, 16),
                total: bytes.length, checksumBytes: bytes),
            expectedRequestId: 1),
        isNull,
      );
      final response = decoder.add(
        _frame(1, 1, bytes.sublist(16)),
        expectedRequestId: 1,
      );

      expect(response?.body, '{"error":"检测到活动"}');
    });
  });
}

List<int> _frame(int requestId, int index, List<int> payload,
    {int? total, List<int>? checksumBytes}) {
  final frame = <int>[
    requestId & 0xFF,
    requestId >> 8,
    index & 0xFF,
    index >> 8,
  ];
  if (index == 0) {
    final length = total!;
    final crc = bleCrc32(checksumBytes ?? payload);
    frame.addAll([
      BleProtocol.frameVersion,
      0,
      length & 0xFF,
      (length >> 8) & 0xFF,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 24) & 0xFF,
    ]);
  }
  frame.addAll(payload);
  return frame;
}
