import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/ble/mimivent_ble_manager.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_transport.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';
import 'package:mimivent_app/features/local_network/wifi_binding.dart';
import 'package:mimivent_app/features/local_network/wifi_binding_controller.dart';
import 'package:mimivent_app/features/local_network/wifi_binding_store.dart';
import 'package:mimivent_app/transport/device_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _deviceId = '0123456789abcdef0123456789abcdef';
const _serviceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _credentialId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _oldCredentialId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _appInstanceId = 'cccccccccccccccccccccccccccccccc';
final _serviceToken = List.filled(43, 'T').join();
final _appToken = List.filled(43, 'P').join();
const _setupId = '11111111-2222-3333-4444-555555555555';
const _setupSecret = 'sssssssssssssssssssssssssssssssssssssssssss';
const _sessionToken = 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk';

class _Ble extends MimiVentBleManager {
  _Ble();

  final List<Map<String, dynamic>> requests = [];
  bool activated = false;
  bool confirmed = false;
  String? activeCredential;

  @override
  Future<DeviceResponse> requestWifi(Map<String, dynamic> envelope) async {
    requests.add(Map<String, dynamic>.from(envelope));
    final op = envelope['op'];
    final result = switch (op) {
      'wifi.status' => {
          'connected': true,
          'deviceId': _deviceId,
          'ip': '192.168.2.5',
          'wifiReadAvailable': false,
        },
      'wifi.service.status' => {
          'deviceId': _deviceId,
          'state': activated ? 'active' : 'unconfigured',
          if (activated) 'serviceId': _serviceId,
          if (activated) 'credentialId': activeCredential ?? _oldCredentialId,
          if (activated) 'authRevision': 1,
          if (activated && !confirmed) 'candidateTransactionId': _setupId,
          if (activated && !confirmed) 'candidateCredentialId': _credentialId,
          if (activated && !confirmed) 'candidateState': 'activated',
        },
      'wifi.service.begin' => {
          'deviceId': _deviceId,
          'serviceId': envelope['serviceId'],
          'credentialId': _credentialId,
          'token': _serviceToken,
          'authRevision': 1,
          'transactionId': envelope['transactionId'],
          'state': 'pending',
        },
      'wifi.service.activate' => {'state': 'active'},
      'wifi.service.confirm' => {'state': 'confirmed'},
      'wifi.service.cancel' => {'state': 'cancelled'},
      _ => {'ok': true},
    };
    if (op == 'wifi.service.activate') activated = true;
    if (op == 'wifi.service.confirm') {
      confirmed = true;
      activeCredential = _credentialId;
    }
    return DeviceResponse(statusCode: 200, body: jsonEncode(result));
  }
}

class _Store extends WifiBindingStore {
  List<WifiBinding> records = [];
  final Map<String, dynamic> pending = {};

  @override
  Future<List<WifiBinding>> load() async => List.of(records);

  @override
  Future<void> save(List<WifiBinding> values) async {
    records = List.of(values);
  }

  @override
  Future<List<Map<String, dynamic>>> loadPendingSetups() async =>
      pending.values.map((value) => Map<String, dynamic>.from(value)).toList();

  @override
  Future<void> savePendingSetup(Map<String, dynamic> setup) async {
    pending[setup['deviceId'] as String] = Map<String, dynamic>.from(setup);
  }

  @override
  Future<void> clearPendingSetup(String deviceId) async {
    pending.remove(deviceId);
  }
}

class _Gateway extends NasGatewayTransport {
  String? savedCredential;
  String? savedToken;
  bool completed = false;
  int verifyCalls = 0;
  int saveCalls = 0;
  int openCalls = 0;
  int beginCalls = 0;
  bool failCompleteOnce = false;
  bool missingStagedOnce = false;

  @override
  Future<Map<String, dynamic>> openSetupWindow() async {
    openCalls++;
    return {
      'setupId': _setupId,
      'setupSecret': _setupSecret,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 300000,
    };
  }

