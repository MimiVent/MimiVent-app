import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/mimivent_theme.dart';
import '../../../data/mimivent_controller.dart';

/// 统计页的时间范围。第一版提供常用预设，避免日期选择器占用空间。
enum _StatisticsRange { today, yesterday, threeDays, sevenDays }

extension on _StatisticsRange {
  String get wireValue => switch (this) {
        _StatisticsRange.today => 'today',
        _StatisticsRange.yesterday => 'yesterday',
        _StatisticsRange.threeDays => 'threeDays',
        _StatisticsRange.sevenDays => 'sevenDays',
      };
}

class StatisticsPage extends StatefulWidget {
  const StatisticsPage(
      {required this.controller, required this.active, super.key});

  final MimiVentController controller;
  final bool active;

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  _StatisticsRange _range = _StatisticsRange.sevenDays;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _updateRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant StatisticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (oldWidget.active != widget.active) _updateRefreshTimer();
  }

  void _updateRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!widget.active) return;
    unawaited(_loadStatistics());
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_loadStatistics());
    });
  }

  Future<void> _loadStatistics() =>
      widget.controller.refreshStatistics(_range.wireValue);

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.controller.statisticsFor(_range.wireValue);
    final view = data == null
        ? _StatisticsPreview.emptyForRange(_range)
        : _StatisticsPreview.fromDevice(_range, data);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(0.0, 860.0);
        return ListView(
          key: const PageStorageKey('statistics-page'),
          primary: false,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _pageHeading(),
                    const SizedBox(height: 8),
                    _syncStatus(data),
                    const SizedBox(height: 8),
                    _rangePicker(),
                    const SizedBox(height: 14),
                    _summaryCard(view),
                    const SizedBox(height: 12),
                    _metricRow(view),
                    const SizedBox(height: 16),
                    _runtimeChart(view),
                    const SizedBox(height: 16),
                    if (_range == _StatisticsRange.today)
                      _eventList(view.events)
                    else
                      _dailyBreakdown(view.days),
                    const SizedBox(height: 4),
                    const Center(
                      child: Text(
                        '感应活动仅代表 PIR 检测到移动，不等同于如厕次数',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: MimiVentColors.muted,
                          fontSize: 10,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _pageHeading() => const Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '使用统计',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '看看 MimiVent 最近的运行情况',
                  style: TextStyle(color: MimiVentColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          Icon(Icons.insights_rounded, color: MimiVentColors.mint, size: 20),
        ],
      );

  Widget _syncStatus(Map<String, dynamic>? data) {
    final loading = widget.controller.statisticsLoadingFor(_range.wireValue);
    final failed = widget.controller.statisticsFailedFor(_range.wireValue);
    final label = failed
        ? '同步暂不可用 · 将自动重试'
        : loading
            ? '正在同步设备数据'
            : data == null
                ? '等待首次同步'
                : '设备数据已同步 · 每分钟更新';
    final color = failed ? MimiVentColors.amber : MimiVentColors.mint;
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: loading
                ? CircularProgressIndicator(
                    strokeWidth: 1.7,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  )
                : Icon(
                    failed
                        ? Icons.sync_problem_rounded
                        : Icons.cloud_done_rounded,
                    size: 14,
                    color: color.withOpacity(data == null ? .45 : .8),
                  ),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: MimiVentColors.muted,
              fontSize: 10,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangePicker() => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1916),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withOpacity(.055)),
        ),
        child: Row(
          children: _StatisticsRange.values.map((range) {
            final selected = range == _range;
            return Expanded(
              child: Semantics(
                button: true,
                selected: selected,
                label: _rangeLabel(range),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () {
                    setState(() => _range = range);
                    unawaited(_loadStatistics());
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 37,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? MimiVentColors.mint.withOpacity(.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(11),
                      border: selected
                          ? Border.all(
                              color: MimiVentColors.mint.withOpacity(.2))
                          : null,
                    ),
                    child: Text(
                      _rangeLabel(range),
                      maxLines: 1,
                      style: TextStyle(
                        color: selected
                            ? MimiVentColors.mint
                            : MimiVentColors.muted,
                        fontSize: 10,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );

  Widget _summaryCard(_StatisticsPreview view) => Container(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        decoration: _cardDecoration(accent: MimiVentColors.mint),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('风机累计运行',
                      style: TextStyle(
                          color: MimiVentColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
                _dateRangePill(view.rangeText),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  view.runtimeMain,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.1,
                    height: 1,
                  ),
                ),
                if (view.runtimeUnit.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(view.runtimeUnit,
                        style: const TextStyle(
                            color: MimiVentColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
                const Spacer(),
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: MimiVentColors.mint.withOpacity(.10),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.air_rounded,
                      color: MimiVentColors.mint, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(view.runtimeCaption,
                style: const TextStyle(
                    color: MimiVentColors.muted, fontSize: 10, height: 1.3)),
          ],
        ),
      );

  Widget _metricRow(_StatisticsPreview view) => Row(
        children: [
          Expanded(
            child: _metricCard(
              icon: Icons.motion_photos_on_rounded,
              title: '感应活动段',
              value: '${view.activityCount}',
              unit: '次',
              accent: MimiVentColors.mint,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _metricCard(
              icon: Icons.air_rounded,
              title: '自动排风',
              value: '${view.autoExhaustCount}',
              unit: '次',
              accent: MimiVentColors.amber,
            ),
          ),
        ],
      );

  Widget _metricCard({
    required IconData icon,
    required String title,
    required String value,
    required String unit,
    required Color accent,
  }) =>
      Container(
        padding: const EdgeInsets.all(13),
        decoration: _cardDecoration(),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                  color: accent.withOpacity(.11), shape: BoxShape.circle),
              child: Icon(icon, color: accent, size: 15),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 10)),
                  const SizedBox(height: 5),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(value,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              height: 1)),
                      const SizedBox(width: 4),
                      Text(unit,
                          style: const TextStyle(
                              color: MimiVentColors.muted, fontSize: 9)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _runtimeChart(_StatisticsPreview view) => Container(
        padding: const EdgeInsets.fromLTRB(15, 14, 15, 12),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(view.chartTitle,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                      color: MimiVentColors.mint, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                const Text('风机运行',
                    style: TextStyle(color: MimiVentColors.muted, fontSize: 9)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 142,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: view.chart.map((point) {
                  final fraction = view.maxChartValue == 0
                      ? 0.0
                      : point.minutes / view.maxChartValue;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: view.chart.length > 18
                              ? .5
                              : view.chart.length > 9
                                  ? 1
                                  : 3),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 16,
                            child: Text(
                              point.minutes > 0 ? '${point.minutes}m' : '',
                              maxLines: 1,
                              style: const TextStyle(
                                  color: MimiVentColors.muted,
                                  fontSize: 8,
                                  height: 1),
                            ),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: fraction == 0
                                    ? 0
                                    : fraction.clamp(.035, 1.0).toDouble(),
                                child: Container(
                                  width: view.chart.length > 18
                                      ? 7
                                      : view.chart.length > 9
                                          ? 12
                                          : 18,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        MimiVentColors.mint,
                                        MimiVentColors.mint.withOpacity(.32),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(7),
                                    boxShadow: fraction > .62
                                        ? [
                                            BoxShadow(
                                              color: MimiVentColors.mint
                                                  .withOpacity(.13),
                                              blurRadius: 10,
                                            )
                                          ]
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(point.label,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.clip,
                              style: const TextStyle(
                                  color: MimiVentColors.muted,
                                  fontSize: 7,
                                  height: 1.05)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            Text(view.chartCaption,
                style:
                    const TextStyle(color: MimiVentColors.muted, fontSize: 9)),
          ],
        ),
      );

  Widget _dailyBreakdown(List<_DailySummary> days) => Container(
        padding: const EdgeInsets.fromLTRB(15, 14, 15, 5),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('按日概览',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 7),
            for (var i = 0; i < days.length; i++) ...[
              _dailySummaryRow(days[i]),
              if (i != days.length - 1)
                Divider(height: 1, color: Colors.white.withOpacity(.055)),
            ],
          ],
        ),
      );

  Widget _dailySummaryRow(_DailySummary day) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: MimiVentColors.mint.withOpacity(.1),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.calendar_today_rounded,
                  color: MimiVentColors.mint, size: 14),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(day.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text('活动 ${day.activityCount} 次  ·  排风 ${day.exhaustCount} 次',
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 9)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('${day.runtimeMinutes} 分钟',
                style: const TextStyle(
                    color: MimiVentColors.mint,
                    fontSize: 10,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _eventList(List<_PreviewEvent> events) => Container(
        padding: const EdgeInsets.fromLTRB(15, 14, 15, 5),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('最近事件',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                Text('${events.length} 条',
                    style: const TextStyle(
                        color: MimiVentColors.muted, fontSize: 9)),
              ],
            ),
            const SizedBox(height: 7),
            for (var i = 0; i < events.length; i++) ...[
              _eventRow(events[i]),
              if (i != events.length - 1)
                Divider(height: 1, color: Colors.white.withOpacity(.055)),
            ],
          ],
        ),
      );

  Widget _eventRow(_PreviewEvent event) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Container(
              width: 31,
              height: 31,
              decoration: BoxDecoration(
                color: event.color.withOpacity(.11),
                shape: BoxShape.circle,
              ),
              child: Icon(event.icon, size: 14, color: event.color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(event.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 9)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(event.time,
                style: const TextStyle(
                    color: MimiVentColors.muted,
                    fontSize: 9,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      );

  Widget _dateRangePill(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.045),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: const TextStyle(
                color: MimiVentColors.muted,
                fontSize: 9,
                fontWeight: FontWeight.w500)),
      );

  BoxDecoration _cardDecoration({Color? accent}) => BoxDecoration(
        color: MimiVentColors.surface.withOpacity(.88),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(
          color:
              (accent ?? Colors.white).withOpacity(accent == null ? .07 : .14),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.12),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      );

  String _rangeLabel(_StatisticsRange range) => switch (range) {
        _StatisticsRange.today => '今日',
        _StatisticsRange.yesterday => '昨日',
        _StatisticsRange.threeDays => '近 3 天',
        _StatisticsRange.sevenDays => '近 7 天',
      };
}

/// 统计页面的显示模型，空状态只生成固定布局所需的零值占位，不展示虚构记录。
class _StatisticsPreview {
  const _StatisticsPreview({
    required this.rangeText,
    required this.runtimeMain,
    required this.runtimeUnit,
    required this.runtimeCaption,
    required this.activityCount,
    required this.autoExhaustCount,
    required this.chart,
    required this.maxChartValue,
    required this.chartTitle,
    required this.chartCaption,
    required this.events,
    required this.days,
  });

  final String rangeText;
  final String runtimeMain;
  final String runtimeUnit;
  final String runtimeCaption;
  final int activityCount;
  final int autoExhaustCount;
  final List<_ChartPoint> chart;
  final double maxChartValue;
  final String chartTitle;
  final String chartCaption;
  final List<_PreviewEvent> events;
  final List<_DailySummary> days;

  factory _StatisticsPreview.emptyForRange(_StatisticsRange range) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOffset = switch (range) {
      _StatisticsRange.today => 0,
      _StatisticsRange.yesterday => 1,
      _StatisticsRange.threeDays => 2,
      _StatisticsRange.sevenDays => 6,
    };
    final start = today.subtract(Duration(days: startOffset));
    final dayCount = switch (range) {
      _StatisticsRange.today || _StatisticsRange.yesterday => 1,
      _StatisticsRange.threeDays => 3,
      _StatisticsRange.sevenDays => 7,
    };
    final chart = switch (range) {
      _StatisticsRange.today => List.generate(
          24, (index) => _ChartPoint(index.toString().padLeft(2, '0'), 0)),
      _StatisticsRange.yesterday => List.generate(12,
          (index) => _ChartPoint((index * 2).toString().padLeft(2, '0'), 0)),
      _StatisticsRange.threeDays => List.generate(9, (index) {
          final day = start.add(Duration(days: index ~/ 3));
          final hour = (index % 3) * 8;
          return _ChartPoint(
              index % 3 == 0
                  ? '${day.day}\\n${hour.toString().padLeft(2, '0')}'
                  : hour.toString().padLeft(2, '0'),
              0);
        }),
      _StatisticsRange.sevenDays => List.generate(7, (index) {
          final date = start.add(Duration(days: index));
          return _ChartPoint('${date.month}/${date.day}', 0);
        }),
    };
    final days = List.generate(dayCount, (index) {
      final date = range == _StatisticsRange.yesterday
          ? start
          : range == _StatisticsRange.today
              ? today
              : start.add(Duration(days: index));
      return _DailySummary(
        label: _dayLabel(date, today),
        activityCount: 0,
        exhaustCount: 0,
        runtimeMinutes: 0,
      );
    });
    return _StatisticsPreview(
      rangeText: range == _StatisticsRange.today
          ? _date(today)
          : range == _StatisticsRange.yesterday
              ? _date(start)
              : '${_date(start)} — ${_date(today)}',
      runtimeMain: '0',
      runtimeUnit: '分钟',
      runtimeCaption: '等待设备统计数据',
      activityCount: 0,
      autoExhaustCount: 0,
      chart: chart,
      maxChartValue: 0,
      chartTitle: range == _StatisticsRange.sevenDays ? '每日排风时长' : '分时排风时长',
      chartCaption: switch (range) {
        _StatisticsRange.today => '每柱代表 1 小时 · 单位：分钟',
        _StatisticsRange.yesterday => '每柱代表 2 小时 · 单位：分钟',
        _StatisticsRange.threeDays => '每柱代表 8 小时 · 日期标在当天首个时段',
        _StatisticsRange.sevenDays => '每柱代表 1 天 · 单位：分钟',
      },
      events: const [],
      days: days,
    );
  }

  factory _StatisticsPreview.fromDevice(
    _StatisticsRange range,
    Map<String, dynamic> json,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final runtimeSeconds = _intValue(json['runtimeSeconds']);
    final runtimeMain = runtimeSeconds >= 3600
        ? '${runtimeSeconds ~/ 3600} 小时 ${(runtimeSeconds % 3600) ~/ 60}'
        : runtimeSeconds >= 60
            ? (runtimeSeconds / 60)
                .toStringAsFixed(runtimeSeconds % 60 == 0 ? 0 : 1)
            : '$runtimeSeconds';
    final runtimeUnit = runtimeSeconds >= 3600
        ? '分'
        : runtimeSeconds >= 60
            ? '分钟'
            : '秒';

    final rawBuckets = json['bucketSeconds'];
    final bucketSeconds =
        rawBuckets is List ? rawBuckets.map(_intValue).toList() : <int>[];
    final rawDays = json['days'];
    final dayRows = rawDays is List
        ? rawDays
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .toList()
        : <Map<String, dynamic>>[];

    late final List<_ChartPoint> chart;
    if (range == _StatisticsRange.today) {
      chart = List.generate(
          24,
          (index) => _ChartPoint(
                index.toString().padLeft(2, '0'),
                (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
              ));
    } else if (range == _StatisticsRange.yesterday) {
      chart = List.generate(
          12,
          (index) => _ChartPoint(
                (index * 2).toString().padLeft(2, '0'),
                (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
              ));
    } else if (range == _StatisticsRange.threeDays) {
      final firstDate = today.subtract(const Duration(days: 2));
      chart = List.generate(9, (index) {
        final day = firstDate.add(Duration(days: index ~/ 3));
        final hour = (index % 3) * 8;
        final label = index % 3 == 0
            ? '${day.day}\n${hour.toString().padLeft(2, '0')}'
            : hour.toString().padLeft(2, '0');
        return _ChartPoint(label,
            (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60);
      });
    } else {
      final firstDate = today.subtract(const Duration(days: 6));
      chart = List.generate(7, (index) {
        final date = index < dayRows.length
            ? _dateFromKey(_intValue(dayRows[index]['date']))
            : firstDate.add(Duration(days: index));
        return _ChartPoint('${date.month}/${date.day}',
            (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60);
      });
    }

    final events = <_PreviewEvent>[];
    final rawEvents = json['events'];
    if (rawEvents is List) {
      for (final item in rawEvents.whereType<Map>()) {
        final event = item.cast<String, dynamic>();
        final timestamp = DateTime.fromMillisecondsSinceEpoch(
          _intValue(event['time']) * 1000,
          isUtc: true,
        ).toLocal();
        final kind = event['kind']?.toString() ?? 'automatic';
        final state = event['state']?.toString() ?? 'complete';
        final duration = _intValue(event['durationSeconds']);
        final title = switch (kind) {
          'activity' => '检测到活动',
          'manual' => '临时排风',
          'force' => '强制排风',
          _ => '自动排风',
        };
        final detail = state == 'active'
            ? '正在运行 · ${_durationLabel(duration)}'
            : state == 'interrupted'
                ? '设备重启时中断'
                : kind == 'activity'
                    ? 'PIR 检测到活动'
                    : '运行 ${_durationLabel(duration)}';
        events.add(_PreviewEvent(
          time:
              '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}',
          title: title,
          detail: detail,
          icon: kind == 'activity'
              ? Icons.motion_photos_on_rounded
              : Icons.air_rounded,
          color:
              kind == 'activity' ? MimiVentColors.amber : MimiVentColors.mint,
        ));
      }
    }

    final days = <_DailySummary>[];
    for (final day in dayRows) {
      final date = _dateFromKey(_intValue(day['date']));
      days.add(_DailySummary(
        label: _dayLabel(date, today),
        activityCount: _intValue(day['activityCount']),
        exhaustCount: _intValue(day['automaticCount']),
        runtimeMinutes: _intValue(day['runtimeSeconds']) ~/ 60,
      ));
    }
    final maxValue = chart.fold<double>(
        0, (max, point) => point.minutes > max ? point.minutes : max);
    final rangeText = range == _StatisticsRange.today
        ? _date(today)
        : range == _StatisticsRange.yesterday
            ? _date(today.subtract(const Duration(days: 1)))
            : '${_date(today.subtract(Duration(days: range == _StatisticsRange.threeDays ? 2 : 6)))} — ${_date(today)}';

    return _StatisticsPreview(
      rangeText: rangeText,
      runtimeMain: runtimeMain,
      runtimeUnit: runtimeUnit,
      runtimeCaption: json['timeSynced'] == true
          ? (json['active'] == true
              ? '风机累计运行时长 · 含当前运行和手动排风'
              : '风机累计运行时长 · 含手动排风')
          : '设备时间待校准；校准后回填本次开机以来的统计',
      activityCount: _intValue(json['activityCount']),
      autoExhaustCount: _intValue(json['automaticCount']),
      chart: chart,
      maxChartValue: maxValue,
      chartTitle: range == _StatisticsRange.sevenDays ? '每日排风时长' : '分时排风时长',
      chartCaption: switch (range) {
        _StatisticsRange.today => '每柱代表 1 小时 · 单位：分钟',
        _StatisticsRange.yesterday => '每柱代表 2 小时 · 单位：分钟',
        _StatisticsRange.threeDays => '每柱代表 8 小时 · 日期标在当天首个时段',
        _StatisticsRange.sevenDays => '每柱代表 1 天 · 单位：分钟',
      },
      events: events,
      days: days,
    );
  }

  static int _intValue(Object? value) => value is num ? value.toInt() : 0;

  static DateTime _dateFromKey(int key) =>
      DateTime(key ~/ 10000, (key ~/ 100) % 100, key % 100);

  static String _durationLabel(int seconds) =>
      seconds >= 60 ? '${seconds ~/ 60} 分钟' : '$seconds 秒';

  static String _date(DateTime date) =>
      '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';

  static String _dayLabel(DateTime date, DateTime today) {
    final sameDate = date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    final yesterday = today.subtract(const Duration(days: 1));
    final isYesterday = date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day;
    final suffix = sameDate
        ? ' 今天'
        : isYesterday
            ? ' 昨天'
            : '';
    return '${date.month}月${date.day}日$suffix';
  }
}

class _ChartPoint {
  const _ChartPoint(this.label, this.minutes);

  final String label;
  final double minutes;
}

class _PreviewEvent {
  const _PreviewEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String time;
  final String title;
  final String detail;
  final IconData icon;
  final Color color;
}

class _DailySummary {
  const _DailySummary({
    required this.label,
    required this.activityCount,
    required this.exhaustCount,
    required this.runtimeMinutes,
  });

  final String label;
  final int activityCount;
  final int exhaustCount;
  final int runtimeMinutes;
}
