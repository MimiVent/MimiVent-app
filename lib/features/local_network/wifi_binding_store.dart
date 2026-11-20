import 'dart:convert';
import 'package:flutter/services.dart';
import 'wifi_binding.dart';

class WifiBindingStore {
  static const channel = MethodChannel('mimivent/wifi_credentials');
  int dropped = 0;
  Future<void> clearConfirmed() => channel
      .invokeMethod<void>('clear', {'value': 'REMOVE_LOCAL_WIFI_BINDINGS'});
  Future<List<Map<String, dynamic>>> loadPendingSetups() async {
    final raw = await channel.invokeMethod<String>('read_setup');
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('待恢复配置记录无效');
    return decoded
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList(growable: false);
  }

  Future<void> savePendingSetup(Map<String, dynamic> setup) async {
    final pending = await loadPendingSetups();
    final deviceId = setup['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw const FormatException('待恢复配置缺少设备身份');
    }
    final next = [
      ...pending.where((value) => value['deviceId'] != deviceId),
      Map<String, dynamic>.from(setup),
    ];
    if (next.length > 16) throw StateError('待恢复配置过多，请先完成其他设备配置');
    await channel
        .invokeMethod<void>('write_setup', {'value': jsonEncode(next)});
  }

  Future<void> clearPendingSetup(String deviceId) async {
    final next = (await loadPendingSetups())
        .where((value) => value['deviceId'] != deviceId)
        .toList(growable: false);
    if (next.isEmpty) {
      await channel.invokeMethod<void>('clear_setup');
    } else {
      await channel
          .invokeMethod<void>('write_setup', {'value': jsonEncode(next)});
    }
  }

  Future<List<WifiBinding>> load() async {
    final raw = await channel.invokeMethod<String>('read') ?? '[]';
    final list = jsonDecode(raw);
    if (list is! List) throw const FormatException('安全绑定列表无效，已保留原记录');
    final records = <WifiBinding>[];
    dropped = 0;
    for (final item in list) {
      try {
        records
            .add(WifiBinding.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {
        dropped++;
      }
    }
    // 坏项保留在密文中，避免自动重写掩盖恢复线索；后续用户显式保存时逐条保留有效项。
    return records;
  }

  Future<void> save(List<WifiBinding> records) async {
    if (records.length > 16) throw StateError('本机绑定记录过多，请先移除不使用的设备');
    await channel.invokeMethod<void>('write',
        {'value': jsonEncode(records.map((e) => e.toJson()).toList())});
  }
}