  @override
  Future<Map<String, dynamic>> createSetupSession({
    required String setupId,
    required String setupSecret,
    required String appInstanceId,
  }) async {
    expect(setupId, _setupId);
    expect(setupSecret, _setupSecret);
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(appInstanceId), isTrue);
    return {'setupId': setupId, 'sessionToken': _sessionToken};
  }

  @override
  Future<Map<String, dynamic>> resumeSetupSession({
    required String setupId,
    required String sessionToken,
  }) async =>
      {
        'setupId': setupId,
        'sessionToken': sessionToken,
        'stage': 'pending_device'
      };

  @override
  Future<Map<String, dynamic>> saveServiceCredential({
    required String setupId,
    required String sessionToken,
    required String deviceId,
    required String credentialId,
    required String token,
  }) async {
    saveCalls++;
    expect(sessionToken, _sessionToken);
    expect(deviceId, _deviceId);
    savedCredential = credentialId;
    savedToken = token;
    return {'stage': 'pending_device'};
  }

  @override
  Future<Map<String, dynamic>> verifySetup({
    required String setupId,
    required String sessionToken,
  }) async {
    verifyCalls++;
    if (missingStagedOnce) {
      missingStagedOnce = false;
      throw const NasGatewayException('SERVICE_NOT_STAGED', 'not staged');
    }
    return {'verified': true, 'stage': 'verified'};
  }

  @override
  Future<Map<String, dynamic>> completeSetup({
    required String setupId,
    required String sessionToken,
  }) async {
    if (failCompleteOnce) {
      failCompleteOnce = false;
      throw StateError('gateway temporarily unavailable');
    }
    completed = true;
    return {
      'stage': 'completed',
      'appInstanceId': _appInstanceId,
      'appToken': _appToken,
      'role': 'admin',
    };
  }

  @override
  Future<Map<String, dynamic>> cancelSetup({
    required String setupId,
    required String sessionToken,
    bool devicePendingCancelled = false,
  }) async =>
      {'stage': 'cancelled'};
}

class _Controller extends WifiBindingController {
  _Controller(super.ble, _Store store, _Gateway gateway)
      : super(store: store, gatewayTransport: gateway);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('加载多个手机凭据时保留不同的设备和 App 实例', () async {
    final store = _Store()
      ..records = [
        WifiBinding(
          deviceId: _deviceId,
          tokenId: _appInstanceId,
          token: _appToken,
          pin: '',
          host: '',
          clientId: 'gateway',
          state: 'active',
        ),
        WifiBinding(
          deviceId: _deviceId,
          tokenId: 'fedcba9876543210fedcba9876543210',
          token: 'another-app-token',
          pin: '',
          host: '',
          clientId: 'gateway',
          state: 'active',
        ),
        WifiBinding(
          deviceId: '99999999999999999999999999999999',
          tokenId: _appInstanceId,
          token: 'another-device-token',
          pin: '',
          host: '',
          clientId: 'gateway',
          state: 'active',
        ),
      ];
    final controller = _Controller(_Ble(), store, _Gateway());

    await controller.load();

    expect(controller.error, isNull);
    expect(controller.records, hasLength(3));
    controller.dispose();
  });

  test('首次配置经网关建立服务授权并保存手机凭据', () async {
    final ble = _Ble();
    final store = _Store();
    final gateway = _Gateway();
    final controller = _Controller(ble, store, gateway);

    await controller.bind();

    expect(controller.error, isNull);
    expect(controller.selected?.state, 'active');
    expect(controller.status?['bindingState'], 'active');
    // 手机凭据来自网关，不是设备服务 token。
    expect(controller.selected?.tokenId, _appInstanceId);
    expect(controller.selected?.token, _appToken);
    // 设备生成的服务 token 只转交网关，App 不持久化。
    expect(gateway.savedToken, _serviceToken);
    expect(gateway.savedCredential, _credentialId);
    expect(gateway.completed, isTrue);
    expect(gateway.verifyCalls, greaterThanOrEqualTo(1));
    expect(ble.confirmed, isTrue);
    expect(
        ble.requests.map((request) => request['op']),
        containsAllInOrder([
          'wifi.status',
          'wifi.service.status',
          'wifi.service.begin',
          'wifi.service.activate',
          'wifi.service.confirm',
        ]));
    expect(store.records.single.deviceId, _deviceId);
    expect(store.records.single.tokenId, _appInstanceId);
    controller.dispose();
  });

