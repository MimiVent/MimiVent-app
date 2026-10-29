/// 统计缓存事件规则。
///
/// 汇总数据可以跨 App 版本保留；事件明细与设备事件 ID/数据批次绑定，
/// 格式变化或设备重置时必须单独失效，不能清除诊断日志等其他本地数据。
abstract final class StatisticsEventCache {
  /// 递增此版本会让旧版事件明细在恢复时失效，但保留汇总和图表缓存。
  static const int schemaVersion = 3;

  static Map<String, dynamic> keepCompatibleSnapshot(
      Map<String, dynamic> snapshot) {
    final data = Map<String, dynamic>.from(snapshot);
    if (data['eventsIdentityVersion'] == schemaVersion) return data;

    data
      ..remove('events')
      ..['eventsIdentityVersion'] = schemaVersion
      ..['eventsTotal'] = 0
      ..['eventsNextOffset'] = 0
      ..['eventsNextCursor'] = 0
      ..['eventsHasMore'] = false;
    return data;
  }

  /// 判断新查询首屏是否来自不同事件数据集。
  ///
  /// 新固件可用 dataEpoch 做精确识别。旧固件没有批次字段时，使用总数和
  /// 单调事件 ID 回退识别清空/重建后的 ID 回绕，避免把旧缓存拼回新列表。
  static bool shouldDiscardPrevious({
    required List<Map<String, dynamic>> previous,
    required List<Map<String, dynamic>> incoming,
    required int incomingTotal,
    required bool sameWindow,
    required bool firstPage,
    String? previousDataEpoch,
    String? incomingDataEpoch,
    String? previousDeviceId,
    String? incomingDeviceId,
  }) {
    if (previous.isEmpty) return false;
    if (!sameWindow) return true;

    final oldDevice = previousDeviceId?.trim() ?? '';
    final newDevice = incomingDeviceId?.trim() ?? '';
    if (oldDevice.isNotEmpty &&
        newDevice.isNotEmpty &&
        oldDevice != newDevice) {
      return true;
    }

    final oldEpoch = previousDataEpoch?.trim() ?? '';
    final newEpoch = incomingDataEpoch?.trim() ?? '';
    if (oldEpoch.isNotEmpty && newEpoch.isNotEmpty && oldEpoch != newEpoch) {
      return true;
    }
    if (!firstPage) return false;

    // 同一查询窗口的总事件数不应小于已经缓存的明细数；出现时旧页已过期。
    // 未校时/接口异常可能返回空页和 total=0；不能据此清掉唯一的离线明细缓存。
    if (incomingTotal > 0 && incomingTotal < previous.length) return true;

    final oldMaxId = _maximumId(previous);
    final newMaxId = _maximumId(incoming);
    // 事件 ID 单调递增。首屏最大 ID 倒退说明设备数据被重置或重新初始化。
    if (oldMaxId > 0 && newMaxId > 0 && newMaxId < oldMaxId) return true;

    // 兼容 ID 重用但总量暂时相同的旧固件：同一 ID 对应不同时间/类型即视为新批次。
    final oldById = <int, Map<String, dynamic>>{
      for (final event in previous)
        if (event['id'] is num) (event['id'] as num).toInt(): event,
    };
    for (final event in incoming) {
      final id = event['id'];
      if (id is! num) continue;
      final old = oldById[id.toInt()];
      if (old != null &&
          (old['time'] != event['time'] || old['kind'] != event['kind'])) {
        return true;
      }
    }
    return false;
  }

  static int _maximumId(List<Map<String, dynamic>> events) {
    var maximum = 0;
    for (final event in events) {
      final id = event['id'];
      if (id is num && id.toInt() > maximum) maximum = id.toInt();
    }
    return maximum;
  }

  /// 首屏刷新若检测到批次变化，只保留设备刚返回的新列表。
  ///
  /// 此方法单独定义是为了让“缓存失效后不复活旧事件”成为可测试规则。
  static List<Map<String, dynamic>> mergeFirstPage({
    required List<Map<String, dynamic>> previous,
    required List<Map<String, dynamic>> incoming,
    required bool discardPrevious,
  }) =>
      discardPrevious
          ? List<Map<String, dynamic>>.of(incoming)
          : [...incoming, ...previous];
}
