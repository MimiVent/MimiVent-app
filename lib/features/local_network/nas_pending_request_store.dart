import 'package:shared_preferences/shared_preferences.dart';

import 'wifi_binding.dart';

/// NAS MQTT 控制与管理页共用同一条待确认请求记录。
class NasPendingRequestStore {
  NasPendingRequestStore._();

  static String key(WifiBinding binding) =>
      keyFor(binding.deviceId, binding.tokenId);

  static String keyFor(String deviceId, String tokenId) =>
      'wifi.pendingControl.$deviceId.$tokenId';

  static String legacyKey(WifiBinding binding) =>
      legacyKeyFor(binding.deviceId, binding.tokenId);

  static String legacyKeyFor(String deviceId, String tokenId) =>
      'mimivent.nas.pending.$deviceId.$tokenId';

  static String createdAtKey(WifiBinding binding) =>
      createdAtKeyFor(binding.deviceId, binding.tokenId);

  static String createdAtKeyFor(String deviceId, String tokenId) =>
      '${keyFor(deviceId, tokenId)}.createdAtMs';

  static String estimatedAgeKey(WifiBinding binding) =>
      estimatedAgeKeyFor(binding.deviceId, binding.tokenId);

  static String estimatedAgeKeyFor(String deviceId, String tokenId) =>
      '${createdAtKeyFor(deviceId, tokenId)}.estimated';

  /// 读取并迁移旧版本主控制器写入的 key；冲突时保留两条记录并拒绝猜测。
  static Future<String?> read(
      SharedPreferences preferences, WifiBinding binding) async {
    final current = preferences.getString(key(binding));
    final legacy = preferences.getString(legacyKey(binding));
    if (current != null && legacy != null && current != legacy) {
      throw StateError('发现不一致的 NAS MQTT 待确认请求，请先核对设备状态');
    }
    final requestId = current ?? legacy;
    if (requestId == null) return null;
    if (current == null &&
        !await preferences.setString(key(binding), requestId)) {
      throw StateError('无法迁移 NAS MQTT 待确认记录，请勿重复操作');
    }
    if (legacy != null) await preferences.remove(legacyKey(binding));
    if (preferences.getInt(createdAtKey(binding)) == null) {
      await preferences.setInt(
          createdAtKey(binding), DateTime.now().millisecondsSinceEpoch);
      await preferences.setBool(estimatedAgeKey(binding), true);
    }
    return requestId;
  }

  static Future<bool> save(
      SharedPreferences preferences, WifiBinding binding, String requestId,
      {int? createdAtMs}) async {
    if (!await preferences.setString(key(binding), requestId)) return false;
    await preferences.setInt(createdAtKey(binding),
        createdAtMs ?? DateTime.now().millisecondsSinceEpoch);
    // 清理旧键是附带动作：存储层拒绝删除时不能让保存本身失败，
    // 否则调用方会把「已成功写入待确认记录」误报成控制未发送。
    try {
      await preferences.remove(estimatedAgeKey(binding));
      await preferences.remove(legacyKey(binding));
    } catch (_) {
      // 保留残留键不影响读取：读取侧优先 current，conflict 由 read() 判定。
    }
    return preferences.getString(key(binding)) == requestId;
  }

  static int? ageMs(SharedPreferences preferences, WifiBinding binding,
      {int? nowMs}) {
    final createdAt = preferences.getInt(createdAtKey(binding));
    if (createdAt == null) return null;
    return ((nowMs ?? DateTime.now().millisecondsSinceEpoch) - createdAt)
        .clamp(0, 0x7fffffffffffffff)
        .toInt();
  }

  static bool isAgeEstimated(
          SharedPreferences preferences, WifiBinding binding) =>
      preferences.getBool(estimatedAgeKey(binding)) ?? false;

  static Future<bool> clear(SharedPreferences preferences, WifiBinding binding,
      {String? expectedRequestId}) async {
    final current = preferences.getString(key(binding));
    final legacy = preferences.getString(legacyKey(binding));
    if (expectedRequestId != null &&
        [current, legacy]
            .whereType<String>()
            .any((id) => id != expectedRequestId)) {
      return false;
    }
    // SharedPreferences.remove 先摘内存缓存再落盘：存储层拒绝时缓存已空，
    // 单看 getString()==null 会误判清理成功，导致「暂未清理」永远不出现。
    // 因此同时看 remove 的返回值，任一失败即视为未清理。
    var persisted = true;
    for (final target in [
      key(binding),
      legacyKey(binding),
      createdAtKey(binding),
      estimatedAgeKey(binding),
    ]) {
      if (!preferences.containsKey(target)) continue;
      try {
        if (!await preferences.remove(target)) persisted = false;
      } catch (_) {
        persisted = false;
      }
    }
    return persisted &&
        preferences.getString(key(binding)) == null &&
        preferences.getString(legacyKey(binding)) == null;
  }
}
