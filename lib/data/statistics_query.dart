/// 统计查询模型。
///
/// App 只负责按文档 §10.0 生成 from/to 与口径判定；粒度由固件决定，
/// 客户端不传 bucketHours，也不自行推算桶边界。
library;

enum StatisticsPreset { today, yesterday, lastSevenDays }

const int _secondsPerDay = 86400;

class StatisticsQuery {
  const StatisticsQuery({
    required this.from,
    required this.to,
    required this.tzOffsetSeconds,
    this.preset,
  });

  /// UTC Unix 秒，左闭。
  final int from;

  /// UTC Unix 秒，右开。
  final int to;

  /// 设备固定时区偏移（秒）。必须原样来自 /api/status，App 不得自行推断。
  final int tzOffsetSeconds;

  /// 固定 Tab 的来源；自定义范围时为 null。
  final StatisticsPreset? preset;

  /// 本地日索引（自 1970-01-01 起的本地自然日序号）。
  static int localDayIndex(int epochSeconds, int tzOffsetSeconds) =>
      (epochSeconds + tzOffsetSeconds) ~/ _secondsPerDay;

  /// 该时刻所在本地日的零点（UTC 秒）。
  static int localDayStart(int epochSeconds, int tzOffsetSeconds) =>
      localDayIndex(epochSeconds, tzOffsetSeconds) * _secondsPerDay -
      tzOffsetSeconds;

  /// 覆盖的自然日数（含首尾）。to 是右开边界，故用 to - 1 定位最后一天。
  int get dayCount =>
      localDayIndex(to - 1, tzOffsetSeconds) -
      localDayIndex(from, tzOffsetSeconds) +
      1;

  /// 单日 = 覆盖 1 个本地自然日，与"是否满 24 小时"无关。
  /// 今日的 to = now 永远不满 24 小时，但它是单日，必须能看详情。
  bool get singleDay => dayCount == 1;

  bool get valid => to > from && from > 1700000000;

  /// 缓存键**不含 to**。
  ///
  /// 今日与近7天的 to 是 now，哪怕量化到分钟，跨分钟的那一帧也会算出一个新键，
  /// 导致 build 查不到刚存下的数据、回落到旧接口——表现就是"黄柱闪一下就没了"。
  /// 键只用 from、自然日数、是否整天与时区，这些在一次浏览期间都不变。
  String get cacheKey =>
      '$from-$dayCount-${to - from == _secondsPerDay ? 'full' : 'partial'}-$tzOffsetSeconds';

  factory StatisticsQuery.today({required int now, required int tzOffsetSeconds}) {
    final start = localDayStart(now, tzOffsetSeconds);
    return StatisticsQuery(
      from: start,
      to: now > start ? now : start + 1,
      tzOffsetSeconds: tzOffsetSeconds,
      preset: StatisticsPreset.today,
    );
  }

  factory StatisticsQuery.yesterday({
    required int now,
    required int tzOffsetSeconds,
  }) {
    final todayStart = localDayStart(now, tzOffsetSeconds);
    return StatisticsQuery(
      from: todayStart - _secondsPerDay,
      to: todayStart,
      tzOffsetSeconds: tzOffsetSeconds,
      preset: StatisticsPreset.yesterday,
    );
  }

  factory StatisticsQuery.lastSevenDays({
    required int now,
    required int tzOffsetSeconds,
  }) {
    final todayStart = localDayStart(now, tzOffsetSeconds);
    final start = todayStart - 6 * _secondsPerDay;
    return StatisticsQuery(
      from: start,
      to: now > start ? now : start + 1,
      tzOffsetSeconds: tzOffsetSeconds,
      preset: StatisticsPreset.lastSevenDays,
    );
  }

  /// 自定义单日：设备本地零点到次日本地零点。
  ///
  /// 用 UTC 构造"当天零点"再减去设备偏移——不能用手机时区偏移，
  /// 否则用户在国外选日期会整体偏几个小时。
  factory StatisticsQuery.day({
    required DateTime day,
    required int tzOffsetSeconds,
  }) {
    final utcMidnight =
        DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
            1000;
    final start = utcMidnight - tzOffsetSeconds;
    return StatisticsQuery(
      from: start,
      to: start + _secondsPerDay,
      tzOffsetSeconds: tzOffsetSeconds,
    );
  }

  /// 自定义日期范围：基于设备时区对齐到本地零点。
  factory StatisticsQuery.range({
    required DateTime startDay,
    required DateTime endDay,
    required int tzOffsetSeconds,
  }) {
    final first = StatisticsQuery.day(day: startDay, tzOffsetSeconds: tzOffsetSeconds);
    final last = StatisticsQuery.day(day: endDay, tzOffsetSeconds: tzOffsetSeconds);
    return StatisticsQuery(
      from: first.from,
      to: last.to,
      tzOffsetSeconds: tzOffsetSeconds,
    );
  }
}
