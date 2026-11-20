import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'wifi_binding.dart';
import 'nas_gateway_models.dart';

/// 通过家庭 NAS HTTP 网关转发控制请求；App 不直接持有 MQTT Broker 凭据。
class NasGatewayTransport {
  static const _urlKey = 'mimivent.nas_gateway.url.v1';
  static const _pinKey = 'mimivent.nas_gateway.cert_pin.v1';
  static const _enabledKey = 'mimivent.nas_gateway.enabled.v1';
  // NAS 地址因家庭网络而异；未配置时保持空值，避免把某一用户的 IP
  // 当成所有新用户的默认地址。
  static const defaultUrl = '';
  static const _timeout = Duration(seconds: 4);
  // Gateway 最长等待设备 ACK 6 秒；保留额外余量，避免 App 先于 Gateway
  // 把仍在执行的请求判成未知。
  static const _controlResponseTimeout = Duration(seconds: 8);
  static final Set<HttpClient> _openClients = <HttpClient>{};
  static int _configurationGeneration = 0;
  static bool _configurationUpdating = false;

  NasGatewayTransport({HttpClient Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory ?? _createHttpClient;

  final HttpClient Function() _httpClientFactory;

  HttpClient? _client;
  String? _clientKey;
  int _clientGeneration = -1;
  bool _disposed = false;

  static HttpClient _createHttpClient() =>
      HttpClient(context: SecurityContext(withTrustedRoots: false));

  bool _isCurrentConfiguration(int generation) =>
      !_disposed &&
      !_configurationUpdating &&
      generation == _configurationGeneration;

  int? _captureConfigurationGeneration() {
    if (_disposed || _configurationUpdating) return null;
    return _configurationGeneration;
  }

  NasGatewayException _configurationChanged() => const NasGatewayException(
        'GATEWAY_CONFIG_CHANGED',
        'NAS 网关配置已变化，请重试',
      );

  HttpClient _httpClient(Uri uri, String certificatePin) {
    final key = '${uri.host}:${uri.port}:$certificatePin';
    if (_client != null &&
        _clientGeneration == _configurationGeneration &&
        _clientKey == key) {
      return _client!;
    }

    _closeClient(force: true);
    final client = _httpClientFactory()..connectionTimeout = _timeout;
    client.badCertificateCallback = (certificate, host, port) =>
        host == uri.host &&
        port == uri.port &&
        sha256.convert(certificate.der).toString() == certificatePin;
    _client = client;
    _clientKey = key;
    _clientGeneration = _configurationGeneration;
    _openClients.add(client);
    return client;
  }

  void _closeClient({required bool force}) {
    final client = _client;
    if (client != null) _openClients.remove(client);
    client?.close(force: force);
    _client = null;
    _clientKey = null;
    _clientGeneration = -1;
  }

  static void _invalidateAllClients() {
    _configurationGeneration++;
    for (final client in _openClients.toList()) {
      client.close(force: true);
    }
    _openClients.clear();
  }

  void dispose() {
    _disposed = true;
    _closeClient(force: true);
  }

  Future<String> loadBaseUrl() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_urlKey) ?? defaultUrl;
  }

