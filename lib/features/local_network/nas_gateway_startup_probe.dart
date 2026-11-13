import 'wifi_binding.dart';
import 'wifi_binding_store.dart';
import 'nas_gateway_transport.dart';
import 'nas_gateway_models.dart';

final NasGatewayTransport _startupGateway = NasGatewayTransport();

class NasGatewaySnapshot {
  const NasGatewaySnapshot({required this.binding, required this.status});

  final WifiBinding binding;
  final Map<String, dynamic> status;
}

/// 启动时只尝试已有绑定，不触发蓝牙扫描或蓝牙权限弹窗。
Future<NasGatewaySnapshot?> probeNasGatewayStartup({
  NasGatewayTransport? gateway,
  void Function(Object error)? onError,
}) async {
  final transport = gateway ?? _startupGateway;
  try {
    final records = await WifiBindingStore().load();
    for (final binding in records) {
      if (binding.state != 'active') continue;
      try {
        final result = await transport.tryReadState(binding);
        if (result == null) {
          onError?.call(const NasGatewayException(
              'GATEWAY_UNAVAILABLE', 'NAS 网关未启用或不可达'));
          continue;
        }
        if (result.statusCode != 200) {
          onError?.call(NasGatewayException(
              result.body['error']?.toString() ?? 'GATEWAY_READ_FAILED',
              'NAS 状态不可用'));
          continue;
        }
        if (result.body['deviceId'] != binding.deviceId ||
            result.body['bindingState'] != 'active') {
          onError?.call(
              const NasGatewayException('DEVICE_MISMATCH', 'NAS 快照身份与本地绑定不匹配'));
          continue;
        }
        if (result.body['stale'] != false ||
            result.body['stateFreshness'] != 'fresh') {
          onError?.call(const NasGatewayException(
            'DEVICE_MQTT_UNAVAILABLE',
            '设备尚未通过 NAS MQTT 上报实时状态',
          ));
          continue;
        }
        return NasGatewaySnapshot(binding: binding, status: result.body);
      } on NasGatewayException catch (error) {
        onError?.call(error);
        continue;
      } catch (error) {
        onError?.call(error);
        continue;
      }
    }
  } catch (error) {
    onError?.call(error);
    // 安全存储不可用或记录损坏时回到蓝牙流程，不在这里覆盖任何记录。
  }
  return null;
}
