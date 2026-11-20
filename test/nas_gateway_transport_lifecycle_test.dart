import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_transport.dart';
import 'package:mimivent_app/features/local_network/wifi_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已授权手机列表通过 Gateway 查询并校验当前设备身份', () async {
    SharedPreferences.setMockInitialValues({
      'mimivent.nas_gateway.enabled.v1': true,
      'mimivent.nas_gateway.url.v1': 'https://192.168.2.65:8444',
      'mimivent.nas_gateway.cert_pin.v1': 'a' * 64,
    });
    final response = Completer<HttpClientResponse>();
    final client = _FakeHttpClient(response);
    final transport = NasGatewayTransport(httpClientFactory: () => client);
    final resultFuture = transport.listApps(_binding());
    await client.requestStarted.future;
    response.complete(_FakeHttpClientResponse(
        200,
        utf8.encode(jsonEncode({
          'deviceId': 'a' * 32,
          'currentAppInstanceId': 'b' * 32,
          'currentRole': 'control',
          'apps': [
            {
              'appInstanceId': 'b' * 32,
              'role': 'control',
              'name': '已加入手机',
              'revoked': false,
            },
          ],
        }))));

    final result = await resultFuture;
    expect(client.method, 'GET');
    expect(client.uri?.path, '/api/v1/devices/${'a' * 32}/apps');
    expect(client.request.fakeHeaders.values['X-App-Instance-Id'], 'b' * 32);
    expect(result['currentRole'], 'control');
    expect((result['apps'] as List).length, 1);
    transport.dispose();
  });

  test('已加入手机可撤销其他手机的 Gateway 凭据', () async {
    SharedPreferences.setMockInitialValues({
      'mimivent.nas_gateway.enabled.v1': true,
      'mimivent.nas_gateway.url.v1': 'https://192.168.2.65:8444',
      'mimivent.nas_gateway.cert_pin.v1': 'a' * 64,
    });
    final response = Completer<HttpClientResponse>();
    final client = _FakeHttpClient(response);
    final transport = NasGatewayTransport(httpClientFactory: () => client);
    final revokeFuture = transport.revokeApp(_binding(), 'c' * 32);
    await client.requestStarted.future;
    response.complete(_FakeHttpClientResponse(200, utf8.encode(jsonEncode({
      'deviceId': 'a' * 32,
      'appInstanceId': 'c' * 32,
      'revoked': true,
    }))));

    await revokeFuture;
    expect(client.method, 'DELETE');
    expect(client.uri?.path, '/api/v1/devices/${'a' * 32}/apps/${'c' * 32}');
    transport.dispose();
  });

  test('设备拒绝 NAS 服务 token 时给出授权不同步和恢复提示', () async {
    SharedPreferences.setMockInitialValues({
      'mimivent.nas_gateway.enabled.v1': true,
      'mimivent.nas_gateway.url.v1': 'https://192.168.2.65:8444',
      'mimivent.nas_gateway.cert_pin.v1': 'a' * 64,
    });
    final response = Completer<HttpClientResponse>();
    final client = _FakeHttpClient(response);
    final transport = NasGatewayTransport(httpClientFactory: () => client);
    final read =
        transport.readPath(_binding(), '/api/stats?mode=today&limit=4');
    await client.requestStarted.future;
    response.complete(_FakeHttpClientResponse(
      200,
      utf8.encode(jsonEncode({
        'schemaVersion': 1,
        'deviceId': 'a' * 32,
        'statusCode': 401,
        'body': {'error': 'BINDING_INVALID'},
      })),
    ));

    await expectLater(
      read,
      throwsA(isA<NasGatewayException>()
          .having((error) => error.code, 'code', 'SERVICE_CREDENTIAL_MISMATCH')
          .having((error) => error.message, 'message', contains('重新加入'))),
    );
    expect(client.method, 'POST');
    transport.dispose();
  });

  test('网关配置变化后关闭旧连接并丢弃迟到的旧配置响应', () async {
    SharedPreferences.setMockInitialValues({
      'mimivent.nas_gateway.enabled.v1': true,
      'mimivent.nas_gateway.url.v1': NasGatewayTransport.defaultUrl,
      'mimivent.nas_gateway.cert_pin.v1': 'a' * 64,
    });
    final response = Completer<HttpClientResponse>();
    final client = _FakeHttpClient(response);
    final transport = NasGatewayTransport(httpClientFactory: () => client);
    final configurationTransport = NasGatewayTransport();

    final read = transport.tryReadState(_binding());
    await client.requestStarted.future;
    await configurationTransport.saveConfig(
      url: 'https://192.168.2.66:8444',
      certificatePin: 'b' * 64,
      enabled: true,
    );
    response.complete(_FakeHttpClientResponse(200, utf8.encode('{}')));

    expect(await read, isNull);
    expect(client.forceClosed, isTrue);
    transport.dispose();
    configurationTransport.dispose();
  });

  test('网关配置变化中断已发送的控制时保留结果未知', () async {
    SharedPreferences.setMockInitialValues({
      'mimivent.nas_gateway.enabled.v1': true,
      'mimivent.nas_gateway.url.v1': NasGatewayTransport.defaultUrl,
      'mimivent.nas_gateway.cert_pin.v1': 'a' * 64,
    });
    final response = Completer<HttpClientResponse>();
    final client = _FakeHttpClient(response);
    final transport = NasGatewayTransport(httpClientFactory: () => client);
    final configurationTransport = NasGatewayTransport();

    final write = transport.tryWrite(
      _binding(),
      path: '/api/auto',
      body: 'profile=production',
      requestId: 'request-1',
    );
    await client.request.requestClosed.future;
    await configurationTransport.saveConfig(
      url: 'https://192.168.2.66:8444',
      certificatePin: 'b' * 64,
      enabled: true,
    );
    response.complete(_FakeHttpClientResponse(
      200,
      utf8.encode(jsonEncode({
        'requestId': 'request-1',
        'httpStatus': 200,
        'body': {'ok': true},
      })),
    ));

    final result = await write;
    expect(result?.body['resultUnknown'], isTrue);
    expect(result?.body['commandPublished'], isNull);
    expect(client.forceClosed, isTrue);
    transport.dispose();
    configurationTransport.dispose();
  });
}

