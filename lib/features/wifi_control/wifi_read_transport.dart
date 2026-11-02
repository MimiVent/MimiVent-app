import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'wifi_binding.dart';

class WifiReadException implements Exception {
  const WifiReadException(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

abstract class WifiSecureConnection {
  List<int> get certificateDer;
  Future<List<int>> request(String request);
  void close();
}

class _Connection implements WifiSecureConnection {
  _Connection(this.socket);
  final SecureSocket socket;
  @override
  List<int> get certificateDer => socket.peerCertificate?.der ?? const [];
  @override
  void close() => socket.destroy();
  @override
  Future<List<int>> request(String request) async {
    socket.add(utf8.encode(request));
    await socket.flush().timeout(const Duration(seconds: 10));
    final result = Completer<List<int>>();
    final bytes = <int>[];
    final subscription = socket.listen((chunk) {
      if (result.isCompleted) return;
      bytes.addAll(chunk);
      if (bytes.length > 12288) {
        result.completeError(
            const WifiReadException('RESPONSE_TOO_LARGE', '设备响应超过上限'));
        return;
      }
      final header = latin1.decode(bytes);
      final end = header.indexOf('\r\n\r\n');
      if (end < 0) {
        if (bytes.length > 4096) {
          result.completeError(
              const WifiReadException('HEADER_TOO_LARGE', '响应头超过上限'));
        }
        return;
      }
      final lengths = RegExp(r'^content-length:\s*(\d+)\s*$',
              caseSensitive: false, multiLine: true)
          .allMatches(header.substring(0, end).replaceAll('\r', ''));
      if (lengths.length != 1) {
        result
            .completeError(const WifiReadException('HTTP_FORMAT', '设备响应长度无效'));
        return;
      }
      final length = int.parse(lengths.single[1]!);
      if (length > 8192) {
        result.completeError(
            const WifiReadException('RESPONSE_TOO_LARGE', '设备响应超过上限'));
        return;
      }
      if (bytes.length >= end + 4 + length) {
        result.complete(List<int>.from(bytes));
      }
    }, onError: (Object e) {
      if (!result.isCompleted) result.completeError(e);
    }, onDone: () {
      if (!result.isCompleted) {
        result.completeError(
            const WifiReadException('HTTP_INCOMPLETE', '设备响应不完整'));
      }
    });
    try {
      return await result.future.timeout(const Duration(seconds: 10));
    } finally {
      await subscription.cancel();
    }
  }
}

class WifiHttpResult {
  const WifiHttpResult(this.statusCode, this.body);
  final int statusCode;
  final Map<String, dynamic> body;
}

typedef WifiConnector = Future<WifiSecureConnection> Function(
    String host, int port);

class WifiReadTransport {
  WifiReadTransport({WifiConnector? connect}) : _connect = connect ?? _open;
  final WifiConnector _connect;
  static Future<WifiSecureConnection> _open(String host, int port) async =>
      _Connection(await SecureSocket.connect(host, port,
          timeout: const Duration(seconds: 8),
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true,
          supportedProtocols: const ['http/1.1']));

  Future<Map<String, dynamic>> read(WifiBinding binding) async {
    if (binding.state == 'blocked') {
      throw const WifiReadException('IDENTITY_BLOCKED', '设备身份异常，请经蓝牙核查后重新绑定');
    }
    // 同时校验本地字段，禁止外部输入进入 HTTP 头。
    WifiBinding.fromJson(binding.toJson());
    final connection = await _connect(binding.host, 8443);
    try {
      final der = connection.certificateDer;
      if (der.isEmpty || sha256.convert(der).toString() != binding.pin) {
        throw const WifiReadException(
            'PIN_MISMATCH', '设备证书不匹配，已停止 WiFi 访问，请经蓝牙核查');
      }
      // 无论系统 CA 是否认可证书，都在发送 Bearer 前检查实际 DER pin。
      final raw = await connection.request(
          'GET /api/status HTTP/1.1\r\nHost: ${binding.host}:8443\r\nAuthorization: Bearer ${binding.token}\r\nConnection: close\r\nAccept: application/json\r\n\r\n');
      final result = parseResponse(raw);
      if (result['deviceId'] != binding.deviceId ||
          result['tokenId'] != binding.tokenId) {
        throw const WifiReadException('DEVICE_MISMATCH', '设备或绑定身份不匹配，请经蓝牙核查');
      }
      if (result['protocolVersion'] != 1 ||
          !['pending', 'active'].contains(result['bindingState'])) {
        throw const WifiReadException('PROTOCOL', '设备只读协议无效');
      }
      return result;
    } finally {
      connection.close();
    }
  }

  Future<WifiHttpResult> write(
    WifiBinding binding, {
    required String path,
    required String body,
    required String requestId,
  }) async {
    if (binding.state != 'active') {
      throw const WifiReadException('BINDING_NOT_ACTIVE', '当前绑定尚未生效，请先完成绑定');
    }
    if (!RegExp(r'^/api/[a-z0-9-]+$').hasMatch(path)) {
      throw const WifiReadException('INVALID_PATH', '控制路径无效');
    }
    if (!RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(requestId)) {
      throw const WifiReadException('INVALID_REQUEST_ID', '请求标识无效');
    }
    WifiBinding.fromJson(binding.toJson());
    final connection = await _connect(binding.host, 8443);
    try {
      final der = connection.certificateDer;
      if (der.isEmpty || sha256.convert(der).toString() != binding.pin) {
        throw const WifiReadException(
            'PIN_MISMATCH', '设备证书不匹配，已停止 WiFi 访问，请经蓝牙核查');
      }
      final raw = await connection
          .request('POST $path HTTP/1.1\r\nHost: ${binding.host}:8443\r\n'
              'Authorization: Bearer ${binding.token}\r\n'
              'X-Request-Id: $requestId\r\n'
              'Content-Type: application/x-www-form-urlencoded\r\n'
              'Content-Length: ${utf8.encode(body).length}\r\n'
              'Connection: close\r\nAccept: application/json\r\n\r\n$body');
      final result = _parseAny(raw);
      if (result.statusCode == 401) {
        throw const WifiReadException(
            'BINDING_INVALID', '设备绑定已失效，请通过蓝牙检查或重新绑定');
      }
      if (result.statusCode == 403) {
        throw const WifiReadException('PERMISSION_DENIED', '当前绑定没有访问权限');
      }
      if (result.statusCode == 429) {
        throw const WifiReadException('RATE_LIMITED', '操作过于频繁，请稍后重试');
      }
      if (result.statusCode == 503) {
        if (result.body['error'] == 'DEDUP_UNAVAILABLE') {
          throw const WifiReadException(
              'DEDUP_UNAVAILABLE', '设备存储不足，无法安全去重，暂时不能执行控制');
        }
        throw const WifiReadException('RESOURCE_BUSY', '设备正在升级或繁忙，请稍后重试');
      }
      if (result.statusCode == 423) {
        if (result.body['error'] == 'WIFI_IN_USE') {
          throw const WifiReadException(
              'WIFI_IN_USE', 'WiFi 正被另一台手机控制，请使用蓝牙或稍后重试');
        }
        throw const WifiReadException('OTA_BUSY', '设备正在升级，暂时不能控制');
      }
      return result;
    } finally {
      connection.close();
    }
  }

  Future<Map<String, dynamic>> readPath(
    WifiBinding binding,
    String path,
  ) async {
    if (!RegExp(r'^/api/[a-z]+(\?[A-Za-z0-9_=&.-]{0,120})?$').hasMatch(path)) {
      throw const WifiReadException('INVALID_PATH', '读取路径无效');
    }
    WifiBinding.fromJson(binding.toJson());
    final connection = await _connect(binding.host, 8443);
    try {
      final der = connection.certificateDer;
      if (der.isEmpty || sha256.convert(der).toString() != binding.pin) {
        throw const WifiReadException(
            'PIN_MISMATCH', '设备证书不匹配，已停止 WiFi 访问，请经蓝牙核查');
      }
      final raw = await connection
          .request('GET $path HTTP/1.1\r\nHost: ${binding.host}:8443\r\n'
              'Authorization: Bearer ${binding.token}\r\n'
              'Connection: close\r\nAccept: application/json\r\n\r\n');
      final result = _parseAny(raw);
      if (result.statusCode == 401) {
        throw const WifiReadException(
            'BINDING_INVALID', '设备绑定已失效，请通过蓝牙检查或重新绑定');
      }
      if (result.statusCode != 200) {
        final code =
            result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
        throw WifiReadException(code, '设备未返回数据（$code）');
      }
      return result.body;
    } finally {
      connection.close();
    }
  }

  /// 主动释放 WiFi 租约，让另一台手机可以接管 WiFi 主控。
  Future<void> releaseLease(WifiBinding binding) async {
    await write(binding,
        path: '/api/lease',
        body: 'action=release',
        requestId: _leaseRequestId());
  }

  static String _leaseRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<WifiHttpResult> queryRequest(
    WifiBinding binding,
    String requestId,
  ) async {
    if (!RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(requestId)) {
      throw const WifiReadException('INVALID_REQUEST_ID', '请求标识无效');
    }
    WifiBinding.fromJson(binding.toJson());
    final connection = await _connect(binding.host, 8443);
    try {
      final der = connection.certificateDer;
      if (der.isEmpty || sha256.convert(der).toString() != binding.pin) {
        throw const WifiReadException(
            'PIN_MISMATCH', '设备证书不匹配，已停止 WiFi 访问，请经蓝牙核查');
      }
      final raw = await connection.request(
          'GET /api/requests/$requestId HTTP/1.1\r\nHost: ${binding.host}:8443\r\n'
          'Authorization: Bearer ${binding.token}\r\n'
          'Connection: close\r\nAccept: application/json\r\n\r\n');
      return _parseAny(raw);
    } finally {
      connection.close();
    }
  }

  static WifiHttpResult _parseAny(List<int> raw) {
    if (raw.length > 12288) {
      throw const WifiReadException('RESPONSE_TOO_LARGE', '响应超过上限');
    }
    final text = latin1.decode(raw);
    final end = text.indexOf('\r\n\r\n');
    if (end < 0 || end > 4096) {
      throw const WifiReadException('HTTP_FORMAT', '响应头无效');
    }
    final lines = text.substring(0, end).split('\r\n');
    final status =
        RegExp(r'^HTTP/1\.[01] (\d{3})(?: |$)').firstMatch(lines.first);
    if (status == null) {
      throw const WifiReadException('HTTP_FORMAT', 'HTTP 状态无效');
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon < 1) throw const WifiReadException('HTTP_FORMAT', '响应头无效');
      final key = line.substring(0, colon).toLowerCase(),
          value = line.substring(colon + 1).trim();
      if (headers.containsKey(key)) {
        throw const WifiReadException('HTTP_FORMAT', '重复响应头');
      }
      headers[key] = value;
    }
    final length = int.tryParse(headers['content-length'] ?? '');
    if (headers.containsKey('transfer-encoding') ||
        length == null ||
        length < 0 ||
        length > 8192 ||
        raw.length != end + 4 + length) {
      throw const WifiReadException('HTTP_FORMAT', '响应正文长度无效');
    }
    final code = int.parse(status[1]!);
    final body = jsonDecode(utf8.decode(raw.sublist(end + 4)));
    if (body is! Map<String, dynamic>) {
      throw const WifiReadException('HTTP_FORMAT', '设备响应格式无效');
    }
    if (code == 423) {
      if (body['error'] == 'WIFI_IN_USE') {
        throw const WifiReadException(
            'WIFI_IN_USE', 'WiFi 正被另一台手机控制，请使用蓝牙或稍后重试');
      }
      throw const WifiReadException('OTA_BUSY', '设备正在升级，暂时不能控制');
    }
    return WifiHttpResult(code, body);
  }

  static Map<String, dynamic> parseResponse(List<int> raw) {
    if (raw.length > 6144) {
      throw const WifiReadException('RESPONSE_TOO_LARGE', '响应超过上限');
    }
    final text = latin1.decode(raw);
    final end = text.indexOf('\r\n\r\n');
    if (end < 0 || end > 4096) {
      throw const WifiReadException('HTTP_FORMAT', '响应头无效');
    }
    final lines = text.substring(0, end).split('\r\n');
    final status =
        RegExp(r'^HTTP/1\.[01] (\d{3})(?: |$)').firstMatch(lines.first);
    if (status == null) {
      throw const WifiReadException('HTTP_FORMAT', 'HTTP 状态无效');
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon < 1) throw const WifiReadException('HTTP_FORMAT', '响应头无效');
      final key = line.substring(0, colon).toLowerCase(),
          value = line.substring(colon + 1).trim();
      if (headers.containsKey(key)) {
        throw const WifiReadException('HTTP_FORMAT', '重复响应头');
      }
      headers[key] = value;
    }
    final length = int.tryParse(headers['content-length'] ?? '');
    if (headers.containsKey('transfer-encoding') ||
        length == null ||
        length < 0 ||
        length > 2048 ||
        raw.length != end + 4 + length) {
      throw const WifiReadException('HTTP_FORMAT', '响应正文长度无效');
    }
    final code = int.parse(status[1]!);
    final body = jsonDecode(utf8.decode(raw.sublist(end + 4)));
    if (body is! Map<String, dynamic>) {
      throw const WifiReadException('HTTP_FORMAT', '设备状态格式无效');
    }
    if (code != 200) {
      if (code == 401) {
        throw const WifiReadException(
            'BINDING_INVALID', '设备绑定已失效，请通过蓝牙检查或重新绑定');
      }
      if (code == 403) {
        throw const WifiReadException('PERMISSION_DENIED', '当前绑定没有访问权限');
      }
      if (code == 429) {
        throw const WifiReadException('RATE_LIMITED', '读取过于频繁，请稍后重试');
      }
      if (code == 503) {
        throw const WifiReadException(
            'RESOURCE_BUSY', '设备正在升级、繁忙或状态暂不可读，请稍后重试');
      }
      if (code == 423) {
        final error = body['error']?.toString();
        if (error == 'WIFI_IN_USE') {
          throw const WifiReadException(
              'WIFI_IN_USE', 'WiFi 正被另一台手机控制，请使用蓝牙或稍后重试');
        }
        throw const WifiReadException('OTA_BUSY', '设备正在升级，暂时不能控制');
      }
      throw WifiReadException('HTTP_$code', '设备返回 HTTP $code，未跟随重定向');
    }
    return body;
  }
}
