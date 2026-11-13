import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/ble/mimivent_ble_manager.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_transport.dart';
import 'package:mimivent_app/features/local_network/wifi_binding.dart';
import 'package:mimivent_app/features/local_network/wifi_binding_controller.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';

class _Gateway extends NasGatewayTransport {
  int code = 200;
  int writes = 0;
  String? lastPath;
  bool unknown = false;
  bool unavailable = false;
  String rejectionCode = 'PIR_HIGH';
  NasGatewayHttpResult? queryResult;
  @override
  Future<NasGatewayHttpResult?> queryRequest(
          WifiBinding binding, String requestId) async =>
      queryResult;
  @override
  Future<NasGatewayHttpResult?> tryWrite(WifiBinding binding,
      {required String path,
      required String body,
      required String requestId}) async {
    writes++;
    lastPath = path;
    if (unknown) {
      return const NasGatewayHttpResult(504, {
        'gatewayHttpStatus': 504,
        'resultUnknown': true,
      });
    }
    if (unavailable) return null;
    return NasGatewayHttpResult(
        code, code == 200 ? {'ok': true} : {'error': rejectionCode});
  }
}

class _Controller extends WifiBindingController {
  _Controller(_Gateway gateway)
      : super(MimiVentBleManager(), gatewayTransport: gateway);
}

class _ReadController extends WifiBindingController {
  _ReadController(NasGatewayTransport gateway)
      : super(MimiVentBleManager(), gatewayTransport: gateway);
}

class _SnapshotController extends WifiBindingController {
  _SnapshotController(NasGatewayTransport gateway, this.snapshot)
      : super(MimiVentBleManager(), gatewayTransport: gateway);

  final Map<String, dynamic> snapshot;

  @override
  Future<Map<String, dynamic>> checkedRead(WifiBinding binding) async =>
      Map<String, dynamic>.from(snapshot);
}

