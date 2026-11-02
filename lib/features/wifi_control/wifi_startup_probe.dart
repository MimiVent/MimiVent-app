import 'wifi_binding.dart';
import 'wifi_binding_store.dart';
import 'wifi_read_transport.dart';

class WifiStartupSnapshot {
  const WifiStartupSnapshot({required this.binding, required this.status});

  final WifiBinding binding;
  final Map<String, dynamic> status;
}

/// 启动时只尝试已有绑定，不触发蓝牙扫描或蓝牙权限弹窗。
Future<WifiStartupSnapshot?> probeWifiStartup() async {
  try {
    final records = await WifiBindingStore().load();
    for (final binding in records) {
      if (binding.state != 'active') continue;
      try {
        final status = await WifiReadTransport().read(binding);
        return WifiStartupSnapshot(binding: binding, status: status);
      } on WifiReadException {
        continue;
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    // 安全存储不可用或记录损坏时回到蓝牙流程，不在这里覆盖任何记录。
  }
  return null;
}
