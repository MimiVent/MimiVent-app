import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/ble/mimivent_ble_manager.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_transport.dart';
import 'package:mimivent_app/features/local_network/wifi_binding.dart';
import 'package:mimivent_app/features/local_network/wifi_binding_controller.dart';
import 'package:mimivent_app/features/local_network/wifi_binding_store.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';
import 'package:mimivent_app/transport/device_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ble extends MimiVentBleManager {
  _Ble(this.deviceId);

  final String deviceId;
  final List<Map<String, dynamic>> requests = [];
  bool committed = false;

  @override
  Future<DeviceResponse> requestWifi(Map<String, dynamic> envelope) async {
    requests.add(Map<String, dynamic>.from(envelope));
    final op = envelope['op'];
    final result = switch (op) {
      'wifi.status' => {
          'connected': true,
          'deviceId': deviceId,
          'ip': '192.168.2.5',
          'wifiReadAvailable': false,
        },
      'wifi.bind.open' => {'expiresInSec': 120},
      'wifi.bind.begin' => {
          'scheme': 'https',
          'host': '192.168.2.5',
          'port': 8443,
          'certPinSha256': List.filled(64, 'a').join(),
          'deviceId': deviceId,
          'tokenId': List.filled(32, 'b').join(),
          'token': List.filled(43, 'T').join(),
          'bindingState': 'pending',
          'expiresInSec': 120,
        },
      'wifi.bind.verify' => {
          'verified': envelope['token'] == List.filled(43, 'T').join(),
        },
      'wifi.bind.commit' => {'bindingState': 'active'},
      'wifi.bind.status' => {
          'tokenId': envelope['tokenId'],
          'bindingState': committed ? 'active' : 'pending',
        },
      _ => {'ok': true},
    };
    if (op == 'wifi.bind.commit') committed = true;
    return DeviceResponse(statusCode: 200, body: jsonEncode(result));
  }
}

class _Store extends WifiBindingStore {
  List<WifiBinding> records = [];

  @override
  Future<List<WifiBinding>> load() async => List.of(records);

  @override
  Future<void> save(List<WifiBinding> values) async {
    records = List.of(values);
  }
}

class _Gateway extends NasGatewayTransport {
  @override
  Future<NasGatewayHttpResult?> tryReadState(WifiBinding binding) async => null;
}

class _Controller extends WifiBindingController {
  _Controller(_Ble ble, _Store store)
      : super(ble, store: store, gatewayTransport: _Gateway());

  int directReads = 0;

  @override
  Future<Map<String, dynamic>> checkedRead(WifiBinding binding) async {
    directReads++;
    throw StateError('binding must not depend on device HTTPS');
  }
}

void main() {
  const deviceId = '0123456789abcdef0123456789abcdef';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('new binding verifies and commits over BLE when HTTPS is disabled',
      () async {
    final ble = _Ble(deviceId);
    final store = _Store();
    final controller = _Controller(ble, store);

    await controller.bind();

    expect(controller.error, isNull);
    expect(controller.selected?.state, 'active');
    expect(controller.status?['bindingState'], 'active');
    expect(controller.directReads, 0);
    expect(
        ble.requests.map((request) => request['op']),
        containsAllInOrder([
          'wifi.status',
          'wifi.bind.open',
          'wifi.bind.begin',
          'wifi.bind.status',
          'wifi.bind.verify',
          'wifi.bind.commit',
          'wifi.bind.status',
        ]));
    expect(
        ble.requests.firstWhere(
            (request) => request['op'] == 'wifi.bind.verify')['token'],
        List.filled(43, 'T').join());
    expect(store.records.single.state, 'active');
    controller.dispose();
  });
}
