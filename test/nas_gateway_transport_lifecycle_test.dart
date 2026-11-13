import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_transport.dart';
import 'package:mimivent_app/features/local_network/wifi_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return request;
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => getUrl(url);

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

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

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

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

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