WifiBinding _binding() => WifiBinding(
      deviceId: 'a' * 32,
      tokenId: 'b' * 32,
      token: 'c' * 43,
      pin: 'd' * 64,
      host: '192.168.2.5',
      clientId: 'test-client',
      state: 'active',
    );

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(Completer<HttpClientResponse> response)
      : request = _FakeHttpClientRequest(response);

  final _FakeHttpClientRequest request;
  final requestStarted = Completer<void>();
  bool forceClosed = false;
  String? method;
  Uri? uri;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    method = 'GET';
    uri = url;
    if (!requestStarted.isCompleted) requestStarted.complete();
    return request;
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    method = 'POST';
    uri = url;
    if (!requestStarted.isCompleted) requestStarted.complete();
    return request;
  }

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) async {
    method = 'DELETE';
    uri = url;
    if (!requestStarted.isCompleted) requestStarted.complete();
    return request;
  }

  @override
  void close({bool force = false}) {
    forceClosed = force;
  }

  @override
  set connectionTimeout(Duration? value) {}

  @override
  set badCertificateCallback(BadCertificateCallback? callback) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._response);

  final Completer<HttpClientResponse> _response;
  final requestClosed = Completer<void>();

  final _FakeHttpHeaders _headers = _FakeHttpHeaders();
  _FakeHttpHeaders get fakeHeaders => _headers;

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() {
    if (!requestClosed.isCompleted) requestClosed.complete();
    return _response.future;
  }

  @override
  void write(Object? object) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  ContentType? contentType;
  final Map<String, Object> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, List<int> bytes)
      : _stream = Stream<List<int>>.value(bytes);

  final Stream<List<int>> _stream;

  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
