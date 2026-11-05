import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/statistics_query.dart';

/// 2026-10-29 23:30 (UTC+8) 的 UTC 秒。
const int _now = 1793287800;
const int _tz = 28800;

void main() {
  group('预设查询边界', () {
    test('今日是从本地零点到 now，且仍算单日', () {
      final query = StatisticsQuery.today(now: _now, tzOffsetSeconds: _tz);
      expect(query.from, 1793203200);
      expect(query.to, _now);
      expect(query.to - query.from, lessThan(86400));
      // 关键：未满 24 小时也必须是单日，否则今日详情永远不可用。
      expect(query.singleDay, isTrue);
      expect(query.dayCount, 1);
    });

    test('昨日是完整 24 小时', () {
      final query = StatisticsQuery.yesterday(now: _now, tzOffsetSeconds: _tz);
      expect(query.to - query.from, 86400);
      expect(query.singleDay, isTrue);
      expect(query.to, 1793203200);
    });

    test('近7天包含今天共 7 个本地自然日', () {
      final query =
          StatisticsQuery.lastSevenDays(now: _now, tzOffsetSeconds: _tz);
      expect(query.dayCount, 7);
      expect(query.from, 1793203200 - 6 * 86400);
      expect(query.to, _now);
      expect(query.preset, StatisticsPreset.lastSevenDays);
    });

    test('自定义单日与范围按本地零点对齐', () {
      final day = DateTime(2026, 10, 29);
      final single =
          StatisticsQuery.day(day: day, tzOffsetSeconds: _tz);
      expect(single.to - single.from, 86400);
      expect(single.from, 1793203200); // 设备时区零点，不是手机时区
      expect(single.singleDay, isTrue);

      final span = StatisticsQuery.range(
        startDay: DateTime(2026, 10, 27),
        endDay: DateTime(2026, 11, 2),
        tzOffsetSeconds: _tz,
      );
      expect(span.dayCount, 7);
      expect(span.singleDay, isFalse);
    });
  });

  group('缓存键', () {
    test('今日刷新时查询键稳定，响应仍保留实际截止时间', () {
      final a = StatisticsQuery.today(now: _now, tzOffsetSeconds: _tz);
      final b = StatisticsQuery.today(now: _now + 59, tzOffsetSeconds: _tz);
      expect(a.cacheKey, b.cacheKey);
      final c = StatisticsQuery.today(now: _now + 60, tzOffsetSeconds: _tz);
      expect(a.cacheKey, c.cacheKey);
      expect(c.to, _now + 60);
    });

    test('缓存键不含 now，跨分钟仍稳定', () {
      final query = StatisticsQuery.yesterday(now: _now, tzOffsetSeconds: _tz);
      final later = StatisticsQuery.yesterday(now: _now + 120, tzOffsetSeconds: _tz);
      // 键只由 from/dayCount/是否整天/时区组成，to 的漂移不应改变它。
      expect(query.cacheKey, later.cacheKey);
    });

    test('自定义范围与预设不会互相覆盖', () {
      final preset = StatisticsQuery.today(now: _now, tzOffsetSeconds: _tz);
      final custom = StatisticsQuery.day(
        day: DateTime(2026, 10, 29),
        tzOffsetSeconds: _tz,
      );
      expect(preset.cacheKey, isNot(custom.cacheKey));
    });
  });

  test('时区偏移会改变本地零点与日序号', () {
    expect(StatisticsQuery.localDayStart(1793203200, 0), 1793145600);
    expect(StatisticsQuery.localDayStart(1793203200, _tz), 1793203200);
    expect(
      StatisticsQuery.localDayIndex(1793203200, 0),
      isNot(StatisticsQuery.localDayIndex(1793203200, _tz)),
    );
  });
}
