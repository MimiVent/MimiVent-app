import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/mimivent_theme.dart';
import '../../../data/mimivent_controller.dart';
import '../../../shared/widgets/version_compatibility_notice.dart';
import '../../../shared/widgets/device_animations.dart';

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
      {required this.controller,
      required this.active,
      required this.appVersion,
      super.key});

  final MimiVentController controller;
  final bool active;
  final String appVersion;

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  bool get _readOnly =>
      widget.controller.offlineViewing || !widget.controller.connected;
  bool get _canSynchronize =>
      widget.active &&
      !_readOnly &&
      widget.controller.status != null &&
      widget.controller.settings != null;

  _StatisticsRange _range = _StatisticsRange.today;
  int? _selectedChartIndex;
  Timer? _refreshTimer;
  bool _loadingMoreEvents = false;
  bool _refreshEnabled = false;

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
    _refreshEnabled = _canSynchronize;
    if (!_refreshEnabled) return;
    // 切换 Tab 或重连可能发生于父级构建期间，延后到帧末再通知加载状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _canSynchronize) unawaited(_loadStatistics());
    });
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_loadStatistics());
    });
  }

  Future<void> _loadStatistics() =>
      widget.controller.refreshStatistics(_range.wireValue);

  bool _onScrollNotification(ScrollNotification notification) {
    final supportsEventPages = _range == _StatisticsRange.today ||
        _range == _StatisticsRange.yesterday;
    if (widget.controller.connected &&
        !widget.controller.offlineViewing &&
        supportsEventPages &&
        notification.metrics.extentAfter < 180 &&
        !_loadingMoreEvents &&
        widget.controller.statisticsHasMoreEventsFor(_range.wireValue)) {
      _loadMoreEvents();
    }
    // 继续向外冒泡，避免影响 Dashboard 的滚动标题行为。
    return false;
  }

  Future<void> _loadMoreEvents() async {
    setState(() => _loadingMoreEvents = true);
    try {
      await widget.controller.loadMoreStatisticsEvents(_range.wireValue);
    } finally {
      if (mounted) setState(() => _loadingMoreEvents = false);
    }
  }

  void _onControllerChanged() {
    final canRefresh = _canSynchronize;
    if (canRefresh != _refreshEnabled) _updateRefreshTimer();
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
        : _StatisticsPreview.fromDevice(_range, data,
            currentMode: widget.controller.status?.mode,
            snapshotOnly: _readOnly);
    return NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: LayoutBuilder(
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
                        if (widget.controller.status != null)
                          VersionCompatibilityNotice(
                            appVersion: widget.appVersion,
                            firmwareVersion: widget.controller.status!.firmware,
                            minimumAppVersion:
                                widget.controller.status!.minimumAppVersion,
                          ),
                        _pageHeading(),
                        const SizedBox(height: 8),
                        _syncStatus(data),
                        const SizedBox(height: 8),
                        _rangePicker(),
                        const SizedBox(height: 14),
                        if (_readOnly && data == null)
                          _offlineEmptyState()
                        else ...[
                          _summaryCard(view),
                          const SizedBox(height: 12),
                          _metricRow(view),
                          const SizedBox(height: 16),
                          _runtimeChart(view),
                          const SizedBox(height: 16),
                          if (data?['eventsTruncated'] == true)
                            const _EventPaginationHint(
                                label: '部分历史明细已淘汰，图表与累计时长仍保留完整汇总'),
                          if (_range == _StatisticsRange.today ||
                              _range == _StatisticsRange.yesterday)
                            _eventList(
                              view.events,
                              title: _range == _StatisticsRange.today
                                  ? '今日事件'
                                  : '昨日事件',
                              rawCount: view.rawEventCount,
                              totalCount: view.eventTotal,
                              hasMore: view.eventsHasMore,
                              loadingMore: _loadingMoreEvents,
                            )
                          else
                            _dailyBreakdown(view.days),
                        ],
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
        ));
  }

  Widget _pageHeading() => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '使用统计',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _readOnly ? '查看上次同步快照，日期以卡片显示为准' : '看看 MimiVent 最近的运行情况',
                  style: const TextStyle(
                      color: MimiVentColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const Icon(Icons.insights_rounded,
              color: MimiVentColors.mint, size: 20),
        ],
      );

  Widget _offlineEmptyState() => Container(
        key: const ValueKey('offline-statistics-empty'),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 36),
        decoration: _cardDecoration(),
        child: const Column(children: [
          Icon(Icons.bar_chart_rounded, size: 32, color: MimiVentColors.muted),
          SizedBox(height: 14),
          Text('此范围暂无缓存',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          SizedBox(height: 8),
          Text('连接设备并查看相应时间范围后，会自动保存统计快照。\n离线模式仅展示已下载的数据。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: MimiVentColors.muted, fontSize: 12, height: 1.6)),
        ]),
      );

  Widget _syncStatus(Map<String, dynamic>? data) {
    final loading = widget.controller.statisticsLoadingFor(_range.wireValue);
    final failed = widget.controller.statisticsFailedFor(_range.wireValue);
    final cached = widget.controller.statisticsIsCachedFor(_range.wireValue);
    final cachedAt =
        widget.controller.statisticsCacheUpdatedAtFor(_range.wireValue);
    final cachedAtLabel = cachedAt == null
        ? ''
        : ' · ${cachedAt.month}/${cachedAt.day} ${cachedAt.hour.toString().padLeft(2, '0')}:${cachedAt.minute.toString().padLeft(2, '0')}';
    final offline = _readOnly;
    final label = offline
        ? data == null
            ? '离线只读 · 此范围尚未缓存'
            : cachedAt == null
                ? '离线缓存 · 更新时间未知'
                : '离线缓存$cachedAtLabel'
        : failed
            ? cached
                ? '同步失败 · 显示上次数据$cachedAtLabel'
                : '同步暂不可用 · 将自动重试'
            : loading
                ? cached
                    ? '显示本地缓存 · 正在更新$cachedAtLabel'
                    : '正在同步设备数据'
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
                    offline
                        ? Icons.offline_bolt_outlined
                        : failed
                            ? Icons.sync_problem_rounded
                            : Icons.cloud_done_rounded,
                    size: 14,
                    color: color.withOpacity(data == null ? .45 : .8),
                  ),
          ),
          const SizedBox(width: 7),
          Expanded(
              child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: MimiVentColors.muted,
              fontSize: 10,
              height: 1,
            ),
          )),
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
                    setState(() {
                      _range = range;
                      _selectedChartIndex = null;
                      _loadingMoreEvents = false;
                    });
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

  Widget _runtimeChart(_StatisticsPreview view) {
    final selectedIndex =
        _selectedChartIndex != null && _selectedChartIndex! < view.chart.length
            ? _selectedChartIndex!
            : null;
    final selectedPoint =
        selectedIndex == null ? null : view.chart[selectedIndex];
    return Container(
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
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: selectedPoint == null
                ? const Text(
                    '点击图表查看该时段排风时长',
                    style: TextStyle(
                        color: MimiVentColors.muted, fontSize: 10, height: 1.4),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Text(
                          selectedPoint.intervalLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: MimiVentColors.muted, fontSize: 10),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_formatMinutes(selectedPoint.minutes)} 分钟',
                        style: const TextStyle(
                            color: MimiVentColors.mint,
                            fontSize: 11,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
          ),
          SizedBox(
            height: 168,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final chartSize = Size(constraints.maxWidth, 168);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    const leftInset = _StatisticsChartPainter.leftInset;
                    final plotWidth = chartSize.width - leftInset - 5;
                    final x = details.localPosition.dx - leftInset;
                    if (plotWidth <= 0 || x < 0 || x > plotWidth) return;
                    final index = (x / plotWidth * view.chart.length)
                        .floor()
                        .clamp(0, view.chart.length - 1);
                    setState(() => _selectedChartIndex = index);
                  },
                  child: CustomPaint(
                    size: chartSize,
                    painter: _StatisticsChartPainter(
                      points: view.chart,
                      maxValue: view.maxChartValue,
                      selectedIndex: selectedIndex,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Text(view.chartCaption,
              style: const TextStyle(color: MimiVentColors.muted, fontSize: 9)),
        ],
      ),
    );
  }

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

  Widget _eventList(
    List<_PreviewEvent> events, {
    required String title,
    required int rawCount,
    required int totalCount,
    required bool hasMore,
    required bool loadingMore,
  }) =>
      Container(
        padding: const EdgeInsets.fromLTRB(15, 14, 15, 5),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                Text('${events.length} 组 · $rawCount/$totalCount 条',
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
            if (loadingMore)
              const _EventPaginationHint(label: '正在加载更多原始事件…', loading: true)
            else if (_readOnly && hasMore)
              const _EventPaginationHint(label: '仅显示已缓存事件，连接设备可加载其余记录')
            else if (hasMore)
              const _EventPaginationHint(label: '继续上滑加载更早事件')
            else if (rawCount > 0)
              const _EventPaginationHint(label: '已显示全部可用事件'),
          ],
        ),
      );

  Widget _eventRow(_PreviewEvent event) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: SizedBox.square(dimension: 16, child: event.icon),
              ),
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
    required this.rawEventCount,
    required this.eventTotal,
    required this.eventsHasMore,
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
  final int rawEventCount;
  final int eventTotal;
  final bool eventsHasMore;
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
          24,
          (index) => _ChartPoint(index.toString().padLeft(2, '0'), 0,
              intervalLabel: _hourInterval(index, 1))),
      _StatisticsRange.yesterday => List.generate(
          12,
          (index) => _ChartPoint((index * 2).toString().padLeft(2, '0'), 0,
              intervalLabel: _hourInterval(index * 2, 2))),
      _StatisticsRange.threeDays => List.generate(9, (index) {
          final day = start.add(Duration(days: index ~/ 3));
          final hour = (index % 3) * 8;
          return _ChartPoint(hour.toString().padLeft(2, '0'), 0,
              intervalLabel: '${_date(day)} ${_hourInterval(hour, 8)}',
              groupLabel: _date(day));
        }),
      _StatisticsRange.sevenDays => List.generate(7, (index) {
          final date = start.add(Duration(days: index));
          return _ChartPoint('${date.month}/${date.day}', 0,
              intervalLabel: '${_date(date)} 00:00–24:00');
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
      rawEventCount: 0,
      eventTotal: 0,
      eventsHasMore: false,
      days: days,
    );
  }

  factory _StatisticsPreview.fromDevice(
      _StatisticsRange range, Map<String, dynamic> json,
      {String? currentMode, bool snapshotOnly = false}) {
    final cachedAtMs = _intValue(json['_cacheUpdatedAt']);
    final now = cachedAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(cachedAtMs)
        : DateTime.now();
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
                intervalLabel: _hourInterval(index, 1),
              ));
    } else if (range == _StatisticsRange.yesterday) {
      chart = List.generate(
          12,
          (index) => _ChartPoint(
                (index * 2).toString().padLeft(2, '0'),
                (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
                intervalLabel: _hourInterval(index * 2, 2),
              ));
    } else if (range == _StatisticsRange.threeDays) {
      final firstDate = today.subtract(const Duration(days: 2));
      chart = List.generate(9, (index) {
        final day = firstDate.add(Duration(days: index ~/ 3));
        final hour = (index % 3) * 8;
        return _ChartPoint(hour.toString().padLeft(2, '0'),
            (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
            intervalLabel: '${_date(day)} ${_hourInterval(hour, 8)}',
            groupLabel: _date(day));
      });
    } else {
      final firstDate = today.subtract(const Duration(days: 6));
      chart = List.generate(7, (index) {
        final date = index < dayRows.length
            ? _dateFromKey(_intValue(dayRows[index]['date']))
            : firstDate.add(Duration(days: index));
        return _ChartPoint('${date.month}/${date.day}',
            (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
            intervalLabel: '${_date(date)} 00:00–24:00');
      });
    }

    final chronologicalEvents = <_PreviewEvent>[];
    final rawEvents = json['events'];
    if (rawEvents is List) {
      // 设备接口按事件 ID 从新到旧返回；按 ID 还原记录顺序后再合并感应段。
      final source = rawEvents.whereType<Map>().toList().reversed.toList();
      final ordered =
          source.map((event) => Map<String, dynamic>.from(event)).toList();
      if (ordered.every((event) => event['id'] is num)) {
        ordered
            .sort((a, b) => _intValue(a['id']).compareTo(_intValue(b['id'])));
      } else {
        // 兼容没有事件 ID 的旧固件；按时间排序，并保持同秒记录原有顺序。
        final indexed = ordered.asMap().entries.toList();
        indexed.sort((a, b) {
          final byTime =
              _intValue(a.value['time']).compareTo(_intValue(b.value['time']));
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });
        ordered
          ..clear()
          ..addAll(indexed.map((entry) => entry.value));
      }
      DateTime? nextControlEventTime(int fromIndex) {
        for (var next = fromIndex + 1; next < ordered.length; next++) {
          final nextEvent = ordered[next].cast<String, dynamic>();
          // PIR 活动不会结束暂停或持续关闭，只有后续控制操作才作为结束边界。
          if (nextEvent['kind'] == 'activity') continue;
          return _eventTimestamp(nextEvent);
        }
        return null;
      }

      var index = 0;
      while (index < ordered.length) {
        final event = ordered[index].cast<String, dynamic>();
        final kind = event['kind']?.toString() ?? 'automatic';
        final timestamp = _eventTimestamp(event);
        if (kind == 'activity') {
          var lastTimestamp = timestamp;
          var next = index + 1;
          while (next < ordered.length) {
            final nextEvent = ordered[next].cast<String, dynamic>();
            if (nextEvent['kind'] != 'activity') break;
            lastTimestamp = _eventTimestamp(nextEvent);
            next++;
          }
          final count = next - index;
          final clockMovedBack = lastTimestamp.isBefore(timestamp);
          final rangeStart = clockMovedBack ? lastTimestamp : timestamp;
          final rangeEnd = clockMovedBack ? timestamp : lastTimestamp;
          final span = rangeEnd.difference(rangeStart);
          final timeRange = _activityTimeRange(rangeStart, rangeEnd);
          chronologicalEvents.add(_PreviewEvent(
            // 右侧时间始终显示这一组合并段的首次触发时间。
            time: _clockTime(timestamp),
            title: count == 1 ? '检测到活动' : '连续感应 · $count 次',
            detail: count == 1
                ? '$timeRange · 单次触发'
                : clockMovedBack
                    ? '$timeRange · 设备时间回退，跨度暂不可用'
                    : '$timeRange · 活动跨度 ${_activitySpanLabel(span)}',
            icon: const Icon(Icons.sensors_rounded,
                size: 16, color: MimiVentColors.mint),
          ));
          index = next;
          continue;
        }

        final state = event['state']?.toString() ?? 'complete';
        final configuredDuration = _intValue(event['durationSeconds']);
        final nextControlTime = nextControlEventTime(index);
        final elapsedToNextControl = nextControlTime == null
            ? null
            : math.max(0, nextControlTime.difference(timestamp).inSeconds);
        final title = switch (kind) {
          'manual' => '临时排风',
          'force' => '强制排风',
          'pause' => '临时暂停',
          'locked_off' => '持续关闭',
          'resume' => '恢复自动感应',
          _ => '自动排风',
        };
        final pauseDuration = elapsedToNextControl == null
            ? configuredDuration
            : math.min(configuredDuration, elapsedToNextControl);
        final lockedOffDuration = elapsedToNextControl ??
            (currentMode == 'lock_off'
                ? math.max(0, DateTime.now().difference(timestamp).inSeconds)
                : null);
        final detail = switch (kind) {
          'pause' => snapshotOnly && nextControlTime == null
              ? '暂停 · 设定 ${_durationLabel(configuredDuration)}'
              : currentMode == 'timed_off' && nextControlTime == null
                  ? '暂停中 · 已 ${_durationLabel(math.max(0, DateTime.now().difference(timestamp).inSeconds))}'
                  : '暂停 ${_durationLabel(pauseDuration)}',
          'locked_off' => lockedOffDuration == null
              ? '持续关闭 · 结束时间未记录'
              : currentMode == 'lock_off' && nextControlTime == null
                  ? '持续关闭中 · 已 ${_durationLabel(lockedOffDuration)}'
                  : '持续关闭 ${_durationLabel(lockedOffDuration)}',
          'resume' => '自动感应已恢复',
          _ => state == 'active'
              ? '${snapshotOnly ? '同步时运行中' : '正在运行'} · ${_durationLabel(configuredDuration)}'
              : state == 'interrupted'
                  ? '设备重启时中断'
                  : '运行 ${_durationLabel(configuredDuration)}',
        };
        final color = switch (kind) {
          'automatic' => MimiVentColors.amber,
          'force' => MimiVentColors.amber,
          'pause' => const Color(0xFF9AC8FF),
          'locked_off' => MimiVentColors.red,
          _ => MimiVentColors.mint,
        };
        final icon = switch (kind) {
          'activity' => const Icon(Icons.sensors_rounded,
              size: 16, color: MimiVentColors.mint),
          // 自定义扇叶线稿视觉面积比 Material 图标大，事件列表中使用较小尺寸。
          'manual' => const FanRotorGlyph(color: MimiVentColors.mint, size: 6),
          'automatic' =>
            const FanRotorGlyph(color: MimiVentColors.amber, size: 6),
          'resume' => const Icon(Icons.sensors_rounded,
              size: 16, color: MimiVentColors.mint),
          'force' => Icon(Icons.science_outlined, size: 16, color: color),
          'pause' =>
            Icon(Icons.pause_circle_outline_rounded, size: 16, color: color),
          'locked_off' =>
            Icon(Icons.power_settings_new_rounded, size: 16, color: color),
          _ => Icon(Icons.air_rounded, size: 16, color: color),
        };
        chronologicalEvents.add(_PreviewEvent(
          time: _clockTime(timestamp),
          title: title,
          detail: detail,
          icon: icon,
        ));
        index++;
      }
    }
    final events = chronologicalEvents.reversed.toList();

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
      maxChartValue: _niceAxisMaximum(maxValue),
      chartTitle: range == _StatisticsRange.sevenDays ? '每日排风时长' : '分时排风时长',
      chartCaption: switch (range) {
        _StatisticsRange.today => '每柱代表 1 小时 · 单位：分钟',
        _StatisticsRange.yesterday => '每柱代表 2 小时 · 单位：分钟',
        _StatisticsRange.threeDays => '每柱代表 8 小时 · 日期标在当天首个时段',
        _StatisticsRange.sevenDays => '每柱代表 1 天 · 单位：分钟',
      },
      events: events,
      rawEventCount: rawEvents is List ? rawEvents.length : 0,
      eventTotal: _intValue(json['eventsTotal']) > 0
          ? _intValue(json['eventsTotal'])
          : rawEvents is List
              ? rawEvents.length
              : 0,
      eventsHasMore: json['eventsHasMore'] == true,
      days: days,
    );
  }

  static int _intValue(Object? value) => value is num ? value.toInt() : 0;

  static DateTime _eventTimestamp(Map<String, dynamic> event) =>
      DateTime.fromMillisecondsSinceEpoch(
        _intValue(event['time']) * 1000,
        isUtc: true,
      ).toLocal();

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  static String _clockTime(DateTime value) =>
      '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}:${_twoDigits(value.second)}';

  static String _activityTimeRange(DateTime start, DateTime end) {
    final startText = _clockTime(start);
    final endText = _clockTime(end);
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    return sameDay
        ? '$startText–$endText'
        : '${_date(start)} $startText–${_date(end)} $endText';
  }

  static String _activitySpanLabel(Duration span) {
    final seconds = math.max(0, span.inSeconds);
    if (seconds < 60) return '$seconds 秒';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return remainder == 0 ? '$minutes 分钟' : '$minutes 分 $remainder 秒';
  }

  static String _hourInterval(int startHour, int spanHours) {
    final endHour = startHour + spanHours;
    return '${_twoDigits(startHour)}:00–${_twoDigits(endHour)}:00';
  }

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
  const _ChartPoint(this.label, this.minutes,
      {this.intervalLabel = '', this.groupLabel = ''});

  final String label;
  final double minutes;
  final String intervalLabel;
  final String groupLabel;
}