  /// NAS Gateway 通道是否已启用。
  Future<bool> isEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? false;
  }

  Future<Map<String, String>> loadConfig() async {
    final preferences = await SharedPreferences.getInstance();
    return {
      'url': preferences.getString(_urlKey) ?? defaultUrl,
      'certificatePin': preferences.getString(_pinKey) ?? '',
      'enabled': (preferences.getBool(_enabledKey) ?? false).toString(),
    };
  }

  Future<void> saveConfig({
    required String url,
    required String certificatePin,
    required bool enabled,
  }) async {
    final value = url.trim();
    final pin = certificatePin.trim().toLowerCase();
    if (enabled && value.isEmpty) {
      throw const FormatException('请填写 NAS 网关 HTTPS 地址');
    }
    if (value.isNotEmpty) {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !uri.hasAuthority ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.query.isNotEmpty ||
          uri.fragment.isNotEmpty ||
          (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
        throw const FormatException(
            '地址须为有效 HTTPS URL，例如 https://192.168.1.20:8444');
      }
    }
    if (pin.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)) {
      throw const FormatException('证书指纹须为 64 位十六进制 SHA-256');
    }
    if (enabled && pin.isEmpty) {
      throw const FormatException('请填写 64 位 HTTPS 证书 SHA-256 指纹');
    }
    // 跨 Transport 实例使旧请求失效，避免旧 NAS/证书的迟到响应污染当前会话。
    _configurationUpdating = true;
    _invalidateAllClients();
    try {
      final preferences = await SharedPreferences.getInstance();
      if (value.isEmpty) {
        await preferences.remove(_urlKey);
      } else {
        final uri = Uri.parse(value);
        await preferences.setString(_urlKey, uri.replace(path: '').toString());
      }
      if (pin.isEmpty) {
        await preferences.remove(_pinKey);
      } else {
        await preferences.setString(_pinKey, pin);
      }
      await preferences.setBool(_enabledKey, enabled);
    } finally {
      _configurationGeneration++;
      _configurationUpdating = false;
    }
  }

  /// 只查询网关缓存，不能通过此接口重发控制。
  /// 网关不可达或未启用返回 null；调用方必须提示用户改用蓝牙。
  Future<NasGatewayHttpResult?> tryReadState(WifiBinding binding) async {
    final generation = _captureConfigurationGeneration();
    if (generation == null) return null;
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool(_enabledKey) ?? false)) return null;
    final baseUrl = await loadBaseUrl();
    final certificatePin = preferences.getString(_pinKey) ?? '';
    if (!_isCurrentConfiguration(generation)) return null;
    final uri =
        Uri.parse(baseUrl).resolve('/api/v1/devices/${binding.deviceId}/state');
    final client = _httpClient(uri, certificatePin);
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      final response = await request.close().timeout(_timeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 8192) {
          throw const FormatException('NAS 网关响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(_timeout);
      if (!_isCurrentConfiguration(generation)) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      return NasGatewayHttpResult(response.statusCode, decoded);
    } catch (error) {
      if (!_isCurrentConfiguration(generation)) return null;
      debugPrint('[gw] readState failed: $error');
      return null;
    }
  }

  // ---- P2 单服务授权（Gateway 用 AuthorizationStore 管理窗口/会话/凭据）----
  Future<Map<String, dynamic>> _setupRequest(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    String method = 'POST',
  }) async {
    final config = await loadConfig();
    // 首次配置时网关还未启用（enabled 开关用于“是否走网关控制”），
    // 这里只要求已填写地址与证书指纹。
    final baseUrl = config['url'] ?? '';
    if (baseUrl.isEmpty) {
      throw const NasGatewayException(
          'GATEWAY_NOT_CONFIGURED', '请先填写 NAS 网关地址');
    }
    final uri = Uri.parse(baseUrl).resolve(path);
    final client = _httpClient(uri, config['certificatePin']!);
    try {
      final request = method == 'GET'
          ? await client.getUrl(uri).timeout(_timeout)
          : await client.postUrl(uri).timeout(_timeout);
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(_timeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 8192) {
          throw const FormatException('网关响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(_timeout);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const NasGatewayException('INVALID_RESPONSE', '网关响应格式无效');
      }
      if (response.statusCode != 200) {
        final code = decoded['error']?.toString() ?? 'SETUP_FAILED';
        final message = code == 'SERVICE_CREDENTIAL_REJECTED'
            ? 'NAS 仍保留旧的手机授权，未能接受新服务凭据。请更新 NAS Gateway 后，在蓝牙连接状态下重试直接配置。'
            : code == 'SETUP_WINDOW_INVALID_OR_EXPIRED'
                ? 'NAS 配置窗口已过期，请重新点击直接配置。'
                : '网关拒绝：$code';
        throw NasGatewayException(code, message);
      }
      return decoded;
    } on NasGatewayException {
      rethrow;
    } catch (error) {
      throw NasGatewayException('SETUP_UNAVAILABLE', '无法连接 NAS 网关：$error');
    }
  }

  /// 已加入服务的手机生成邀请码（24 小时有效，一次性）。
  Future<Map<String, dynamic>> createInvite(WifiBinding binding) async {
    final config = await loadConfig();
    final baseUrl = config['url'] ?? '';
    if (baseUrl.isEmpty) {
      throw const NasGatewayException(
          'GATEWAY_NOT_CONFIGURED', '请先填写 NAS 网关地址');
    }
    final uri =
        Uri.parse(baseUrl).resolve('/api/v1/devices/${binding.deviceId}/apps');
    final client = _httpClient(uri, config['certificatePin']!);
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      request.write('{}');
      final response = await request.close().timeout(_timeout);
      final text =
          await response.transform(utf8.decoder).join().timeout(_timeout);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const NasGatewayException('INVALID_RESPONSE', '网关响应格式无效');
      }
      if (response.statusCode != 200) {
        throw NasGatewayException(
          decoded['error']?.toString() ?? 'INVITE_FAILED',
          '生成邀请码失败：${decoded['error'] ?? response.statusCode}',
        );
      }
      return decoded;
    } on NasGatewayException {
      rethrow;
    } catch (error) {
      throw NasGatewayException('INVITE_UNAVAILABLE', '无法连接网关：$error');
    }
  }

  /// 从 Gateway 查询所有手机凭据。手机管理不依赖 BLE，也不读取设备端旧槽位。
  Future<Map<String, dynamic>> listApps(WifiBinding binding) async {
    final generation = _captureConfigurationGeneration();
    if (generation == null) throw _configurationChanged();
    final config = await loadConfig();
    if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
    final baseUrl = config['url'] ?? '';
    if (baseUrl.isEmpty) {
      throw const NasGatewayException('GATEWAY_NOT_CONFIGURED', '请先配置 NAS 网关');
    }
    final uri =
        Uri.parse(baseUrl).resolve('/api/v1/devices/${binding.deviceId}/apps');
    final client = _httpClient(uri, config['certificatePin'] ?? '');
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      final response = await request.close().timeout(_timeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 8192) {
          throw const FormatException('手机列表响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(_timeout);
      if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const NasGatewayException('INVALID_RESPONSE', '手机列表响应格式无效');
      }
      if (response.statusCode != HttpStatus.ok) {
        final code = decoded['error']?.toString() ?? 'APP_LIST_FAILED';
        throw NasGatewayException(code, _appManagementError(code));
      }
      final apps = decoded['apps'];
      if (decoded['deviceId'] != binding.deviceId ||
          decoded['currentAppInstanceId'] != binding.tokenId ||
          !const ['admin', 'control'].contains(decoded['currentRole']) ||
          apps is! List ||
          apps.any((item) =>
              item is! Map<String, dynamic> ||
              item['appInstanceId'] is! String ||
              !RegExp(r'^[0-9a-f]{32}$')
                  .hasMatch(item['appInstanceId'] as String) ||
              item['name'] is! String ||
              !const ['admin', 'control'].contains(item['role']) ||
              item['revoked'] is! bool)) {
        throw const NasGatewayException('INVALID_RESPONSE', '手机列表缺少有效的授权信息');
      }
      return decoded;
    } on NasGatewayException {
      rethrow;
    } catch (error) {
      if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
      throw NasGatewayException('APP_LIST_UNAVAILABLE', '无法读取已授权手机：$error');
    }
  }

  /// 撤销某个 App 安装实例的 Gateway 凭据，不改变设备服务授权。
  Future<void> revokeApp(WifiBinding binding, String appInstanceId) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(appInstanceId)) {
      throw const NasGatewayException('INVALID_APP_INSTANCE', '手机授权标识无效');
    }
    final generation = _captureConfigurationGeneration();
    if (generation == null) throw _configurationChanged();
    final config = await loadConfig();
    if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
    final baseUrl = config['url'] ?? '';
    if (baseUrl.isEmpty) {
      throw const NasGatewayException('GATEWAY_NOT_CONFIGURED', '请先配置 NAS 网关');
    }
    final uri = Uri.parse(baseUrl)
        .resolve('/api/v1/devices/${binding.deviceId}/apps/$appInstanceId');
    final client = _httpClient(uri, config['certificatePin'] ?? '');
    try {
      final request = await client.deleteUrl(uri).timeout(_timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      final response = await request.close().timeout(_timeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 8192) {
          throw const FormatException('撤销响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(_timeout);
      if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const NasGatewayException('INVALID_RESPONSE', '撤销响应格式无效');
      }
      if (response.statusCode != HttpStatus.ok ||
          decoded['deviceId'] != binding.deviceId ||
          decoded['appInstanceId'] != appInstanceId ||
          decoded['revoked'] != true) {
        final code = decoded['error']?.toString() ?? 'APP_REVOKE_FAILED';
        throw NasGatewayException(code, _appManagementError(code));
      }
    } on NasGatewayException {
      rethrow;
    } catch (error) {
      if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
      throw NasGatewayException('APP_REVOKE_UNAVAILABLE', '撤销手机授权失败：$error');
    }
  }

  String _appManagementError(String code) =>
      const {
        'ADMIN_REQUIRED': '当前 NAS Gateway 仍要求管理员权限，请更新 Gateway 后重试',
        'LAST_ADMIN_CANNOT_REVOKE': '当前 NAS Gateway 仍启用管理员限制，请更新 Gateway 后重试',
        'CANNOT_REVOKE_SELF': '不能撤销当前手机自己的 NAS 授权',
        'APP_NOT_FOUND': '该手机授权已不存在或已被撤销',
        'INVALID_BEARER': '当前手机凭据已失效，请重新加入服务',
      }[code] ??
      '网关手机管理失败（$code）';

  /// 新手机用邀请码兑换自己的访问凭据；不需要设备蓝牙。
  Future<Map<String, dynamic>> redeemInvite({
    required String inviteCode,
    required String appInstanceId,
    required String name,
  }) =>
      _setupRequest('/api/v1/invites/redeem',
          body: {'inviteCode': inviteCode, 'name': name},
          headers: {'x-app-instance-id': appInstanceId});

  /// 清除 Gateway 侧该设备的全部授权（服务凭据 + 所有手机凭据）。
  /// 设备侧清除服务授权后必须同步调用，否则旧 admin 会阻塞重新配置。
  Future<bool> resetDeviceAuth(WifiBinding binding) async {
    final config = await loadConfig();
    final baseUrl = config['url'] ?? '';
    if (baseUrl.isEmpty) return false;
    final uri =
        Uri.parse(baseUrl).resolve('/api/v1/devices/${binding.deviceId}/reset');
    final client = _httpClient(uri, config['certificatePin']!);
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      request.write('{}');
      final response = await request.close().timeout(_timeout);
      await response.drain<void>().timeout(_timeout);
      return response.statusCode == 200;
    } catch (error) {
      debugPrint('[gw] resetDeviceAuth failed: $error');
      return false;
    }
  }

  /// 生成一次性配置窗口（5 分钟，单次使用）。
  Future<Map<String, dynamic>> openSetupWindow() =>
      _setupRequest('/api/v1/setup/windows');

  /// 用窗口密钥建立配置会话；窗口一旦消费即失效。
  Future<Map<String, dynamic>> createSetupSession({
    required String setupId,
    required String setupSecret,
    required String appInstanceId,
  }) =>
      _setupRequest('/api/v1/setup/sessions',
          body: {'setupId': setupId, 'setupSecret': setupSecret},
          headers: {'x-app-instance-id': appInstanceId});

  /// 恢复过期但尚未完成的配置会话；Gateway 会校验原会话令牌并续期。
  Future<Map<String, dynamic>> resumeSetupSession({
    required String setupId,
    required String sessionToken,
  }) =>
      _setupRequest('/api/v1/setup/sessions/$setupId/resume',
          body: {'sessionToken': sessionToken});

  /// 把设备生成的服务凭据转交 Gateway（明文只落 Gateway 侧 0600 文件）。
  Future<Map<String, dynamic>> saveServiceCredential({
    required String setupId,
    required String sessionToken,
    required String deviceId,
    required String credentialId,
    required String token,
  }) =>
      _setupRequest('/api/v1/setup/sessions/$setupId/service', body: {
        'sessionToken': sessionToken,
        'deviceId': deviceId,
        'credentialId': credentialId,
        'token': token,
      });

  /// 只读核验：设备必须在 BLE 激活后重新上报 state，且 service.credentialId 匹配。
  Future<Map<String, dynamic>> verifySetup({
    required String setupId,
    required String sessionToken,
  }) =>
      _setupRequest('/api/v1/setup/sessions/$setupId/verify',
          body: {'sessionToken': sessionToken});

  /// 完成配置并签发本手机访问凭据（appToken 只返回一次）。
  Future<Map<String, dynamic>> completeSetup({
    required String setupId,
    required String sessionToken,
  }) =>
      _setupRequest('/api/v1/setup/sessions/$setupId/complete',
          body: {'sessionToken': sessionToken});

  Future<Map<String, dynamic>> cancelSetup({
    required String setupId,
    required String sessionToken,
    bool devicePendingCancelled = false,
  }) =>
      _setupRequest('/api/v1/setup/sessions/$setupId/cancel', body: {
        'sessionToken': sessionToken,
        'devicePendingCancelled': devicePendingCancelled,
      });

  /// 经 Gateway 发起设备 MQTT 只读查询。失败时抛出错误，不回退设备 HTTPS。
  Future<Map<String, dynamic>> readPath(
    WifiBinding binding,
    String path,
  ) async {
    final generation = _captureConfigurationGeneration();
    if (generation == null) throw _configurationChanged();
    if (!RegExp(
            r'^/api/(status|settings|stats|stats/range|events)(\?[A-Za-z0-9_=&.-]{0,160})?$')
        .hasMatch(path)) {
      throw const NasGatewayException('INVALID_PATH', 'NAS 查询路径无效');
    }
    final config = await loadConfig();
    if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
    if (config['enabled'] != 'true') {
      throw const NasGatewayException(
          'GATEWAY_DISABLED', 'NAS 网关未启用，请连接蓝牙读取设备');
    }
    final uri = Uri.parse(config['url']!)
        .resolve('/api/v1/devices/${binding.deviceId}/query');
    final client = _httpClient(uri, config['certificatePin']!);
    // 统计页通过 MQTT 逐片返回；允许完整分页往返，但每个网络阶段仍有硬超时。
    const queryTimeout = Duration(seconds: 35);
    try {
      final request = await client.postUrl(uri).timeout(queryTimeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      request.write(jsonEncode({'path': path}));
      final response = await request.close().timeout(queryTimeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 8192) {
          throw const FormatException('NAS 查询响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(queryTimeout);
      if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
      Map<String, dynamic> envelope;
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('NAS 查询响应格式无效');
        }
        envelope = decoded;
      } on FormatException {
        throw const NasGatewayException(
            'GATEWAY_RESPONSE_INVALID', 'NAS 返回数据格式无效');
      }
      if (response.statusCode != HttpStatus.ok) {
        final code = envelope['error']?.toString() ??
            'NAS_GATEWAY_HTTP_${response.statusCode}';
        if (code == 'SERVICE_CREDENTIAL_MISMATCH') {
          throw NasGatewayException(
            code,
            '设备与 NAS 的服务授权不同步；请任一已加入手机连接蓝牙，在“设备网络与 NAS 控制”中重置服务授权并重新配置，其他手机随后需要重新加入',
          );
        }
        if (code == 'DEVICE_SERVICE_IDENTITY_UNAVAILABLE') {
          throw NasGatewayException(
            code,
            '设备未上报服务授权状态；请确认固件版本并刷新设备状态',
          );
        }
        throw NasGatewayException(code, 'NAS 查询失败（$code）');
      }
      if (envelope['schemaVersion'] != 1 ||
          envelope['deviceId'] is! String ||
          envelope['statusCode'] is! int ||
          envelope['body'] is! Map<String, dynamic>) {
        throw const NasGatewayException(
            'GATEWAY_RESPONSE_INVALID', 'NAS 返回数据格式无效');
      }
      validateGatewayReadDeviceId(envelope, binding.deviceId);
      final statusCode = envelope['statusCode'] as int;
      final body = Map<String, dynamic>.from(envelope['body'] as Map);
      if (statusCode != HttpStatus.ok) {
        final code = body['error']?.toString() ?? 'DEVICE_HTTP_$statusCode';
        if (statusCode == HttpStatus.unauthorized &&
            code == 'BINDING_INVALID') {
          throw const NasGatewayException(
            'SERVICE_CREDENTIAL_MISMATCH',
            '设备拒绝 NAS 服务凭据；请任一已加入手机连接蓝牙重置服务授权并重新配置，其他手机随后需要重新加入',
          );
        }
        throw NasGatewayException(code, '设备查询失败（$code）');
      }
      return body;
    } on NasGatewayException {
      rethrow;
    } catch (error) {
      if (!_isCurrentConfiguration(generation)) throw _configurationChanged();
      if (error is SocketException) {
        throw const NasGatewayException(
            'GATEWAY_UNAVAILABLE', 'NAS 网关不可达，请连接蓝牙');
      }
      if (error is HandshakeException) {
        throw const NasGatewayException(
            'GATEWAY_CERTIFICATE_INVALID', 'NAS 证书指纹不匹配');
      }
      if (error is TimeoutException) {
        throw const NasGatewayException(
            'GATEWAY_QUERY_TIMEOUT', 'NAS 查询超时，请连接蓝牙重试');
      }
      if (error is HttpException) {
        throw const NasGatewayException(
            'GATEWAY_UNAVAILABLE', 'NAS 网关不可达，请连接蓝牙');
      }
      rethrow;
    }
  }

  Future<NasGatewayHttpResult?> queryRequest(
      WifiBinding binding, String requestId) async {
    final generation = _captureConfigurationGeneration();
    if (generation == null) return null;
    final config = await loadConfig();
    if (!_isCurrentConfiguration(generation)) return null;
    if (config['enabled'] != 'true') return null;
    final uri = Uri.parse(config['url']!)
        .resolve('/api/v1/devices/${binding.deviceId}/requests/$requestId');
    final client = _httpClient(uri, config['certificatePin']!);
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      final response = await request.close().timeout(_timeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 4096) {
          throw const FormatException('NAS 结果响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(_timeout);
      if (!_isCurrentConfiguration(generation)) return null;
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) {
        throw const FormatException('NAS 结果响应格式无效');
      }
      if (response.statusCode != HttpStatus.ok) {
        // 保留 HTTP 状态和网关错误码；404 UNKNOWN 与网络不可达不能混为一谈。
        return NasGatewayHttpResult(response.statusCode, body);
      }
      if (body['requestId'] != requestId ||
          !['applied', 'rejected', 'pending', 'unknown']
              .contains(body['status']) ||
          body['httpStatus'] is! int) {
        return null;
      }
      return NasGatewayHttpResult(response.statusCode, body);
    } on SocketException {
      return null;
    } on HandshakeException {
      return null;
    } on HttpException {
      return null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// 网关不可达或未启用时返回 null；禁止改走设备 HTTPS。
  Future<NasGatewayHttpResult?> tryWrite(
    WifiBinding binding, {
    required String path,
    required String body,
    required String requestId,
  }) async {
    final generation = _captureConfigurationGeneration();
    if (generation == null) return _writeFailure(false);
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool(_enabledKey) ?? false)) return null;
    if (!_isCurrentConfiguration(generation)) {
      return _writeFailure(false);
    }
    final baseUrl = await loadBaseUrl();
    final certificatePin = preferences.getString(_pinKey) ?? '';
    if (!_isCurrentConfiguration(generation)) return _writeFailure(false);
    final base = Uri.parse(baseUrl);
    final uri = base.resolve('/api/v1/devices/${binding.deviceId}/control');
    // 关闭系统 CA 信任链，只接受与用户配置指纹匹配的网关证书。
    final client = _httpClient(uri, certificatePin);
    var commandMayHaveReachedGateway = false;
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${binding.token}')
        ..set('X-App-Instance-Id', binding.tokenId);
      request.write(jsonEncode({
        'version': 1,
        'requestId': requestId,
        'tokenId': binding.tokenId,
        'path': path,
        'body': body,
      }));
      if (!_isCurrentConfiguration(generation)) {
        return _writeFailure(false);
      }
      // 从 close 开始请求可能已到达 Gateway；之后的超时必须作为 unknown 处理。
      commandMayHaveReachedGateway = true;
      final response = await request.close().timeout(_controlResponseTimeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, part) {
        if (all.length + part.length > 4096) {
          throw const FormatException('NAS 网关响应超出长度限制');
        }
        return all..addAll(part);
      }).timeout(_controlResponseTimeout);
      if (!_isCurrentConfiguration(generation)) {
        return _writeFailure(commandMayHaveReachedGateway);
      }
      if (response.statusCode != HttpStatus.ok) {
        Map<String, dynamic> gatewayBody = const {};
        try {
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is Map<String, dynamic>) gatewayBody = decoded;
        } on FormatException {
          // 无法解析网关响应时保守保留 unknown，避免生成第二个控制请求。
        }
        final published = gatewayBody['commandPublished'];
        return NasGatewayHttpResult(
            response.statusCode,
            {
              ...gatewayBody,
              'error': gatewayBody['error'] ??
                  'NAS_GATEWAY_HTTP_${response.statusCode}',
              'gatewayHttpStatus': response.statusCode,
              'resultUnknown': published == true ||
                  (published != false && response.statusCode >= 500),
            },
            commandOutcomeKnown: published == false ||
                (response.statusCode < 500 && published != true));
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['requestId'] != requestId ||
          decoded['httpStatus'] is! int) {
        throw const FormatException('NAS 网关响应格式无效');
      }
      final statusCode = decoded['httpStatus'] as int;
      final payload = decoded['body'];
      final resultBody = payload is Map<String, dynamic>
          ? payload
          : decoded['error'] is String
              ? <String, dynamic>{'error': decoded['error']}
              : <String, dynamic>{};
      // 网关外层 HTTP 200 只会在设备返回最终 ACK 后发出；设备 statusCode
      // 即使是 4xx/5xx，也属于已知拒绝，不能继续当作结果未知保留 pending。
      return NasGatewayHttpResult(statusCode, resultBody,
          commandOutcomeKnown: true);
    } on SocketException {
      return _writeFailure(commandMayHaveReachedGateway);
    } on HandshakeException {
      return _writeFailure(false);
    } on HttpException {
      return _writeFailure(commandMayHaveReachedGateway);
    } on TimeoutException {
      return _writeFailure(commandMayHaveReachedGateway);
    } catch (error) {
      if (!_isCurrentConfiguration(generation)) {
        return _writeFailure(commandMayHaveReachedGateway);
      }
      rethrow;
    }
  }

  NasGatewayHttpResult _writeFailure(bool unknown) => NasGatewayHttpResult(
        unknown ? HttpStatus.gatewayTimeout : HttpStatus.serviceUnavailable,
        {
          'error': unknown ? 'GATEWAY_RESULT_UNKNOWN' : 'GATEWAY_UNAVAILABLE',
          'gatewayHttpStatus': unknown
              ? HttpStatus.gatewayTimeout
              : HttpStatus.serviceUnavailable,
          'resultUnknown': unknown,
          'commandPublished': unknown ? null : false,
        },
        commandOutcomeKnown: !unknown,
      );
}
