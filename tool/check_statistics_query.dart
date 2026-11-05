// 统计查询模型的独立校验脚本。
// 本机 flutter test 缺少 engine 产物，用 `dart run tool/check_statistics_query.dart` 跑同一组断言。
import 'dart:io';

import 'package:mimivent_app/data/statistics_query.dart';

const int _now = 1793287800; // 2026-10-29 23:30 (UTC+8)
const int _tz = 28800;

int _failures = 0;

void check(String name, bool condition, [String? detail]) {
  if (condition) {
    stdout.writeln('  ok   $name');
    return;
  }
  _failures++;
  stdout.writeln('  FAIL $name${detail == null ? '' : ' ($detail)'}');
}

void equal(String name, Object? actual, Object? expected) {
  check(name, actual == expected, 'expected $expected, got $actual');
}

void main() {
  stdout.writeln('预设查询边界');
  final today = StatisticsQuery.today(now: _now, tzOffsetSeconds: _tz);
  equal('今日 from = 本地零点', today.from, 1793203200);
  equal('今日 to = now', today.to, _now);
  check('今日未满 24 小时', today.to - today.from < 86400);
  check('今日仍算单日', today.singleDay);

  final yesterday = StatisticsQuery.yesterday(now: _now, tzOffsetSeconds: _tz);
  equal('昨日完整 24 小时', yesterday.to - yesterday.from, 86400);
  check('昨日单日', yesterday.singleDay);

  final week = StatisticsQuery.lastSevenDays(now: _now, tzOffsetSeconds: _tz);
  equal('近7天含今天共 7 天', week.dayCount, 7);
  equal('近7天 from', week.from, 1793203200 - 6 * 86400);
  check('近7天非单日', !week.singleDay);

  final single = StatisticsQuery.day(day: DateTime(2026, 10, 29), tzOffsetSeconds: _tz);
  equal('自定义单日 24 小时', single.to - single.from, 86400);
  equal('自定义单日按设备时区取零点', single.from, 1793203200);
  final span = StatisticsQuery.range(
    startDay: DateTime(2026, 10, 27),
    endDay: DateTime(2026, 11, 2),
    tzOffsetSeconds: _tz,
  );
  equal('自定义范围 7 天', span.dayCount, 7);

  stdout.writeln('缓存键');
  final a = StatisticsQuery.today(now: _now, tzOffsetSeconds: _tz);
  final b = StatisticsQuery.today(now: _now + 59, tzOffsetSeconds: _tz);
  check('同一分钟内键稳定', a.cacheKey == b.cacheKey, a.cacheKey);
  final c = StatisticsQuery.today(now: _now + 60, tzOffsetSeconds: _tz);
  check('跨分钟换键', a.cacheKey != c.cacheKey);
  equal('昨日键稳定（不含 now）', yesterday.cacheKey,
      StatisticsQuery.yesterday(now: _now + 300, tzOffsetSeconds: _tz).cacheKey);
  check('预设与自定义不互相覆盖', a.cacheKey != single.cacheKey);

  stdout.writeln('时区');
  equal('UTC 本地零点', StatisticsQuery.localDayStart(1793203200, 0), 1793145600);
  equal('UTC+8 本地零点', StatisticsQuery.localDayStart(1793203200, _tz), 1793203200);
  check('日序号随时区不同',
      StatisticsQuery.localDayIndex(1793203200, 0) !=
          StatisticsQuery.localDayIndex(1793203200, _tz));

  stdout.writeln(_failures == 0 ? '全部通过' : '$_failures 项失败');
  exit(_failures == 0 ? 0 : 1);
}
