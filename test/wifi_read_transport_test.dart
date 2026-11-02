import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/wifi_control/wifi_binding.dart';
import 'package:mimivent_app/features/wifi_control/wifi_read_transport.dart';

class FakeConnection implements WifiSecureConnection {
  int requests = 0;
  bool closed = false;
  @override
  List<int> certificateDer = [1, 2, 3];
  List<int> response = [];
  @override
  Future<List<int>> request(String request) async {
    requests++;
    return response;
  }

  @override
  void close() {
    closed = true;
  }
}

WifiBinding binding(String pin) => WifiBinding(
    deviceId: 'a' * 32,
    tokenId: 'b' * 32,
    token: 'c' * 43,
    pin: pin,
    host: '192.168.2.5',
    clientId: 'phone',
    state: 'active');
List<int> response(int code, Map<String, dynamic> body) {
  final data = utf8.encode(jsonEncode(body));
  return [
    ...ascii.encode(
        'HTTP/1.1 $code Test\r\nContent-Length: ${data.length}\r\n\r\n'),
    ...data
  ];
}

void main() {
  test('实际证书 pin 不匹配时绝不发送 token，即使 TLS 建连成功', () async {
    final socket = FakeConnection();
    final transport = WifiReadTransport(connect: (_, __) async => socket);
    await expectLater(
        transport.read(binding('0' * 64)),
        throwsA(isA<WifiReadException>()
            .having((e) => e.code, 'code', 'PIN_MISMATCH')));
    expect(socket.requests, 0);
    expect(socket.closed, true);
  });
  test('匹配 pin 后核验设备和 token 身份', () async {
    final socket = FakeConnection()
      ..response = response(200, {
        'deviceId': 'a' * 32,
        'tokenId': 'b' * 32,
        'bindingState': 'active',
        'protocolVersion': 1
      });
    final transport = WifiReadTransport(connect: (_, __) async => socket);
    final pin = sha256.convert(socket.certificateDer).toString();
    expect((await transport.read(binding(pin)))['bindingState'], 'active');
    expect(socket.requests, 1);
    expect(socket.closed, true);
  });
  test('不跟随重定向；401 与 403 不混为连接错误', () async {
    for (final code in [302, 401, 403]) {
      final socket = FakeConnection()..response = response(code, {});
      final transport = WifiReadTransport(connect: (_, __) async => socket);
      await expectLater(
          transport
              .read(binding(sha256.convert(socket.certificateDer).toString())),
          throwsA(isA<WifiReadException>().having(
              (e) => e.code,
              'code',
              {
                302: 'HTTP_302',
                401: 'BINDING_INVALID',
                403: 'PERMISSION_DENIED'
              }[code])));
      expect(socket.requests, 1);
      expect(socket.closed, true);
    }
  });
  test('身份不同和重复长度响应拒绝', () async {
    final socket = FakeConnection()
      ..response = response(200, {
        'deviceId': 'd' * 32,
        'tokenId': 'b' * 32,
        'bindingState': 'active',
        'protocolVersion': 1
      });
    final transport = WifiReadTransport(connect: (_, __) async => socket);
    await expectLater(
        transport
            .read(binding(sha256.convert(socket.certificateDer).toString())),
        throwsA(isA<WifiReadException>()
            .having((e) => e.code, 'code', 'DEVICE_MISMATCH')));
    expect(
        () => WifiReadTransport.parseResponse(ascii.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}')),
        throwsA(isA<WifiReadException>()));
  });
  test('持久记录拒绝头注入与未知版本', () {
    final json = binding('0' * 64).toJson();
    expect(WifiBinding.fromJson(json).host, '192.168.2.5');
    expect(
        () =>
            WifiBinding.fromJson({...json, 'token': '\r\nAuthorization: bad'}),
        throwsFormatException);
    expect(() => WifiBinding.fromJson({...json, 'version': 2}),
        throwsFormatException);
  });
}