class _StatisticsChartPainter extends CustomPainter {
  const _StatisticsChartPainter({
    required this.points,
    required this.maxValue,
    required this.selectedIndex,
  });

  static const double leftInset = 38;
  final List<_ChartPoint> points;
  final double maxValue;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= leftInset + 8) return;
    const top = 7.0;
    const bottomInset = 37.0;
    const rightInset = 4.0;
    final baseline = size.height - bottomInset;
    final plotHeight = baseline - top;
    final plotWidth = size.width - leftInset - rightInset;
    final axisMaximum = maxValue > 0 ? maxValue : 1.0;
    final tickStep = _niceStep(axisMaximum / 4);
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(.09)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = Colors.white.withOpacity(.2)
      ..strokeWidth = 1;

    for (var value = 0.0;
        value <= axisMaximum + tickStep * .01;
        value += tickStep) {
      final y = baseline - (value / axisMaximum) * plotHeight;
      canvas.drawLine(Offset(leftInset, y), Offset(size.width - rightInset, y),
          value == 0 ? axisPaint : gridPaint);
      _drawText(
        canvas,
        _formatMinutes(value),
        Offset(0, y - 6),
        maxWidth: leftInset - 6,
        align: TextAlign.right,
        color: MimiVentColors.muted,
        fontSize: 9,
      );
    }
    canvas.drawLine(
        const Offset(leftInset, top), Offset(leftInset, baseline), axisPaint);

    final slotWidth = plotWidth / points.length;
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final centerX = leftInset + slotWidth * (index + .5);
      final value = point.minutes.clamp(0.0, axisMaximum);
      final barHeight = (value / axisMaximum) * plotHeight;
      if (index == selectedIndex) {
        final highlight = Paint()..color = MimiVentColors.mint.withOpacity(.07);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
                leftInset + index * slotWidth, top, slotWidth, baseline - top),
            const Radius.circular(4),
          ),
          highlight,
        );
      }
      final barWidth = math.min(16.0, math.max(3.0, slotWidth * .52));
      final barPaint = Paint()
        ..color = index == selectedIndex
            ? MimiVentColors.amber
            : MimiVentColors.mint.withOpacity(.82);
      if (barHeight > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(centerX - barWidth / 2, baseline - barHeight,
                barWidth, barHeight),
            const Radius.circular(4),
          ),
          barPaint,
        );
      }
    }

    final labelStep = points.length >= 20
        ? 4
        : points.length >= 12
            ? 2
            : 1;
    for (var index = 0; index < points.length; index += labelStep) {
      final point = points[index];
      final centerX = leftInset + slotWidth * (index + .5);
      _drawText(
        canvas,
        point.label,
        Offset(centerX - slotWidth / 2, baseline + 7),
        maxWidth: slotWidth,
        align: TextAlign.center,
        color: MimiVentColors.muted,
        fontSize: points.length >= 20 ? 7 : 8,
      );
    }

    var groupStart = 0;
    while (groupStart < points.length) {
      final group = points[groupStart].groupLabel;
      if (group.isEmpty) break;
      var groupEnd = groupStart;
      while (groupEnd + 1 < points.length &&
          points[groupEnd + 1].groupLabel == group) {
        groupEnd++;
      }
      final centerX = leftInset + slotWidth * (groupStart + groupEnd + 1) / 2;
      _drawText(
        canvas,
        group,
        Offset(centerX - slotWidth * (groupEnd - groupStart + 1) / 2,
            size.height - 11),
        maxWidth: slotWidth * (groupEnd - groupStart + 1),
        align: TextAlign.center,
        color: MimiVentColors.muted,
        fontSize: 8,
      );
      groupStart = groupEnd + 1;
    }
  }

  static double _niceStep(double rawStep) {
    if (!rawStep.isFinite || rawStep <= 0) return 1;
    final magnitude = math.pow(10, (math.log(rawStep) / math.ln10).floor());
    final fraction = rawStep / magnitude;
    final niceFraction = fraction <= 1
        ? 1.0
        : fraction <= 2
            ? 2.0
            : fraction <= 2.5
                ? 2.5
                : fraction <= 5
                    ? 5.0
                    : 10.0;
    return niceFraction * magnitude;
  }

  static void _drawText(
    Canvas canvas,
    String value,
    Offset offset, {
    required double maxWidth,
    required TextAlign align,
    required Color color,
    required double fontSize,
  }) {
    final painter = TextPainter(
      text: TextSpan(
          text: value,
          style: TextStyle(color: color, fontSize: fontSize, height: 1)),
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, maxWidth));
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _StatisticsChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.selectedIndex != selectedIndex;
}

String _formatMinutes(double value) {
  if (!value.isFinite || value <= 0) return '0';
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
}

double _niceAxisMaximum(double maximum) {
  if (!maximum.isFinite || maximum <= 0) return 1;
  final step = _StatisticsChartPainter._niceStep(maximum / 4);
  return (maximum / step).ceil() * step;
}

class _EventPaginationHint extends StatelessWidget {
  const _EventPaginationHint({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading) ...[
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation(MimiVentColors.muted),
                ),
              ),
              const SizedBox(width: 7),
            ],
            Text(label,
                style:
                    const TextStyle(color: MimiVentColors.muted, fontSize: 9)),
          ],
        ),
      );
}

class _PreviewEvent {
  const _PreviewEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.icon,
  });

  final String time;
  final String title;
  final String detail;
  final Widget icon;
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