class _FaultyStore extends InMemorySharedPreferencesStore {
  _FaultyStore(this.throwOnRemove) : super.empty();
  final bool throwOnRemove;
  bool failing = true;
  @override
  Future<bool> remove(String key) async {
    if (failing) {
      if (throwOnRemove) throw PlatformException(code: 'WRITE_FAILED');
      return false;
    }
    return super.remove(key);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final binding = WifiBinding(
      deviceId: 'device',
      tokenId: 'token-id',
      token: 'token',
      pin: 'pin',
      host: '192.168.2.10',
      clientId: 'client',
      state: 'active');

  test('NAS 确认成功后直连读取失败仍保留执行成功，并且只发送一次', () async {
    final gateway = _Gateway();
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=on');
    expect(gateway.writes, 1);
    expect(controller.error, isNull);
    expect(controller.status, isNull);
    expect(controller.controlNotice, contains('设备已确认执行'));
    expect(controller.controlNotice, contains('无需重复操作'));
  });

  test('设备拒绝控制时不能显示执行成功', () async {
    final gateway = _Gateway()..code = 409;
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=on');
    expect(controller.error, isNotNull);
    expect(controller.controlNotice, isNull);
  });

  test('普通读取失败继续报告读取错误，不冒充控制成功', () async {
    final controller = _Controller(_Gateway())..selected = binding;
    addTearDown(controller.dispose);
    await controller.loadSettings();
    expect(controller.error, isNotNull);
    expect(controller.controlNotice, isNull);
  });

  test('网关结果未知时跨页面保留请求，再次点击仅查询而不发送', () async {
    final gateway = _Gateway()..unknown = true;
    final first = _Controller(gateway)..selected = binding;
    await first.control('/api/timed', 'mode=on');
    expect(first.error, contains('原请求仍保留'));
    first.dispose();
    final reopened = _Controller(gateway)..selected = binding;
    addTearDown(reopened.dispose);
    await reopened.control('/api/timed', 'mode=on');
    expect(gateway.writes, 1);
    expect(reopened.error, contains('没有发送新控制'));
    await reopened.finishPendingConfirmation();
    await reopened.control('/api/timed', 'mode=on');
    expect(gateway.writes, 2);
  });

  test('确认上次成功时明确说明本次没有发送新操作', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'wifi.pendingControl.device.token-id', 'prior-request');
    final gateway = _Gateway()
      ..queryResult = const NasGatewayHttpResult(200, {
        'status': 'applied',
        'httpStatus': 200,
      });
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=off');
    expect(gateway.writes, 0);
    expect(controller.error, isNull);
    expect(controller.controlNotice, contains('本次未发送新控制'));
    expect(
        preferences.getString('wifi.pendingControl.device.token-id'), isNull);
  });

  for (final throws in [true, false]) {
    test('成功后清理记录${throws ? '抛异常' : '返回失败'}仍显示成功且跨页面不重发', () async {
      final faulty = _FaultyStore(throws);
      SharedPreferencesStorePlatform.instance = faulty;
      final gateway = _Gateway();
      final first = _Controller(gateway)..selected = binding;
      await first.control('/api/timed', 'mode=on');
      expect(first.error, isNull);
      expect(first.controlNotice, contains('设备已确认执行'));
      expect(first.controlNotice, contains('暂未清理'));
      first.dispose();
      final reopened = _Controller(gateway)..selected = binding;
      addTearDown(reopened.dispose);
      await reopened.control('/api/timed', 'mode=off');
      expect(reopened.error, isNull);
      expect(reopened.controlNotice, contains('暂未清理'));
      expect(gateway.writes, 1);
      faulty.failing = false;
      await reopened.finishPendingConfirmation();
      await reopened.control('/api/timed', 'mode=off');
      expect(gateway.writes, 2);
    });
  }

  test('NAS 缓存确认成功时无需设备直连查询，也不发送新控制', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'wifi.pendingControl.device.token-id', 'prior-request');
    final gateway = _Gateway()
      ..queryResult = const NasGatewayHttpResult(200, {
        'status': 'applied',
        'httpStatus': 200,
      });
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=on');
    expect(controller.error, isNull);
    expect(controller.controlNotice, contains('上次控制已确认'));
    expect(gateway.writes, 0);
    expect(
        preferences.getString('wifi.pendingControl.device.token-id'), isNull);
  });

  test('旧记录正文未知时查询原结果，不直接当成拒绝执行或重发', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'wifi.pendingControl.device.token-id', 'prior-request');
    final gateway = _Gateway()
      ..queryResult = const NasGatewayHttpResult(200, {
        'status': 'applied',
        'httpStatus': 200,
      });
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=on');
    expect(controller.error, isNull);
    expect(controller.controlNotice, contains('上次控制已确认'));
    expect(gateway.writes, 0);
  });

  test('NAS 未启用时不回落设备 HTTPS 写入，清理未发送请求', () async {
    final gateway = _Gateway()..unavailable = true;
    final preferences = await SharedPreferences.getInstance();
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=on');
    expect(gateway.writes, 1);
    expect(controller.error, contains('请连接蓝牙'));
    expect(
        preferences.getString('wifi.pendingControl.device.token-id'), isNull);
  });

  test('只读结果暂不可查时保留 pending，不通过设备 HTTPS 伪确认', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'wifi.pendingControl.device.token-id', 'prior-request');
    final gateway = _Gateway();
    final controller = _Controller(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.control('/api/timed', 'mode=on');
    // 实现区分了「网关查询失败」与「设备返回 unknown」两种待确认来源，
    // 这里断言的是前者：查询没成功，因此不伪确认也不发送新控制。
    expect(controller.error, contains('原请求仍保留'));
    expect(controller.error, contains('没有发送新控制'));
    expect(preferences.getString('wifi.pendingControl.device.token-id'),
        'prior-request');
  });

  test('NAS 状态读取不可用时提示改用蓝牙，不连接设备 HTTPS', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = NasGatewayTransport();
    final controller = _ReadController(gateway)..selected = binding;
    addTearDown(controller.dispose);
    await controller.read(binding.host);
    expect(controller.error, contains('请连接蓝牙'));
  });

  test('WiFi 设置从 NAS 状态快照读取，不访问设备 HTTPS', () async {
    final controller = _SnapshotController(_Gateway(), {
      'startupCooldownMs': 1000,
      'leaveConfirmMs': 0,
      'autoExhaustMs': 300000,
      'manualExhaustMs': 180000,
      'pauseMs': 600000,
    })
      ..selected = binding;
    addTearDown(controller.dispose);

    await controller.loadSettings();

    expect(controller.error, isNull);
    expect(controller.settings?['manualExhaustMs'], 180000);
  });

  test('WiFi 设置保存走 NAS MQTT 网关并保留 ACK 确认', () async {
    final gateway = _Gateway();
    final controller = _SnapshotController(gateway, {
      'startupCooldownMs': 1000,
      'leaveConfirmMs': 0,
      'autoExhaustMs': 300000,
      'manualExhaustMs': 180000,
      'pauseMs': 600000,
    })
      ..selected = binding;
    addTearDown(controller.dispose);

    await controller.saveSettings({
      'startupCooldownMs': 1000,
      'leaveConfirmMs': 0,
      'autoExhaustMs': 300000,
      'manualExhaustMs': 240000,
      'pauseMs': 600000,
    });

    expect(controller.error, isNull);
    expect(gateway.writes, 1);
    expect(gateway.lastPath, '/api/settings');
    expect(controller.settings?['manualExhaustMs'], 240000);
  });
}