  test('设备已激活而网关完成暂时失败时保留事务并可恢复', () async {
    final ble = _Ble();
    final store = _Store();
    final gateway = _Gateway()..failCompleteOnce = true;
    final controller = _Controller(ble, store, gateway);

    await controller.bind();

    expect(controller.error, contains('恢复'));
    expect(ble.confirmed, isTrue);
    expect(store.pending, contains(_deviceId));
    expect(gateway.completed, isFalse);
    final saved = Map<String, dynamic>.from(store.pending[_deviceId]!);
    expect(saved['serviceToken'], _serviceToken);
    expect(ble.requests.where((r) => r['op'] == 'wifi.service.begin'),
        hasLength(1));

    final retry = _Controller(ble, store, gateway);
    await retry.bind();

    expect(retry.error, isNull);
    expect(retry.selected?.token, _appToken);
    expect(gateway.completed, isTrue);
    expect(gateway.openCalls, 1);
    expect(ble.requests.where((r) => r['op'] == 'wifi.service.begin'),
        hasLength(1));
    expect(store.pending, isEmpty);
    retry.dispose();
    controller.dispose();
  });

  test('恢复已核验的激活候选时不重写 Gateway 暂存凭据', () async {
    final ble = _Ble()..activated = true;
    final store = _Store();
    store.pending[_deviceId] = {
      'deviceId': _deviceId,
      'setupId': _setupId,
      'sessionToken': _sessionToken,
      'appInstanceId': _appInstanceId,
      'transactionId': _setupId,
      'serviceId': _serviceId,
      'credentialId': _credentialId,
      'serviceToken': _serviceToken,
      'stage': 'verified',
    };
    final gateway = _Gateway();
    final controller = _Controller(ble, store, gateway);

    await controller.bind();

    expect(controller.error, isNull);
    expect(gateway.saveCalls, 0);
    expect(ble.confirmed, isTrue);
    expect(gateway.completed, isTrue);
    expect(store.pending, isEmpty);
    expect(ble.requests.where((r) => r['op'] == 'wifi.service.begin'), isEmpty);
    controller.dispose();
  });

  test('激活后 Gateway 暂存丢失时使用安全断点补交同一凭据', () async {
    final ble = _Ble()..activated = true;
    final store = _Store();
    store.pending[_deviceId] = {
      'deviceId': _deviceId,
      'setupId': _setupId,
      'sessionToken': _sessionToken,
      'appInstanceId': _appInstanceId,
      'transactionId': _setupId,
      'serviceId': _serviceId,
      'credentialId': _credentialId,
      'serviceToken': _serviceToken,
      'stage': 'device_activated',
    };
    final gateway = _Gateway()..missingStagedOnce = true;
    final controller = _Controller(ble, store, gateway);

    await controller.bind();

    expect(controller.error, isNull);
    expect(gateway.saveCalls, 1);
    expect(gateway.savedToken, _serviceToken);
    expect(ble.confirmed, isTrue);
    expect(gateway.completed, isTrue);
    expect(store.pending, isEmpty);
    controller.dispose();
  });

  test('设备已完成服务授权且本机有凭据时直接复用，不重复配置', () async {
    final ble = _Ble()..activated = true;
    final store = _Store()
      ..records = [
        WifiBinding(
          deviceId: _deviceId,
          tokenId: _appInstanceId,
          token: _appToken,
          pin: '',
          host: '',
          clientId: 'gateway',
          state: 'active',
        )
      ];
    final gateway = _Gateway();
    final controller = _Controller(ble, store, gateway);

    await controller.bind();

    expect(controller.error, isNull);
    expect(controller.selected?.tokenId, _appInstanceId);
    expect(gateway.completed, isFalse);
    expect(gateway.verifyCalls, 0);
    expect(ble.requests.map((request) => request['op']),
        isNot(contains('wifi.service.begin')));
    controller.dispose();
  });

  test('设备已有服务授权但本机没有凭据时给出明确错误', () async {
    final ble = _Ble()..activated = true;
    final store = _Store();
    final gateway = _Gateway();
    final controller = _Controller(ble, store, gateway);

    await controller.bind();

    expect(controller.error, contains('本机没有访问凭据'));
    expect(gateway.completed, isFalse);
    controller.dispose();
  });
}
