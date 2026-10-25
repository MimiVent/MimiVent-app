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

    test('waits until a split status and body are complete', () {
      final decoder = BleResponseDecoder();
      expect(decoder.add(utf8.encode('20')), isNull);
      expect(decoder.add(utf8.encode('0\n{"ok":')), isNull);
      final response = decoder.add(utf8.encode('true}\n'));

      expect(response?.statusCode, 200);
      expect(response?.body, '{"ok":true}');
    });

    test('decodes a complete response delivered in one notification', () {
      final response =
          BleResponseDecoder().add(utf8.encode('409\n{"error":"PIR_HIGH"}\n'));

      expect(response?.statusCode, 409);
      expect(response?.body, '{"error":"PIR_HIGH"}');
    });

    test('preserves Chinese UTF-8 text split across BLE notifications', () {
      final decoder = BleResponseDecoder();
      final bytes = utf8.encode('409\n{"error":"检测到活动"}\n');
      expect(decoder.add(bytes.sublist(0, 16)), isNull);
      final response = decoder.add(bytes.sublist(16));

      expect(response?.body, '{"error":"检测到活动"}');
    });
  });
}
