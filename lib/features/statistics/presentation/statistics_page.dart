import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/mimivent_theme.dart';
import '../../../data/mimivent_controller.dart';
import '../../../data/statistics_query.dart';
import '../../../shared/widgets/version_compatibility_notice.dart';
import '../../../shared/widgets/device_animations.dart';

/// 统计页的时间范围。第一版提供常用预设，避免日期选择器占用空间。
enum _StatisticsRange { today, yesterday, dayBeforeYesterday, sevenDays, custom }

extension on _StatisticsRange {
  String get wireValue => switch (this) {
        _StatisticsRange.today => 'today',
        _StatisticsRange.yesterday => 'yesterday',
        _StatisticsRange.dayBeforeYesterday => 'yesterday',
        _StatisticsRange.sevenDays => 'sevenDays',
        // custom 只走范围接口；旧固件在入口处就被拦住，不会用到这个值。
        _StatisticsRange.custom => 'today',
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
  /// 上次成功取到范围数据的时刻。2 分钟内切回本页直接复用缓存，
  /// 不再新建 TLS 会话（设备端每次会话约 18 KB 堆）。
  DateTime? _rangeLoadedAt;

  /// 断开后 controller.status 会被清空，而查询需要 tzOffsetSeconds 与范围能力。
  /// 记住最近一次已知值，断线期间仍能构造 query 命中缓存，而不是整页变空。
  bool _protocolWarningLogged = false;
  int? _cachedTzOffsetSeconds;
  bool _cachedRangeCapable = false;

  bool get _canSynchronize =>
      widget.active &&
      !_readOnly &&
      widget.controller.status != null &&
      widget.controller.settings != null;

  _StatisticsRange _range = _StatisticsRange.today;
  // "选择时间"生成的查询；为 null 表示还没选过。
  StatisticsQuery? _customQuery;
  int? _selectedChartIndex;
  Timer? _refreshTimer;
  /// range 接口的刷新状态：旧接口标志不适用于它，否则界面永远显示"已同步"。
  bool _rangeRefreshing = false;
  Object? _rangeError;
  Timer? _retryTimer;
  bool _loadingMoreEvents = false;
  bool _loadingSelectedIntervalEvents = false;
  bool _selectedIntervalEventsIncomplete = false;
  int _selectedIntervalGeneration = 0;
  bool _refreshEnabled = false;
  Map<String, dynamic>? _yesterdayData;
  String? _yesterdayDataDay;
  String? _comparisonDeviceId;
  bool _yesterdayRequested = false;

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
    // 在这里记录时区与范围能力：build 里做会随每帧重复执行。
    _rememberRangeCapability();
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _refreshEnabled = _canSynchronize;
    if (!_refreshEnabled) return;
    // 切换 Tab 或重连可能发生于父级构建期间，延后到帧末再通知加载状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_canSynchronize) return;
      final loadedAt = _rangeLoadedAt;
      if (loadedAt != null &&
          _rangeQuery() != null &&
          DateTime.now().difference(loadedAt) < const Duration(minutes: 2)) {
        // 缓存够新：直接复用，避免切 Tab 就新建一次 WiFi 会话。
        // 这里不能 setState——postFrameCallback 里再触发重建会形成循环。
        return;
      }
      unawaited(_loadStatistics());
    });
    // 兜底刷新从 1 分钟放宽到 5 分钟：设备端每次 WiFi 请求都要新建一次 TLS 会话
    // （约 18 KB 堆），而 C3 空闲堆只有 36 KB，高频刷新会把它推到断链边缘。
    // 切到统计页时会立即刷新一次，用户想手动更新可下拉或切走再切回。
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_loadStatistics());
    });
  }

  /// 固件支持范围接口时构造对应查询；否则返回 null，继续走旧 mode 接口。
  /// 固件支持范围接口时构造对应查询；否则返回 null，继续走旧 mode 接口。
  StatisticsQuery? _rangeQuery() => _rangeQueryFor(_range);

  /// 设备本地"今天 00:00"。用手机的日历日期即可：设备时区偏移由 tz 单独带上。
  static DateTime _localToday(DateTime now) =>
      DateTime(now.year, now.month, now.day);

  /// 断线期间沿用最近一次已知的时区与能力，避免缓存查不出来。
  int? get _effectiveTz =>
      widget.controller.deviceTimezoneOffsetSeconds ?? _cachedTzOffsetSeconds;

  bool get _effectiveRangeCapable =>
      widget.controller.supportsStatisticsRange || _cachedRangeCapable;

  /// 只在在线且拿到 status 时刷新缓存，断线后保持旧值。
  void _rememberRangeCapability() {
    final tz = widget.controller.deviceTimezoneOffsetSeconds;
    if (tz != null && widget.controller.supportsStatisticsRange) {
      _cachedTzOffsetSeconds = tz;
      _cachedRangeCapable = true;
    }
  }

  StatisticsQuery? _rangeQueryFor(_StatisticsRange range) {
    final tz = _effectiveTz;
    if (tz == null || !_effectiveRangeCapable) return null;
    final now = DateTime.now();
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    return switch (range) {
      _StatisticsRange.today =>
        StatisticsQuery.today(now: nowSeconds, tzOffsetSeconds: tz),
      _StatisticsRange.yesterday =>
        StatisticsQuery.yesterday(now: nowSeconds, tzOffsetSeconds: tz),
      // 前天：以今天本地零点往前推两天的单日查询。
      _StatisticsRange.dayBeforeYesterday => StatisticsQuery.day(
          day: _localToday(now).subtract(const Duration(days: 2)),
          tzOffsetSeconds: tz),
      _StatisticsRange.sevenDays =>
        StatisticsQuery.lastSevenDays(now: nowSeconds, tzOffsetSeconds: tz),
      _StatisticsRange.custom => _customQuery,
    };
  }

  void _showRangeUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('当前固件不支持按日期查询，请先升级固件'),
    ));
  }

  /// 两步选择：先起始日，再结束日（默认等于起始日），范围限定最近 30 天。
  /// 第二步左上角可以回到上一步重新选起始日；任一步取消都直接退出。
  Future<void> _pickCustomRange() async {
    final tz = widget.controller.deviceTimezoneOffsetSeconds;
    if (tz == null || !widget.controller.supportsStatisticsRange) {
      _showRangeUnavailable();
      return;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final earliest = today.subtract(const Duration(days: 29));

    DateTime? start;
    DateTime? end;
    while (end == null) {
      start = await _showDateWheel(
        title: '选择开始日期',
        subtitle: '可查最近 30 天；最近 10 天有事件明细',
        leftLabel: '取消',
        rightLabel: '下一步',
        initial: start ?? today,
        first: earliest,
        last: today,
      );
      if (start == null || !mounted) return;
      // 第二步默认沿用起始日：只看一天时两次确认即可，
      // 不会因为默认今日而把单日悄悄变成两天。
      final picked = await _showDateWheel(
        title: '选择结束日期',
        subtitle: '默认与开始日期相同，即只看单日',
        leftLabel: '上一步',
        rightLabel: '确定',
        initial: start,
        first: start,
        last: today,
      );
      if (!mounted) return;
      // 上一步返回 null：保留已选起始日，重新走第一步。
      if (picked != null) end = picked;
    }

    final query = start!.isAtSameMomentAs(end)
        ? StatisticsQuery.day(day: start, tzOffsetSeconds: tz)
        : StatisticsQuery.range(
            startDay: start, endDay: end, tzOffsetSeconds: tz);
    setState(() {
      _customQuery = query;
      _range = _StatisticsRange.custom;
      _selectedChartIndex = null;
      _selectedIntervalGeneration++;
      _selectedIntervalEventsIncomplete = false;
    });
    await _loadStatistics();
  }

  /// 滚轮式日期选择：顶部左侧次要操作、右侧主操作，中间标题与说明。
  Future<DateTime?> _showDateWheel({
    required String title,
    required String subtitle,
    required String leftLabel,
    required String rightLabel,
    required DateTime initial,
    required DateTime first,
    required DateTime last,
  }) {
    var value = initial;
    return showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: const Color(0xFF12211E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 76,
                    child: TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(leftLabel,
                          style: const TextStyle(
                              color: MimiVentColors.muted, fontSize: 13)),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text(subtitle,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: MimiVentColors.muted,
                                  fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    child: TextButton(
                      onPressed: () => Navigator.pop(sheetContext, value),
                      child: Text(rightLabel,
                          style: const TextStyle(
                              color: MimiVentColors.mint,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _DateWheel(
                first: first,
                last: last,
                initial: initial,
                onChanged: (picked) => value = picked,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadStatistics() async {
    if (_range == _StatisticsRange.custom && _rangeQuery() == null) return;
    final query = _rangeQuery();
    if (query != null) {
      if (mounted) {
        setState(() {
          _rangeRefreshing = true;
          _rangeError = null;
        });
      }
      try {
        await widget.controller.refreshStatisticsRange(query);
      } catch (error) {
        // 不 rethrow：调用方全是 unawaited(_loadStatistics())，抛出去会变成
        // "Dart 未捕获异常"写满诊断日志（PlatformDispatcher.onError 会记录完整堆栈）。
        // 失败已经由 _rangeError 驱动 UI 显示"同步失败"。
        if (mounted) setState(() => _rangeError = error);
      } finally {
        if (mounted) setState(() => _rangeRefreshing = false);
      }
      _rangeLoadedAt = DateTime.now();
      // 协议自检放在请求结束后做一次，避免在 build 里重复构造整份预览。
      if (!_protocolWarningLogged) {
        final raw = widget.controller.statisticsRangeFor(query);
        final buckets = raw?['buckets'];
        if (buckets is List && buckets.isNotEmpty) {
          final first = buckets.first;
          if (first is Map &&
              !first.containsKey('rt') &&
              !first.containsKey('span') &&
              !first.containsKey('cov') &&
              !first.containsKey('bits')) {
            _protocolWarningLogged = true;
            widget.controller.diagnostics?.warning('统计协议',
                '范围响应含桶但缺少已知字段，可能与固件 key 名不一致');
          }
        }
      }
      if (!mounted || !_canSynchronize) return;
      // 新接口不返回事件；单日范围再单独拉一页明细。
      if (query.singleDay) {
        await widget.controller.refreshRangeEventPage(query);
      }
      // 对比日：今天→昨天、昨天→前天、前天→大前天；缓存键稳定后只拉一次。
      final offset = switch (_range) {
        _StatisticsRange.today => 1,
        _StatisticsRange.yesterday => 2,
        _StatisticsRange.dayBeforeYesterday => 3,
        _ => 0,
      };
      final tzForCompare = widget.controller.deviceTimezoneOffsetSeconds;
      if (offset > 0 && tzForCompare != null) {
        await widget.controller.refreshStatisticsRange(StatisticsQuery.day(
          day: _localToday(DateTime.now()).subtract(Duration(days: offset)),
          tzOffsetSeconds: tzForCompare,
        ));
      }
      return;
    }
    await widget.controller.refreshStatistics(_range.wireValue);
    if (_range == _StatisticsRange.today) await _ensureYesterdayData();
    if (!mounted || !_canSynchronize || _retryTimer != null) return;
    if (widget.controller.statisticsFailedFor(_range.wireValue) &&
        !widget.controller.statisticsLoadingFor(_range.wireValue)) {
      _retryTimer = Timer(const Duration(seconds: 3), () {
        _retryTimer = null;
        if (mounted && _canSynchronize) unawaited(_loadStatistics());
      });
    }
  }

  Future<void> _ensureYesterdayData() async {
    final now = DateTime.now();
    final dayKey = '${now.year}-${now.month}-${now.day}';
    final current = widget.controller.statisticsFor(_range.wireValue);
    final deviceId =
        (current?['deviceId'] ?? current?['eventsDeviceId'])?.toString() ?? '';
    if (_yesterdayDataDay != dayKey || _comparisonDeviceId != deviceId) {
      _yesterdayDataDay = dayKey;
      _comparisonDeviceId = deviceId;
      _yesterdayData = null;
      _yesterdayRequested = false;
    }
    if (_yesterdayRequested || !_canSynchronize) return;
    _yesterdayRequested = true;
    await widget.controller.refreshStatistics('yesterday');
    if (!mounted) return;
    final data = widget.controller.statisticsFor('yesterday');
    if (data != null) setState(() => _yesterdayData = data);
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final supportsEventPages = _range == _StatisticsRange.today ||
        _range == _StatisticsRange.yesterday;
    if (widget.controller.connected &&
        !widget.controller.offlineViewing &&
        supportsEventPages &&
        notification.metrics.extentAfter < 180 &&
        !_loadingSelectedIntervalEvents &&
        !_loadingMoreEvents &&
        widget.controller.statisticsHasMoreEventsFor(_range.wireValue)) {
      _loadMoreEvents();
    }
    // 继续向外冒泡，避免影响 Dashboard 的滚动标题行为。
    return false;
  }

  Future<void> _loadMoreEvents() async {
    if (_loadingSelectedIntervalEvents) return;
    setState(() => _loadingMoreEvents = true);
    try {
      await widget.controller.loadMoreStatisticsEvents(_range.wireValue);
    } finally {
      if (mounted) setState(() => _loadingMoreEvents = false);
    }
  }

  void _clearSelectedChartPoint() {
    if (!mounted ||
        (_selectedChartIndex == null && !_loadingSelectedIntervalEvents)) {
      return;
    }
    _selectedIntervalGeneration++;
    setState(() {
      _selectedChartIndex = null;
      _loadingSelectedIntervalEvents = false;
      _selectedIntervalEventsIncomplete = false;
    });
  }

  void _selectChartPoint(int index, List<_ChartPoint> points) {
    if (_selectedChartIndex == index) {
      _clearSelectedChartPoint();
      return;
    }
    final generation = ++_selectedIntervalGeneration;
    final point = points[index];
    setState(() {
      _selectedChartIndex = index;
      _selectedIntervalEventsIncomplete = false;
    });
    if (_range == _StatisticsRange.today ||
        _range == _StatisticsRange.yesterday) {
      if (_canSynchronize) {
        unawaited(_loadSelectedIntervalEvents(point, generation));
      } else if (widget.controller
          .statisticsHasMoreEventsFor(_range.wireValue)) {
        setState(() => _selectedIntervalEventsIncomplete = true);
      }
    } else if (widget.controller.statisticsHasMoreEventsFor(_range.wireValue)) {
      setState(() => _selectedIntervalEventsIncomplete = true);
    }
  }

  Future<void> _loadSelectedIntervalEvents(
      _ChartPoint point, int generation) async {
    final start = point.startAt;
    if (start == null || !_canSynchronize) return;
    if (_loadingMoreEvents) {
      if (mounted && generation == _selectedIntervalGeneration) {
        setState(() => _selectedIntervalEventsIncomplete = true);
      }
      return;
    }

    setState(() {
      _loadingSelectedIntervalEvents = true;
      _selectedIntervalEventsIncomplete = false;
    });
    var covered = false;
    try {
      // 统计摘要首屏最多带 32 条事件；继续按设备游标翻页，直到覆盖所选时段。
      for (var page = 0; page < 20; page++) {
        if (!mounted || generation != _selectedIntervalGeneration) return;
        final data = widget.controller.statisticsFor(_range.wireValue);
        final rawEvents = data?['events'];
        final List<Map> events = rawEvents is List
            ? rawEvents.whereType<Map>().toList()
            : const <Map>[];
        final intervalStart = start.millisecondsSinceEpoch ~/ 1000;
        covered = events.any((event) {
          final value = event['time'];
          return value is num && value.toInt() <= intervalStart;
        });
        if (covered ||
            !widget.controller.statisticsHasMoreEventsFor(_range.wireValue)) {
          break;
        }
        final countBefore = events.length;
        await widget.controller.loadMoreStatisticsEvents(_range.wireValue);
        final updated = widget.controller.statisticsFor(_range.wireValue);
        final updatedEvents = updated?['events'];
        final countAfter = updatedEvents is List ? updatedEvents.length : 0;
        if (countAfter <= countBefore) break;
      }
    } finally {
      if (mounted && generation == _selectedIntervalGeneration) {
        final remains =
            widget.controller.statisticsHasMoreEventsFor(_range.wireValue);
        setState(() {
          _loadingSelectedIntervalEvents = false;
          _selectedIntervalEventsIncomplete = remains && !covered;
        });
      }
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
    _retryTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rangeQuery = _rangeQuery();
    final rangeData =
        rangeQuery == null ? null : widget.controller.statisticsRangeFor(rangeQuery);
    final data = widget.controller.statisticsFor(_range.wireValue);
    // 固件支持范围查询时，未拿到数据就显示空态——绝不能回落到旧接口：
    // 旧接口没有跨度桶，回落会让黄柱在"有/无"之间闪变。
    // custom 分支即使还没选日期也必须走空态，否则会回落到 statisticsFor('today')。
    final expectRangeOnly = _range == _StatisticsRange.custom ||
        (rangeQuery != null && widget.controller.supportsStatisticsRange);
    final view = rangeData != null
        ? _StatisticsPreview.fromRange(_range, rangeData,
            currentMode: widget.controller.status?.mode,
            snapshotOnly: _readOnly)
        : expectRangeOnly
            ? _StatisticsPreview.emptyForRange(_range)
            : data == null
                ? _StatisticsPreview.emptyForRange(_range)
                : _StatisticsPreview.fromDevice(_range, data,
                currentMode: widget.controller.status?.mode,
                snapshotOnly: _readOnly,
                activityGapSeconds:
                    (((widget.controller.settings?.autoExhaustMs ?? 120000) ~/
                            1000)
                        .clamp(60, 600)));
    // 对比基准：今天→昨天、昨天→前天、前天→大前天；其它范围不显示增减。
    final comparisonOffset = switch (_range) {
      _StatisticsRange.today => 1,
      _StatisticsRange.yesterday => 2,
      _StatisticsRange.dayBeforeYesterday => 3,
      _ => 0,
    };
    _StatisticsPreview? previousView;
    if (comparisonOffset > 0) {
      final tz = widget.controller.deviceTimezoneOffsetSeconds;
      StatisticsQuery? compareQuery;
      if (tz != null && widget.controller.supportsStatisticsRange) {
        compareQuery = StatisticsQuery.day(
          day: _localToday(DateTime.now())
              .subtract(Duration(days: comparisonOffset)),
          tzOffsetSeconds: tz,
        );
      }
      final compareRange = compareQuery == null
          ? null
          : widget.controller.statisticsRangeFor(compareQuery);
      if (compareRange != null) {
        previousView = _StatisticsPreview.fromRange(
            _StatisticsRange.yesterday, compareRange,
            currentMode: widget.controller.status?.mode,
            snapshotOnly: _readOnly);
      } else if (_yesterdayData != null &&
          _range == _StatisticsRange.today) {
        // 旧固件只有 today/yesterday 两个 mode，回落到缓存快照。
        previousView = _StatisticsPreview.fromDevice(
            _StatisticsRange.yesterday, _yesterdayData!,
            currentMode: widget.controller.status?.mode,
            snapshotOnly: _readOnly,
            activityGapSeconds:
                ((widget.controller.settings?.autoExhaustMs ?? 120000) ~/ 1000)
                    .clamp(60, 600));
      }
    }
    final comparison = previousView != null
        ? _YesterdayComparison.from(view, previousView)
        : null;
    return NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.clamp(0.0, 860.0);
            return ListView(
              key: const PageStorageKey('statistics-page'),
              primary: false,
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
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
                        const SizedBox(height: 4),
                        _syncStatus(data),
                        const SizedBox(height: 4),
                        _rangePicker(),
                        const SizedBox(height: 8),
                        if (_readOnly && data == null)
                          _offlineEmptyState()
                        else ...[
                          _summaryCard(view, comparison),
                          const SizedBox(height: 8),
                          _metricRow(view, comparison),
                          const SizedBox(height: 10),
                          _runtimeChart(view),
                          const SizedBox(height: 10),
                          // 最近三天都能拉到单日明细，显示事件列表；
                          // 更早的范围只有日汇总，退化为按日概览。
                          if (_range == _StatisticsRange.today ||
                              _range == _StatisticsRange.yesterday ||
                              _range == _StatisticsRange.dayBeforeYesterday)
                            _eventList(
                              view.events,
                              title: switch (_range) {
                                _StatisticsRange.today => '今天事件',
                                _StatisticsRange.yesterday => '昨天事件',
                                _ => '前天事件',
                              },
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
    // 范围接口有独立的刷新状态：旧接口的 loading/failed 标志对它永远为假，
    // 不接进来的话界面会一直停在"已同步"，看不到更新中和失败。
    final rangeQuery = _rangeQuery();
    final rangeMode = rangeQuery != null;
    final loading = rangeMode
        ? _rangeRefreshing
        : widget.controller.statisticsLoadingFor(_range.wireValue);
    final failed = rangeMode
        ? _rangeError != null
        : widget.controller.statisticsFailedFor(_range.wireValue);
    final cached = rangeMode
        ? widget.controller.statisticsRangeFor(rangeQuery) != null
        : widget.controller.statisticsIsCachedFor(_range.wireValue);
    final cachedAt =
        widget.controller.statisticsCacheUpdatedAtFor(_range.wireValue);
    final cachedAtLabel = cachedAt == null
        ? ''
        : ' · ${cachedAt.month}/${cachedAt.day} ${cachedAt.hour.toString().padLeft(2, '0')}:${cachedAt.minute.toString().padLeft(2, '0')}';
    final offline = _readOnly;
    // custom 且还没选日期时既没有请求也没有缓存，显示"等待首次同步"是误导。
    final awaitingCustomRange =
        _range == _StatisticsRange.custom && _customQuery == null;
    final label = awaitingCustomRange
        ? '尚未选择时间范围 · 点击「更多时间」开始'
        : offline
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
                // 用 cached 而不是 data：range 模式下数据存在 statisticsRangeFor 里，
                // data（旧接口快照）恒为 null，用 data 判断会永远显示"等待首次同步"。
                : cached
                    ? '设备数据已同步 · 每 5 分钟刷新'
                    : '等待首次同步';
    final color = failed ? MimiVentColors.amber : MimiVentColors.mint;
    return SizedBox(
      height: 24,
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
          children: const [
            _StatisticsRange.today,
            _StatisticsRange.yesterday,
            _StatisticsRange.dayBeforeYesterday,
            _StatisticsRange.sevenDays,
            _StatisticsRange.custom,
          ].map((range) {
            final selected = range == _range;
            return Expanded(
              child: Semantics(
                button: true,
                selected: selected,
                label: _rangeLabel(range),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () {
                    if (range == _StatisticsRange.custom) {
                      unawaited(_pickCustomRange());
                      return;
                    }
                    setState(() {
                      _range = range;
                      _selectedChartIndex = null;
                      _selectedIntervalGeneration++;
                      _loadingSelectedIntervalEvents = false;
                      _selectedIntervalEventsIncomplete = false;
                      _loadingMoreEvents = false;
                    });
                    unawaited(_loadStatistics());
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 34,
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

  Widget _summaryCard(
          _StatisticsPreview view, _YesterdayComparison? comparison) =>
      Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                if (comparison != null && comparison.runtimeText != null) ...[
                  Text(comparison.runtimeText!,
                      style: TextStyle(
                          color: comparison.color,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(width: 7),
                ],
                _dateRangePill(view.rangeText),
              ],
            ),
            const SizedBox(height: 6),
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
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: MimiVentColors.mint.withOpacity(.10),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.air_rounded,
                      color: MimiVentColors.mint, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(view.runtimeCaption,
                style: const TextStyle(
                    color: MimiVentColors.muted, fontSize: 10, height: 1.3)),
          ],
        ),
      );

  /// 有对比但该指标不可用时占位，保证同行卡片高度一致。
  static const String _kComparisonPlaceholder = '较昨日 —';

  Widget _metricRow(
          _StatisticsPreview view, _YesterdayComparison? comparison) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _metricSlot(_metricCard(
            icon: Icons.air_rounded,
            title: '自动排风',
            value: '${view.autoExhaustCount}',
            unit: '次',
            accent: MimiVentColors.amber,
            comparisonText: comparison?.autoExhaustText,
            comparisonColor: comparison?.autoExhaustColor,
          )),
          const SizedBox(width: 10),
          _metricSlot(_metricCard(
            icon: Icons.wc_rounded,
            title: '预计入厕',
            value: view.toiletEstimateAvailable
                ? '${view.toiletEstimateCount}'
                : '—',
            unit: view.toiletEstimateAvailable ? '次' : '',
            accent: const Color(0xFF8DB8FF),
            // 有对比就占位：缺数据时给"—"而不是省略，
            // 避免同一行卡片有的三行、有的两行。
            comparisonText: comparison == null
                ? null
                : (comparison.toiletText ?? _kComparisonPlaceholder),
            comparisonColor: comparison?.toiletColor,
          )),
          const SizedBox(width: 10),
          _metricSlot(_metricCard(
            icon: Icons.timer_outlined,
            title: '平均入厕时间',
            value: view.toiletAverageMain,
            unit: view.toiletAverageUnit,
            accent: const Color(0xFFB69CFF),
            comparisonText: comparison == null
                ? null
                : (comparison.toiletAverageText ?? _kComparisonPlaceholder),
            comparisonColor: comparison?.toiletAverageColor ?? MimiVentColors.muted,
          )),
          const SizedBox(width: 10),
          _metricSlot(_metricCard(
            icon: Icons.motion_photos_on_rounded,
            title: '感应活动段',
            value: '${view.activityCount}',
            unit: '次',
            accent: MimiVentColors.mint,
            comparisonText: comparison?.activityText,
            comparisonColor: comparison?.activityColor,
          )),
        ]),
      );

  Widget _metricSlot(Widget child) => SizedBox(width: 122, child: child);

  Widget _metricCard({
    required IconData icon,
    required String title,
    required String value,
    required String unit,
    required Color accent,
    String? comparisonText,
    Color? comparisonColor,
  }) =>
      Container(
        padding: const EdgeInsets.all(9),
        decoration: _cardDecoration(),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                  color: accent.withOpacity(.11), shape: BoxShape.circle),
              child: Icon(icon, color: accent, size: 13),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 9.5)),
                  const SizedBox(height: 4),
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
                  if (comparisonText != null) ...[
                    const SizedBox(height: 3),
                    Text(comparisonText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: comparisonColor ?? MimiVentColors.muted,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600)),
                  ],
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
      padding: const EdgeInsets.fromLTRB(11, 14, 13, 12),
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
              const SizedBox(width: 10),
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    color: MimiVentColors.amber, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              const Text('感应跨度',
                  style: TextStyle(color: MimiVentColors.muted, fontSize: 9)),
            ],
          ),
          const SizedBox(height: 8),
          // 不再监听区域外点击：滚动时手指落在图表外会误触发，
          // 导致"滑到下方详情突然消失"。收起只由再次点击同一柱触发。
          TapRegion(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 30,
                  child: selectedPoint == null
                      ? const Text(
                          '点击图表查看该时段排风与感应跨度',
                          style: TextStyle(
                              color: MimiVentColors.muted,
                              fontSize: 10,
                              height: 1.4),
                        )
                      : Row(                          children: [
                            Text(
                              selectedPoint.intervalLabel,
                              style: const TextStyle(
                                  color: MimiVentColors.muted,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                              TextSpan(
                                text:
                                    "排风 ${selectedPoint.runtimeAvailable ? _formatStatisticMinutes(selectedPoint.minutes) : '不可用'}",
                                style:
                                    const TextStyle(color: MimiVentColors.mint),
                              ),
                              const TextSpan(
                                  text: " · ",
                                  style:
                                      TextStyle(color: MimiVentColors.muted)),
                              TextSpan(
                                text:
                                    "感应 ${selectedPoint.activityAvailable ? _formatStatisticMinutes(selectedPoint.activityMinutes) : '不可用'}",
                                style: const TextStyle(
                                    color: MimiVentColors.amber),
                              ),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                ),
                SizedBox(
                  height: 180,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final chartSize = Size(constraints.maxWidth, 180);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (details) {
                          const leftInset = _StatisticsChartPainter.leftInset;
                          final plotWidth = chartSize.width - leftInset - 5;
                          final x = details.localPosition.dx - leftInset;
                          if (plotWidth <= 0 || x < 0 || x > plotWidth) {
                            _clearSelectedChartPoint();
                            return;
                          }
                          final index = (x / plotWidth * view.chart.length)
                              .floor()
                              .clamp(0, view.chart.length - 1);
                          _selectChartPoint(index, view.chart);
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
                // 单日范围（含"更多时间"选中的单日）都能展开该时段详情；
                // 多日范围按文档不提供明细。
                // 明细只保留最近三天：多日范围（近 7 天、自定义区间）不拉事件，
                // 设备事件容量已收敛到 256 条，整段拉取既不够覆盖也不值得。
                if (selectedPoint != null &&
                    (_range == _StatisticsRange.today ||
                        _range == _StatisticsRange.yesterday ||
                        _range == _StatisticsRange.dayBeforeYesterday))
                  _selectedIntervalDetails(
                    // 点柱取回的窗口事件优先：整范围刷新只重写 view.events，
                    // 若这里用 view.events，每分钟自动更新会把详情冲掉。
                    view.intervalEvents.isNotEmpty
                        ? view.intervalEvents
                        : view.events,
                    selectedPoint,
                    loading: _loadingSelectedIntervalEvents,
                    incomplete: _selectedIntervalEventsIncomplete,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text('${view.chartCaption} · 感应跨度为活动首末触发时差',
              style: const TextStyle(color: MimiVentColors.muted, fontSize: 9)),
          if (view.detailNotice != null) ...[
            const SizedBox(height: 6),
            Text(view.detailNotice!,
                style: const TextStyle(
                    color: MimiVentColors.amber,
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }

  Widget _selectedIntervalDetails(List<_PreviewEvent> events, _ChartPoint point,
      {required bool loading, required bool incomplete}) {
    final start = point.startAt;
    final end = point.endAt;
    if (start == null || end == null) return const SizedBox.shrink();
    bool overlaps(_PreviewEvent event) {
      final eventStart = event.startAt;
      final eventEnd = event.endAt;
      if (eventStart == null || eventEnd == null) return false;
      if (eventStart.isAtSameMomentAs(eventEnd)) {
        return !eventStart.isBefore(start) && eventStart.isBefore(end);
      }
      return eventStart.isBefore(end) && eventEnd.isAfter(start);
    }

    final fanEvents = events
        .where((event) => event.isFan && overlaps(event))
        .toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    final activityEvents = events
        .where((event) => event.isActivity && overlaps(event))
        .toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));

    final settings = widget.controller.settings;
    final pairWindow = Duration(
      milliseconds: math.max(
        settings?.leaveConfirmMs ?? 20000,
        settings?.autoExhaustMs ?? 180000,
      ),
    );
    final pendingFans = List<_PreviewEvent>.from(fanEvents);
    final rows = <_DetailTimelineRow>[];
    for (final activity in activityEvents) {
      final activityStart = activity.startAt!;
      final activityEnd = activity.endAt!;
      _PreviewEvent? paired;
      for (final fan in pendingFans) {
        final fanStart = fan.startAt!;
        if (fanStart
            .isBefore(activityStart.subtract(const Duration(seconds: 30)))) {
          continue;
        }
        if (fanStart.isAfter(activityEnd.add(pairWindow))) break;
        paired = fan;
        break;
      }
      if (paired != null) pendingFans.remove(paired);
      rows.add(_DetailTimelineRow(activity: activity, fan: paired));
    }
    for (final fan in pendingFans) {
      rows.add(_DetailTimelineRow(fan: fan));
    }
    rows.sort((a, b) => a.sortAt.compareTo(b.sortAt));

    return Container(
      width: double.infinity,
      // 高度随内容自适应，最多 238；超出后列表在框内滚动。
      constraints: const BoxConstraints(maxHeight: 238),
      margin: const EdgeInsets.only(top: 5),
      padding: const EdgeInsets.fromLTRB(9, 8, 9, 7),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.035),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withOpacity(.07)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${point.intervalLabel} 详情',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 9,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(children: [
                  Icon(Icons.sensors_rounded,
                      size: 12, color: MimiVentColors.amber),
                  SizedBox(width: 4),
                  Text('感应',
                      style: TextStyle(
                          color: MimiVentColors.amber,
                          fontSize: 9,
                          fontWeight: FontWeight.w700)),
                ]),
              ),
              SizedBox(width: 8),
              Expanded(
                flex: 5,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('排风',
                        style: TextStyle(
                            color: MimiVentColors.mint,
                            fontSize: 9,
                            fontWeight: FontWeight.w700)),
                    SizedBox(width: 4),
                    Icon(Icons.air_rounded,
                        size: 12, color: MimiVentColors.mint),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Flexible(
            child: rows.isEmpty
                // Center 会撑满可用空间，用 heightFactor:1 让它贴合单行高度。
                ? const Align(
                    alignment: Alignment.center,
                    heightFactor: 1,
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('此时段暂无感应或排风记录',
                          style: TextStyle(
                              color: MimiVentColors.muted, fontSize: 9)),
                    ),
                  )
                : ListView.builder(
                    primary: false,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    itemBuilder: (context, index) => _timelineRow(rows[index]),
                  ),
          ),
          if (loading || incomplete)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                loading ? '正在载入此时段完整记录…' : '当前连接未能载入全部记录',
                style:
                    const TextStyle(color: MimiVentColors.muted, fontSize: 9),
              ),
            ),
        ],
      ),
    );
  }

  Widget _timelineRow(_DetailTimelineRow row) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
                flex: 5, child: _timelineCell(row.activity, alignEnd: false)),
            const SizedBox(width: 8),
            Expanded(flex: 5, child: _timelineCell(row.fan, alignEnd: true)),
          ],
        ),
      );

  Widget _timelineCell(_PreviewEvent? event, {required bool alignEnd}) {
    if (event == null) {
      return Container(
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.018),
          borderRadius: BorderRadius.circular(7),
        ),
      );
    }
    final alignment =
        alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final textAlign = alignEnd ? TextAlign.end : TextAlign.start;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.035),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Text(event.time,
              textAlign: textAlign,
              style: const TextStyle(color: MimiVentColors.muted, fontSize: 8)),
          const SizedBox(height: 1),
          Text(event.title,
              textAlign: textAlign,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 9,
                  fontWeight: FontWeight.w600)),
          if (event.detail.isNotEmpty)
            Text(event.detail,
                textAlign: textAlign,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: MimiVentColors.muted, fontSize: 8)),
        ],
      ),
    );
  }

  Widget _intervalDetailRow(
          {required String title,
          required String detail,
          required Widget icon}) =>
      Container(
        width: double.infinity,
        height: 52,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.035),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            SizedBox(width: 20, child: Center(child: icon)),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9,
                          fontWeight: FontWeight.w600)),
                  if (detail.isNotEmpty)
                    Text(detail,
                        maxLines: 2,
                        overflow: TextOverflow.fade,
                        style: const TextStyle(
                            color: MimiVentColors.muted, fontSize: 8)),
                ],
              ),
            ),
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
            // 倒序：最新的一天排在最前，最久的在最后。
            for (var i = 0; i < days.length; i++) ...[
              _dailySummaryRow(days[days.length - 1 - i]),
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
                  Text(
                      _dailyDetailLine(day),
                      style: const TextStyle(
                          color: MimiVentColors.muted, fontSize: 9)),
                ],
              ),
            ),
            // 右侧不再单独重复排风时长：左侧明细已包含"排风 N 次 · 时长"。
          ],
        ),
      );

  /// 按日概览的一行明细：感应与排风都给出"次数 + 时长"。
  /// 感应跨度不可用的日期只显示次数，并标注"—"避免与真实 0 混淆。
  static String _dailyDetailLine(_DailySummary day) {
    final span = day.activityAvailable && day.activitySeconds != null
        ? _shortDuration(day.activitySeconds!)
        : '—';
    final runtime = _shortDuration(day.runtimeMinutes * 60);
    return '感应 ${day.activityCount} 次 · $span   |   排风 ${day.exhaustCount} 次 · $runtime';
  }

  /// 90 → "1分30秒"；0 → "0秒"；整分省略秒。
  static String _shortDuration(int seconds) {
    if (seconds <= 0) return '0秒';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    if (minutes == 0) return '$rest秒';
    if (rest == 0) return '$minutes分钟';
    return '$minutes分$rest秒';
  }

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
        _StatisticsRange.today => '今天',
        _StatisticsRange.yesterday => '昨天',
        _StatisticsRange.dayBeforeYesterday => '前天',
        _StatisticsRange.custom => '更多时间',
        _StatisticsRange.sevenDays => '近 7 天',
      };
}

/// 统计页面的显示模型，空状态只生成固定布局所需的零值占位，不展示虚构记录。
class _YesterdayComparison {
  const _YesterdayComparison({
    required this.runtimeDeltaSeconds,
    required this.activityDelta,
    required this.autoExhaustDelta,
    required this.toiletDelta,
    required this.toiletAvailable,
    required this.toiletAverageDeltaSeconds,
    required this.toiletAverageAvailable,
  });

  final int runtimeDeltaSeconds;
  final int activityDelta;
  final int autoExhaustDelta;
  final int toiletDelta;
  final bool toiletAvailable;
  final int toiletAverageDeltaSeconds;
  final bool toiletAverageAvailable;

  factory _YesterdayComparison.from(
      _StatisticsPreview today, _StatisticsPreview yesterday) {
    final todayRuntime = today.runtimeSeconds;
    final yesterdayRuntime = yesterday.runtimeSeconds;
    return _YesterdayComparison(
      runtimeDeltaSeconds: todayRuntime - yesterdayRuntime,
      activityDelta: today.activityCount - yesterday.activityCount,
      autoExhaustDelta: today.autoExhaustCount - yesterday.autoExhaustCount,
      toiletDelta: today.toiletEstimateCount - yesterday.toiletEstimateCount,
      toiletAvailable:
          today.toiletEstimateAvailable && yesterday.toiletEstimateAvailable,
      toiletAverageDeltaSeconds: (today.toiletAverageSeconds ?? 0) -
          (yesterday.toiletAverageSeconds ?? 0),
      toiletAverageAvailable:
          today.toiletAverageAvailable && yesterday.toiletAverageAvailable,
    );
  }

  Color get color => runtimeDeltaSeconds > 0
      ? MimiVentColors.mint
      : runtimeDeltaSeconds < 0
          ? MimiVentColors.red
          : MimiVentColors.muted;

  String? get runtimeText {
    final seconds = runtimeDeltaSeconds.abs();
    if (seconds == 0) return '与昨日持平';
    final minutes = seconds / 60;
    final text = minutes < 10
        ? minutes.toStringAsFixed(minutes == minutes.roundToDouble() ? 0 : 1)
        : '${minutes.round()}';
    return '较昨日 ${runtimeDeltaSeconds > 0 ? '+' : '-'}$text 分钟 ${runtimeDeltaSeconds > 0 ? '↑' : '↓'}';
  }

  Color _countColor(int delta) => delta > 0
      ? MimiVentColors.mint
      : delta < 0
          ? MimiVentColors.red
          : MimiVentColors.muted;

  String? _countText(int delta) => delta == 0
      ? '与昨日持平'
      : '较昨日 ${delta > 0 ? '+' : '-'}${delta.abs()} ${delta > 0 ? '↑' : '↓'}';

  String? get activityText => _countText(activityDelta);
  Color get activityColor => _countColor(activityDelta);
  String? get autoExhaustText => _countText(autoExhaustDelta);
  Color get autoExhaustColor => _countColor(autoExhaustDelta);
  String? get toiletText => toiletAvailable ? _countText(toiletDelta) : null;
  Color get toiletColor => _countColor(toiletDelta);

  String? get toiletAverageText {
    if (!toiletAverageAvailable) return null;
    final delta = toiletAverageDeltaSeconds;
    if (delta == 0) return '与昨日持平';
    final seconds = delta.abs();
    final value = seconds >= 60
        ? '${(seconds / 60).toStringAsFixed(seconds % 60 == 0 ? 0 : 1)} 分钟'
        : '$seconds 秒';
    return '较昨日 ${delta > 0 ? '+' : '-'}$value ${delta > 0 ? '↑' : '↓'}';
  }

  Color get toiletAverageColor => _countColor(toiletAverageDeltaSeconds);
}

/// 事件图标：新接口（fromRange）与旧接口（fromDevice）共用同一套。
/// 两处各写一份会导致同一份数据在不同手机上显示不同图标。
Widget _eventIconFor(String kind) => switch (kind) {
      'activity' =>
        const Icon(Icons.sensors_rounded, size: 16, color: MimiVentColors.amber),
      'resume' =>
        const Icon(Icons.sensors_rounded, size: 16, color: MimiVentColors.mint),
      'manual' || 'automatic' || 'force' =>
        const FanRotorGlyph(color: MimiVentColors.mint, size: 6),
      'pause' => const Icon(Icons.pause_circle_outline_rounded,
          size: 16, color: Color(0xFF9AC8FF)),
      'locked_off' => const Icon(Icons.power_settings_new_rounded,
          size: 16, color: MimiVentColors.red),
      _ => const Icon(Icons.air_rounded,
          size: 16, color: MimiVentColors.mint),
    };

class _StatisticsPreview {
  const _StatisticsPreview({
    required this.rangeText,
    required this.runtimeSeconds,
    required this.runtimeMain,
    required this.runtimeUnit,
    required this.runtimeCaption,
    required this.activityCount,
    required this.autoExhaustCount,
    required this.toiletEstimateCount,
    required this.toiletEstimateAvailable,
    required this.toiletAverageSeconds,
    required this.toiletAverageAvailable,
    required this.chart,
    required this.maxChartValue,
    required this.chartTitle,
    required this.chartCaption,
    required this.events,
    required this.rawEventCount,
    required this.eventTotal,
    required this.eventsHasMore,
    required this.days,
    this.detailNotice,
    this.protocolMismatch = false,
    this.intervalEvents = const [],
  });

  final String rangeText;
  final int runtimeSeconds;
  final String runtimeMain;
  final String runtimeUnit;
  final String runtimeCaption;
  final int activityCount;
  final int autoExhaustCount;
  final int toiletEstimateCount;
  final bool toiletEstimateAvailable;
  final int? toiletAverageSeconds;
  final bool toiletAverageAvailable;
  final List<_ChartPoint> chart;
  final double maxChartValue;
  final String chartTitle;
  final String chartCaption;
  final List<_PreviewEvent> events;
  final int rawEventCount;
  final int eventTotal;
  final bool eventsHasMore;
  final List<_DailySummary> days;

  /// 详情降级的单条提示（过保留期 / 时间被调整 / 容量截断），无降级时为 null。
  final String? detailNotice;

  /// 点击某根柱时按该时间窗单独取回的事件；整范围刷新不会覆盖它。
  final List<_PreviewEvent> intervalEvents;

  /// 响应里有桶但一个已知字段都读不到：App 与固件的 key 名漂移。
  final bool protocolMismatch;

  String get toiletAverageMain {
    final seconds = toiletAverageSeconds;
    if (!toiletAverageAvailable || seconds == null || seconds <= 0) return '—';
    if (seconds >= 60) {
      final minutes = seconds / 60;
      return minutes.toStringAsFixed(minutes >= 10 ? 0 : 1);
    }
    return '$seconds';
  }

  String get toiletAverageUnit {
    final seconds = toiletAverageSeconds;
    if (!toiletAverageAvailable || seconds == null || seconds <= 0) return '';
    return seconds >= 60 ? '分钟' : '秒';
  }

  /// 新版范围接口（apiVersion 2）的呈现层转换。
  ///
  /// 粒度由固件决定，这里只按响应里的 buckets[] 画图：柱高 = 运行分钟数，
  /// 活动跨度 = activitySpanSeconds / 60。coveredSeconds 暂不参与归一化——
  /// 现有图表按整柱显示，"部分桶"留到 UI 重排时再处理。
  factory _StatisticsPreview.fromRange(
    _StatisticsRange range,
    Map<String, dynamic> json, {
    required String? currentMode,
    required bool snapshotOnly,
  }) {
    final summary = (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    final coverage = (json['coverage'] as Map?)?.cast<String, dynamic>() ?? const {};
    int? summaryInt(String key) {
      final value = summary[key];
      return value is num ? value.toInt() : null;
    }

    final buckets = (json['buckets'] as List?) ?? const [];
    // 协议自检：桶存在却读不到任何已知字段，说明 App 与固件的 key 名漂移了。
    // 这种情况不会报错，只会静默显示 0，必须显式记录才能发现。
    var protocolMismatch = false;
    if (buckets.isNotEmpty) {
      final first = buckets.first;
      if (first is Map) {
        protocolMismatch = !first.containsKey('rt') &&
            !first.containsKey('span') &&
            !first.containsKey('cov') &&
            !first.containsKey('bits');
      }
    }
    final bucketHours = _intValue(json['bucketHours']).clamp(1, 24);
    final chart = <_ChartPoint>[];
    for (final raw in buckets) {
      final bucket = (raw as Map).cast<String, dynamic>();
      final start = DateTime.fromMillisecondsSinceEpoch(
          _intValue(bucket['start']) * 1000);
      final end =
          DateTime.fromMillisecondsSinceEpoch(_intValue(bucket['end']) * 1000);
      // 精简后的短键；缺失即"不可用"，与原来的 null 语义一致。
      final runtimeSeconds = bucket['rt'];
      final spanSeconds = bucket['span'];
      final label = bucketHours >= 24
          ? '${start.month}/${start.day}'
          : start.hour.toString().padLeft(2, '0');
      chart.add(_ChartPoint(
        label,
        runtimeSeconds is num ? runtimeSeconds / 60 : 0,
        activityMinutes: spanSeconds is num ? spanSeconds / 60 : 0,
        runtimeAvailable: runtimeSeconds is num,
        activityAvailable: spanSeconds is num,
        activityEventCount: _intValue(bucket['trig']),
        intervalLabel: bucketHours >= 24
            ? '${_date(start)} 00:00–24:00'
            : '${_date(start)} ${_hourInterval(start.hour, bucketHours)}',
        startAt: start,
        endAt: end,
        groupLabel: bucketHours >= 24 ? '' : _date(start),
      ));
    }

    final runtimeSeconds = summaryInt('runtimeSeconds') ?? 0;
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
    final maxValue = chart.fold<double>(0, (best, point) {
      final value = math.max(point.minutes, point.activityMinutes);
      return value > best ? value : best;
    });

    final days = <_DailySummary>[];
    for (final raw in (json['days'] as List?) ?? const []) {
      final day = (raw as Map).cast<String, dynamic>();
      final date = _dateFromKey(_intValue(day['date']));
      final dayRuntime = day['rt'];
      final daySpan = day['span'];
      days.add(_DailySummary(
        label: '${date.month}/${date.day}',
        activityCount: _intValue(day['act']),
        exhaustCount: _intValue(day['auto']),
        runtimeMinutes: dayRuntime is num ? (dayRuntime / 60).round() : 0,
        activitySeconds: daySpan is num ? daySpan.round() : null,
        activityAvailable: daySpan is num,
      ));
    }

    final dayCount = _intValue(json['dayCount']);
    final from = DateTime.fromMillisecondsSinceEpoch(_intValue(json['from']) * 1000);
    final to = DateTime.fromMillisecondsSinceEpoch(_intValue(json['to']) * 1000);
    // 详情降级文案：优先级 OUT_OF_RETENTION > timeUntrusted > CAPACITY_LIMITED（§13.5）。
    String? detailNotice;
    final detail = (json['detail'] as Map?)?.cast<String, dynamic>();
    if (detail != null) {
      final status = detail['status']?.toString();
      if (status == 'MULTI_DAY') {
        detailNotice = null;
      } else if (status == 'OUT_OF_RETENTION') {
        detailNotice = '该日期明细已过保留期';
      } else if (detail['timeUntrusted'] == true) {
        detailNotice = '设备时间曾被调整，明细完整性无法保证；可在设置中重置统计批次';
      } else if (status == 'CAPACITY_LIMITED') {
        detailNotice = '事件记录已因容量限制被截断';
      }
    }

    // 末桶覆盖不足时不改数值，只在说明里标注，避免把"时段没走完"画成"排风变少"。
    var caption = bucketHours >= 24
        ? '每柱代表 1 天 · 柱高为排风分钟数'
        : '每柱代表 $bucketHours 小时 · 柱高为排风分钟数';
    if (chart.isNotEmpty) {
      final last = (buckets.last as Map).cast<String, dynamic>();
      final covered = _intValue(last['cov']);
      final full = bucketHours * 3600;
      if (covered > 0 && covered < full) {
        caption += ' · 末柱为部分时段（覆盖 ${(covered / 60).round()} 分钟）';
      }
    }
    // 升级前的日期没有跨度桶与入厕汇总：必须说明"不可用"，
    // 否则空柱和"—"会被读成"当天没有感应/没有入厕"。
    final missingSpan = coverage['activitySpan'] != true;
    final missingToilet = coverage['toilet'] != true;
    if (missingSpan && missingToilet) {
      caption += ' · 该范围含升级前数据，感应跨度与入厕汇总不可用';
    } else if (missingSpan) {
      caption += ' · 该范围含升级前数据，感应跨度不可用';
    } else if (missingToilet) {
      caption += ' · 该范围含升级前数据，入厕汇总不可用';
    }
    // 事件明细由页面额外调用 /api/events 合并进来；多日范围没有明细。
    // 同一段解析同时用于整范围的 events 和点柱窗口的 intervalEvents。
    List<_PreviewEvent> parseEvents(Object? rawList) {
      final parsed = <_PreviewEvent>[];
      for (final raw in (rawList as List?) ?? const []) {
        final event = (raw as Map).cast<String, dynamic>();
        final kind = event['kind']?.toString() ?? '';
        final at = _eventTimestamp(event);
        final duration = _intValue(event['durationSeconds']);
        final isActivity = kind == 'activity';
        final isFan = kind == 'automatic' || kind == 'manual' || kind == 'force';
        final title = switch (kind) {
          'activity' => '检测到活动',
          'automatic' => '自动排风',
          'manual' => '手动排风',
          'force' => '强制测试',
          'pause' => '暂停',
          'locked_off' => '持续关闭',
          'resume' => '恢复感应',
          _ => '设备事件',
        };
        final triggerCount = _intValue(event['triggerCount']);
        final detail = isActivity
            ? (triggerCount > 1 ? '触发 $triggerCount 次' : '单次触发') +
                (duration > 0
                    ? ' · ${_activitySpanLabel(Duration(seconds: duration))}'
                    : '')
            : duration > 0
                ? '运行 ${_activitySpanLabel(Duration(seconds: duration))}'
                : event['state'] == 'interrupted'
                    ? '被中断'
                    : '';
        parsed.add(_PreviewEvent(
          time: _clockTime(at),
          title: title,
          detail: detail,
          icon: _eventIconFor(kind),
          startAt: at,
          endAt: duration > 0 ? at.add(Duration(seconds: duration)) : null,
          isActivity: isActivity,
          isFan: isFan,
        ));
      }
      return parsed;
    }

    final events = parseEvents(json['events']);
    final intervalEvents = parseEvents(json['intervalEvents']);

    final toiletAvailable = coverage['toilet'] == true;
    return _StatisticsPreview(
      rangeText: dayCount <= 1
          ? _date(from)
          : '${_date(from)} — ${_date(to.subtract(const Duration(days: 1)))}',
      runtimeSeconds: runtimeSeconds,
      runtimeMain: runtimeMain,
      runtimeUnit: runtimeUnit,
      runtimeCaption: json['timeSynced'] == false
          ? '设备时间未校准，暂无法按日期统计'
          : snapshotOnly
              ? '离线快照 · 数据来自本机缓存'
              : '数据来自设备范围查询',
      activityCount: summaryInt('activityCount') ?? 0,
      autoExhaustCount: summaryInt('automaticCount') ?? 0,
      toiletEstimateCount: summaryInt('toiletSampleCount') ?? 0,
      toiletEstimateAvailable: toiletAvailable,
      toiletAverageSeconds: summaryInt('toiletAverageSeconds'),
      toiletAverageAvailable: toiletAvailable,
      chart: chart,
      maxChartValue: maxValue,
      chartTitle: bucketHours >= 24 ? '每日排风与感应跨度' : '分时排风与感应跨度',
      chartCaption: caption,
      events: events,
      rawEventCount: events.length,
      eventTotal: _intValue(json['eventsTotal']) > 0
          ? _intValue(json['eventsTotal'])
          : events.length,
      eventsHasMore: json['eventsHasMore'] == true,
      days: days,
      detailNotice: detailNotice,
      intervalEvents: intervalEvents,
      protocolMismatch: protocolMismatch,
    );
  }

  factory _StatisticsPreview.emptyForRange(_StatisticsRange range) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOffset = switch (range) {
      _StatisticsRange.today => 0,
      _StatisticsRange.yesterday => 1,
      _StatisticsRange.dayBeforeYesterday => 2,
      _StatisticsRange.custom => 6,
      _StatisticsRange.sevenDays => 6,
    };
    final start = today.subtract(Duration(days: startOffset));
    final dayCount = switch (range) {
      _StatisticsRange.today ||
      _StatisticsRange.yesterday ||
      _StatisticsRange.dayBeforeYesterday =>
        1,
      _StatisticsRange.custom => 1,
      _StatisticsRange.sevenDays => 7,
    };
    final chart = switch (range) {
      _StatisticsRange.today => List.generate(
          24,
          (index) => _ChartPoint(index.toString().padLeft(2, '0'), 0,
              intervalLabel: _hourInterval(index, 1),
              startAt: today.add(Duration(hours: index)),
              endAt: today.add(Duration(hours: index + 1)))),
      _StatisticsRange.yesterday ||
      _StatisticsRange.dayBeforeYesterday =>
        List.generate(
            12,
            (index) => _ChartPoint((index * 2).toString().padLeft(2, '0'), 0,
                intervalLabel: _hourInterval(index * 2, 2),
                startAt: start.add(Duration(hours: index * 2)),
                endAt: start.add(Duration(hours: (index + 1) * 2)))),
      // custom 未选日期时的占位骨架：24 小时零值。
      _StatisticsRange.custom => List.generate(
          24,
          (index) => _ChartPoint(index.toString().padLeft(2, '0'), 0,
              intervalLabel: _hourInterval(index, 1),
              startAt: today.add(Duration(hours: index)),
              endAt: today.add(Duration(hours: index + 1)))),
      _StatisticsRange.sevenDays => List.generate(7, (index) {
          final date = start.add(Duration(days: index));
          return _ChartPoint('${date.month}/${date.day}', 0,
              intervalLabel: '${_date(date)} 00:00–24:00',
              startAt: date,
              endAt: date.add(const Duration(days: 1)));
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
        activitySeconds: 0,
        activityAvailable: true,
      );
    });
    return _StatisticsPreview(
      rangeText: range == _StatisticsRange.today
          ? _date(today)
          : range == _StatisticsRange.yesterday
              ? _date(start)
              : '${_date(start)} — ${_date(today)}',
      runtimeSeconds: 0,
      runtimeMain: '0',
      runtimeUnit: '分钟',
      runtimeCaption: '等待设备统计数据',
      activityCount: 0,
      autoExhaustCount: 0,
      toiletEstimateCount: 0,
      toiletEstimateAvailable: true,
      toiletAverageSeconds: null,
      toiletAverageAvailable: false,
      chart: chart,
      maxChartValue: 0,
      chartTitle:
          range == _StatisticsRange.sevenDays ? '每日排风与感应跨度' : '分时排风与感应跨度',
      chartCaption: switch (range) {
        _StatisticsRange.today => '上方排风、下方感应跨度 · 每柱代表 1 小时',
        _StatisticsRange.yesterday ||
        _StatisticsRange.dayBeforeYesterday =>
          '上方排风、下方感应跨度 · 每柱代表 2 小时',
        _StatisticsRange.custom => '请先选择时间范围',
        _StatisticsRange.sevenDays => '每柱代表 1 天 · 上方排风、下方感应跨度',
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
      {String? currentMode,
      bool snapshotOnly = false,
      int activityGapSeconds = 120}) {
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
    final rawActivityBuckets = json['activityBucketSeconds'];
    final activityBucketSeconds = rawActivityBuckets is List
        ? rawActivityBuckets.map(_intValue).toList()
        : <int>[];
    final rawActivityCounts = json['activityBucketCount'];
    final activityBucketCount = rawActivityCounts is List
        ? rawActivityCounts.map(_intValue).toList()
        : <int>[];
    final rawDays = json['days'];
    final dayRows = rawDays is List
        ? rawDays
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .toList()
        : <Map<String, dynamic>>[];

    late List<_ChartPoint> chart;
    if (range == _StatisticsRange.today) {
      chart = List.generate(
          24,
          (index) => _ChartPoint(
                index.toString().padLeft(2, '0'),
                (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
                activityMinutes: (index < activityBucketSeconds.length
                        ? activityBucketSeconds[index]
                        : 0) /
                    60,
                activityEventCount: index < activityBucketCount.length
                    ? activityBucketCount[index]
                    : 0,
                intervalLabel:
                    '${_date(today)} ${_hourInterval(index, 1)}',
                startAt: today.add(Duration(hours: index)),
                endAt: today.add(Duration(hours: index + 1)),
              ));
    } else if (range == _StatisticsRange.yesterday) {
      chart = List.generate(
          12,
          (index) => _ChartPoint(
                (index * 2).toString().padLeft(2, '0'),
                (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
                activityMinutes: (index < activityBucketSeconds.length
                        ? activityBucketSeconds[index]
                        : 0) /
                    60,
                activityEventCount: index < activityBucketCount.length
                    ? activityBucketCount[index]
                    : 0,
                intervalLabel: '${_date(today.subtract(const Duration(days: 1)))} '
                    '${_hourInterval(index * 2, 2)}',
                startAt: today
                    .subtract(const Duration(days: 1))
                    .add(Duration(hours: index * 2)),
                endAt: today
                    .subtract(const Duration(days: 1))
                    .add(Duration(hours: (index + 1) * 2)),
              ));
    } else if (range == _StatisticsRange.custom) {
      final firstDate = today.subtract(const Duration(days: 2));
      chart = List.generate(9, (index) {
        final day = firstDate.add(Duration(days: index ~/ 3));
        final hour = (index % 3) * 8;
        return _ChartPoint(hour.toString().padLeft(2, '0'),
            (index < bucketSeconds.length ? bucketSeconds[index] : 0) / 60,
            activityMinutes: (index < activityBucketSeconds.length
                    ? activityBucketSeconds[index]
                    : 0) /
                60,
            activityEventCount: index < activityBucketCount.length
                ? activityBucketCount[index]
                : 0,
            intervalLabel: '${_date(day)} ${_hourInterval(hour, 8)}',
            startAt: day.add(Duration(hours: hour)),
            endAt: day.add(Duration(hours: hour + 8)),
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
            activityMinutes: (index < activityBucketSeconds.length
                    ? activityBucketSeconds[index]
                    : 0) /
                60,
            activityEventCount: index < activityBucketCount.length
                ? activityBucketCount[index]
                : 0,
            intervalLabel: '${_date(date)} 00:00–24:00',
            startAt: date,
            endAt: date.add(const Duration(days: 1)));
      });
    }

    final chronologicalEvents = <_PreviewEvent>[];
    var toiletEstimate = 0;
    var toiletDurationSeconds = 0;
    var toiletDurationSamples = 0;
    var automaticEventsInPage = 0;
    final summaryToilet = json['toiletCount'];
    final summaryToiletAverage = json['toiletAverageSeconds'];
    final summaryToiletSamples = json['toiletSampleCount'];
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

      // 预计入厕：只统计自动排风，且实际排风时长达到设定时长的一半。
      // 手动排风、临时强制排风不计入；PIR 打断导致不足一半也不计入。
      for (var index = 0; index < ordered.length; index++) {
        final event = ordered[index].cast<String, dynamic>();
        if (event['kind'] != 'automatic') continue;
        automaticEventsInPage++;
        final configured = _intValue(event['durationSeconds']);
        if (configured <= 0) continue;
        final start = _eventTimestamp(event);
        final next = nextControlEventTime(index);
        final elapsed = next == null
            ? (event['state'] == 'active'
                ? DateTime.now().difference(start).inSeconds
                : configured)
            : math.max(0, next.difference(start).inSeconds);
        final effective = math.min(configured, elapsed);
        if (effective * 2 >= configured) {
          toiletEstimate++;
          toiletDurationSeconds += effective;
          toiletDurationSamples++;
        }
      }

      var index = 0;
      while (index < ordered.length) {
        final event = ordered[index].cast<String, dynamic>();
        final kind = event['kind']?.toString() ?? 'automatic';
        final timestamp = _eventTimestamp(event);
        if (kind == 'activity') {
          final encodedCount = _intValue(event['triggerCount']);
          final encodedSpan = _intValue(event['durationSeconds']);
          if (encodedCount > 1 || encodedSpan > 0) {
            final count = encodedCount > 0 ? encodedCount : 1;
            final rangeEnd = timestamp.add(Duration(seconds: encodedSpan));
            final timeRange = _activityTimeRange(timestamp, rangeEnd);
            chronologicalEvents.add(_PreviewEvent(
              time: _clockTime(timestamp),
              title: count == 1 ? '检测到活动' : '连续感应 · $count 次',
              detail: count == 1
                  ? '$timeRange · 单次'
                  : '$timeRange · ${_activitySpanLabel(Duration(seconds: encodedSpan))}',
              icon: const Icon(Icons.sensors_rounded,
                  size: 16, color: MimiVentColors.amber),
              startAt: timestamp,
              endAt: rangeEnd,
              isActivity: true,
            ));
            index++;
            continue;
          }
          var lastTimestamp = timestamp;
          var next = index + 1;
          while (next < ordered.length) {
            final nextEvent = ordered[next].cast<String, dynamic>();
            if (nextEvent['kind'] != 'activity') break;
            final nextTimestamp = _eventTimestamp(nextEvent);
            if (nextTimestamp.difference(lastTimestamp).inSeconds >
                activityGapSeconds) {
              break;
            }
            lastTimestamp = nextTimestamp;
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
                    : '$timeRange · ${_activitySpanLabel(span)}',
            icon: const Icon(Icons.sensors_rounded,
                size: 16, color: MimiVentColors.amber),
            startAt: rangeStart,
            endAt: rangeEnd,
            isActivity: true,
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
        // 与 fromRange 共用同一套图标与配色，保证两条数据源显示一致。
        final icon = _eventIconFor(kind);
        chronologicalEvents.add(_PreviewEvent(
          time: _clockTime(timestamp),
          title: title,
          detail: detail,
          icon: icon,
          startAt: timestamp,
          endAt: timestamp.add(Duration(
              seconds: state == 'active'
                  ? math.max(0, now.difference(timestamp).inSeconds)
                  : configuredDuration)),
          isFan: kind == 'automatic' || kind == 'manual' || kind == 'force',
        ));
        index++;
      }
    }
    final events = chronologicalEvents.reversed.toList();

    final days = <_DailySummary>[];
    for (final day in dayRows) {
      final date = _dateFromKey(_intValue(day['date']));
      final legacySpan = day['activitySpanSeconds'];
      days.add(_DailySummary(
        label: _dayLabel(date, today),
        activityCount: _intValue(day['activityCount']),
        exhaustCount: _intValue(day['automaticCount']),
        runtimeMinutes: _intValue(day['runtimeSeconds']) ~/ 60,
        activitySeconds: legacySpan is num ? legacySpan.round() : null,
        activityAvailable: legacySpan is num,
      ));
    }
    // 设备端 activityBucketSeconds 只保存已合并的活动段跨度；单次触发和旧记录
    // 可能为 0。今日/昨日已有事件列表时，用同一活动段的首末触发时间补齐图表。
    if (range == _StatisticsRange.today ||
        range == _StatisticsRange.yesterday) {
      final spans = <int, double>{};
      for (final event in chronologicalEvents) {
        final start = event.startAt;
        final end = event.endAt;
        if (!event.isActivity || start == null || end == null) continue;
        final seconds = end.difference(start).inSeconds;
        if (seconds <= 0) continue;
        final local = start.toLocal();
        final bucket =
            range == _StatisticsRange.today ? local.hour : local.hour ~/ 2;
        spans[bucket] = (spans[bucket] ?? 0) + seconds / 60;
      }
      chart = List.generate(chart.length, (index) {
        final point = chart[index];
        final computed = spans[index] ?? 0;
        if (computed <= point.activityMinutes) return point;
        return point.copyWith(activityMinutes: computed);
      });
    }

    final maxValue = chart.fold<double>(0, (max, point) {
      final pointMax = math.max(point.minutes, point.activityMinutes);
      return pointMax > max ? pointMax : max;
    });
    final rangeText = range == _StatisticsRange.today
        ? _date(today)
        : range == _StatisticsRange.yesterday
            ? _date(today.subtract(const Duration(days: 1)))
            : '${_date(today.subtract(const Duration(days: 6)))} — ${_date(today)}';

    return _StatisticsPreview(
      rangeText: rangeText,
      runtimeSeconds: runtimeSeconds,
      runtimeMain: runtimeMain,
      runtimeUnit: runtimeUnit,
      runtimeCaption: json['timeSynced'] == true
          ? (json['active'] == true
              ? '风机累计运行时长 · 含当前运行和手动排风'
              : '风机累计运行时长 · 含手动排风')
          : '设备时间待校准；校准后回填本次开机以来的统计',
      activityCount: _intValue(json['activityCount']),
      autoExhaustCount: _intValue(json['automaticCount']),
      toiletEstimateCount:
          summaryToilet is num ? summaryToilet.toInt() : toiletEstimate,
      toiletEstimateAvailable: summaryToilet is num ||
          automaticEventsInPage > 0 ||
          _intValue(json['automaticCount']) == 0,
      toiletAverageSeconds: summaryToiletSamples is num &&
              summaryToiletSamples > 0 &&
              summaryToiletAverage is num
          ? summaryToiletAverage.toInt()
          : toiletDurationSamples > 0
              ? (toiletDurationSeconds / toiletDurationSamples).round()
              : null,
      toiletAverageAvailable: summaryToiletSamples is num
          ? summaryToiletSamples > 0
          : toiletDurationSamples > 0,
      chart: chart,
      maxChartValue: _niceAxisMaximum(maxValue),
      chartTitle:
          range == _StatisticsRange.sevenDays ? '每日排风与感应跨度' : '分时排风与感应跨度',
      chartCaption: switch (range) {
        _StatisticsRange.today => '上方排风、下方感应跨度 · 每柱代表 1 小时',
        _StatisticsRange.yesterday ||
        _StatisticsRange.dayBeforeYesterday =>
          '上方排风、下方感应跨度 · 每柱代表 2 小时',
        _StatisticsRange.custom => '请先选择时间范围',
        _StatisticsRange.sevenDays => '每柱代表 1 天 · 上方排风、下方感应跨度',
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
      detailNotice: json['eventsTruncated'] == true
          ? '部分历史明细已淘汰，仅显示现有记录' : null,
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
    final startText = '${_twoDigits(start.hour)}:${_twoDigits(start.minute)}';
    final endText = '${_twoDigits(end.hour)}:${_twoDigits(end.minute)}';
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
      {this.activityMinutes = 0,
      this.runtimeAvailable = true,
      this.activityAvailable = true,
      this.activityEventCount = 0,
      this.intervalLabel = '',
      this.groupLabel = '',
      this.startAt,
      this.endAt});

  final String label;
  final double minutes;
  final double activityMinutes;
  final bool runtimeAvailable;
  final bool activityAvailable;
  final int activityEventCount;
  final String intervalLabel;
  final String groupLabel;
  final DateTime? startAt;
  final DateTime? endAt;

  _ChartPoint copyWith({double? activityMinutes}) => _ChartPoint(
        label,
        minutes,
        activityMinutes: activityMinutes ?? this.activityMinutes,
        runtimeAvailable: runtimeAvailable,
        activityAvailable: activityAvailable,
        activityEventCount: activityEventCount,
        intervalLabel: intervalLabel,
        groupLabel: groupLabel,
        startAt: startAt,
        endAt: endAt,
      );
}

class _StatisticsChartPainter extends CustomPainter {
  const _StatisticsChartPainter({
    required this.points,
    required this.maxValue,
    required this.selectedIndex,
  });

  // Y 轴标签最宽是 "34.3"（fontSize 8 约 22px），留 32 足够；再收窄会裁字。
  static const double leftInset = 32;
  final List<_ChartPoint> points;
  final double maxValue;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= leftInset + 8) return;
    const top = 7.0;
    const bottomInset = 30.0;
    const rightInset = 4.0;
    final bottom = size.height - bottomInset;
    final baseline = (top + bottom) / 2;
    final halfHeight = baseline - top;
    final plotWidth = size.width - leftInset - rightInset;
    final axisMaximum = maxValue > 0 ? maxValue : 1.0;
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(.09)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = Colors.white.withOpacity(.2)
      ..strokeWidth = 1;

    for (var tick = 0; tick <= 4; tick++) {
      final value = axisMaximum * tick / 4;
      final distance = value / axisMaximum * halfHeight;
      final upperY = baseline - distance;
      final lowerY = baseline + distance;
      canvas.drawLine(
          Offset(leftInset, upperY),
          Offset(size.width - rightInset, upperY),
          tick == 0 ? axisPaint : gridPaint);
      _drawText(canvas, _formatMinutes(value), Offset(0, upperY - 5),
          maxWidth: leftInset - 6,
          align: TextAlign.right,
          color: MimiVentColors.muted,
          fontSize: 8);
      if (tick > 0) {
        canvas.drawLine(Offset(leftInset, lowerY),
            Offset(size.width - rightInset, lowerY), gridPaint);
        _drawText(canvas, _formatMinutes(value), Offset(0, lowerY - 5),
            maxWidth: leftInset - 6,
            align: TextAlign.right,
            color: MimiVentColors.muted,
            fontSize: 8);
      }
    }
    canvas.drawLine(
        const Offset(leftInset, top), Offset(leftInset, baseline), axisPaint);

    final slotWidth = plotWidth / points.length;
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final centerX = leftInset + slotWidth * (index + .5);
      final fanHeight =
          (point.minutes.clamp(0.0, axisMaximum) / axisMaximum) * halfHeight;
      final scaledActivityHeight =
          (point.activityMinutes.clamp(0.0, axisMaximum) / axisMaximum) *
              halfHeight;
      final activityHeight =
          scaledActivityHeight > 0 ? math.max(2.5, scaledActivityHeight) : 0.0;
      if (index == selectedIndex) {
        final highlight = Paint()..color = MimiVentColors.mint.withOpacity(.07);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
                leftInset + index * slotWidth, top, slotWidth, bottom - top),
            const Radius.circular(4),
          ),
          highlight,
        );
      }
      final barWidth = math.min(16.0, math.max(3.0, slotWidth * .52));
      // 不可用与真实零值分开：对应半区画灰色斜线，不绘制零柱。
      for (final upper in [true, false]) {
        if (upper ? point.runtimeAvailable : point.activityAvailable) continue;
        final area = Rect.fromLTWH(centerX - barWidth / 2,
            upper ? baseline - halfHeight : baseline, barWidth, halfHeight);
        canvas.save();
        canvas.clipRect(area);
        final unavailablePaint = Paint()
          ..color = MimiVentColors.muted.withOpacity(.35)
          ..strokeWidth = 1;
        for (double y = area.top - barWidth; y < area.bottom; y += 6) {
          canvas.drawLine(Offset(area.left, y),
              Offset(area.right, y + barWidth), unavailablePaint);
        }
        canvas.restore();
      }
      final barPaint = Paint()..color = MimiVentColors.mint.withOpacity(.82);
      if (point.runtimeAvailable && fanHeight > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(centerX - barWidth / 2, baseline - fanHeight,
                barWidth, fanHeight),
            const Radius.circular(4),
          ),
          barPaint,
        );
      }
      if (point.activityAvailable && activityHeight > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
                centerX - barWidth / 2, baseline, barWidth, activityHeight),
            const Radius.circular(4),
          ),
          Paint()..color = MimiVentColors.amber.withOpacity(.86),
        );
      }
    }

    final labelStep = points.length >= 20
        ? 4
        : points.length >= 12
            ? 2
            : 1;
    // 柱数多时 slotWidth 只有十来个像素，"11/03" 这类标签会被 maxWidth 裁掉，
    // 看起来就是"横坐标不见了"。这里放宽到实际可用宽度，并把长标签压成日号。
    final labelWidth = slotWidth * labelStep;
    // 首尾必须标出完整日期（含月份），否则 30 天视图只剩"7 11 15"这种日号，
    // 完全看不出是哪个月的区间；中间部分用日号即可，避免挤在一起。
    final labelIndices = <int>[];
    if (points.isNotEmpty) {
      for (var index = 0; index < points.length; index += labelStep) {
        if (index > 0 && points.length - 1 - index < labelStep) break;
        labelIndices.add(index);
      }
      // points 为空时 points.length - 1 是 -1，会让下面的 points[index] 越界。
      if (labelIndices.isEmpty || labelIndices.last != points.length - 1) {
        labelIndices.add(points.length - 1);
      }
    }
    for (final index in labelIndices) {
      final point = points[index];
      final centerX = leftInset + slotWidth * (index + .5);
      final isEdge = index == 0 || index == points.length - 1;
      var text = point.label;
      if (!isEdge && points.length >= 20 && text.contains('/')) {
        text = text.split('/').last;
      }
      _drawText(
        canvas,
        text,
        // 标签保持在柱子正下方居中；只用 maxWidth 放宽，允许文字略溢出到相邻空白。
        Offset(centerX - slotWidth / 2, bottom + 4),
        maxWidth: labelWidth * .92,
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

String _formatStatisticMinutes(double value) {
  if (!value.isFinite || value <= 0) return '0秒';
  final seconds = (value * 60).round();
  if (seconds < 60) return '$seconds秒';
  final roundedMinutes = (seconds / 60 * 10).round() / 10;
  final text = roundedMinutes == roundedMinutes.roundToDouble()
      ? roundedMinutes.toInt().toString()
      : roundedMinutes.toStringAsFixed(1);
  return '$text分钟';
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

class _DetailTimelineRow {
  const _DetailTimelineRow({this.activity, this.fan});

  final _PreviewEvent? activity;
  final _PreviewEvent? fan;

  DateTime get sortAt =>
      (activity ?? fan)!.startAt ?? DateTime.fromMillisecondsSinceEpoch(0);
}

class _PreviewEvent {
  const _PreviewEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.icon,
    this.startAt,
    this.endAt,
    this.isActivity = false,
    this.isFan = false,
  });

  final String time;
  final String title;
  final String detail;
  final Widget icon;
  final DateTime? startAt;
  final DateTime? endAt;
  final bool isActivity;
  final bool isFan;
}

class _DailySummary {
  const _DailySummary({
    required this.label,
    required this.activityCount,
    required this.exhaustCount,
    required this.runtimeMinutes,
    required this.activitySeconds,
    required this.activityAvailable,
  });

  final String label;
  final int activityCount;
  final int exhaustCount;
  final int runtimeMinutes;
  /// 当日感应跨度合计；不可用时为 null（activityAvailable 为 false）。
  final int? activitySeconds;
  final bool activityAvailable;
}

/// 年/月/日三列滚轮，全部使用数字。
///
/// 不可选的年、月、日直接不出现在列表里（而不是置灰），
/// 因此滚轮永远停不到范围外的日期，也不需要额外的 clamp 逻辑。
class _DateWheel extends StatefulWidget {
  const _DateWheel({
    required this.first,
    required this.last,
    required this.initial,
    required this.onChanged,
  });

  final DateTime first;
  final DateTime last;
  final DateTime initial;
  final ValueChanged<DateTime> onChanged;

  @override
  State<_DateWheel> createState() => _DateWheelState();
}

class _DateWheelState extends State<_DateWheel> {
  late int _year;
  late int _month;
  late int _day;
  late FixedExtentScrollController _yearCtl;
  late FixedExtentScrollController _monthCtl;
  late FixedExtentScrollController _dayCtl;
  late List<int> _years;
  late List<int> _months;
  late List<int> _days;

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
    _month = widget.initial.month;
    _day = widget.initial.day;
    _rebuildLists();
    _yearCtl = FixedExtentScrollController(initialItem: _years.indexOf(_year));
    _monthCtl =
        FixedExtentScrollController(initialItem: _months.indexOf(_month));
    _dayCtl = FixedExtentScrollController(initialItem: _days.indexOf(_day));
  }

  @override
  void dispose() {
    _yearCtl.dispose();
    _monthCtl.dispose();
    _dayCtl.dispose();
    super.dispose();
  }

  int _daysInMonth(int year, int month) =>
      DateTime(year, month + 1, 0).day;

  bool _daySelectable(int day) {
    final candidate = DateTime(_year, _month, day);
    return !candidate.isBefore(widget.first) && !candidate.isAfter(widget.last);
  }

  bool _monthSelectable(int month) {
    for (var d = 1; d <= _daysInMonth(_year, month); d++) {
      final candidate = DateTime(_year, month, d);
      if (!candidate.isBefore(widget.first) && !candidate.isAfter(widget.last)) {
        return true;
      }
    }
    return false;
  }

  void _rebuildLists() {
    _years = [
      for (var y = widget.first.year; y <= widget.last.year; y++) y,
    ];
    _months = [
      for (var m = 1; m <= 12; m++)
        if (_monthSelectable(m)) m,
    ];
    if (!_months.contains(_month)) _month = _months.first;
    _days = [
      for (var d = 1; d <= _daysInMonth(_year, _month); d++)
        if (_daySelectable(d)) d,
    ];
    if (!_days.contains(_day)) _day = _days.first;
  }

  void _emit() => widget.onChanged(DateTime(_year, _month, _day));

  void _onYearChanged(int index) {
    setState(() {
      _year = _years[index];
      _rebuildLists();
    });
    _syncWheel(_monthCtl, _months, _month);
    _syncWheel(_dayCtl, _days, _day);
    _emit();
  }

  void _onMonthChanged(int index) {
    setState(() {
      _month = _months[index];
      _rebuildLists();
    });
    _syncWheel(_dayCtl, _days, _day);
    _emit();
  }

  void _onDayChanged(int index) {
    setState(() => _day = _days[index]);
    _emit();
  }

  /// 列表重建后把控制器对齐到仍然有效的值，避免索引越界。
  void _syncWheel(
      FixedExtentScrollController ctl, List<int> values, int current) {
    final target = values.indexOf(current);
    if (target < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ctl.hasClients) ctl.jumpToItem(target);
    });
  }

  Widget _column(String suffix, List<int> values,
      FixedExtentScrollController ctl, ValueChanged<int> onChanged) {
    return Expanded(
      child: ListWheelScrollView.useDelegate(
        controller: ctl,
        itemExtent: 40,
        diameterRatio: 1.6,
        perspective: 0.003,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: onChanged,
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: values.length,
          builder: (context, index) => Center(
            child: Text(
              '${values[index]}$suffix',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 200,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.06),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            Row(children: [
              _column('年', _years, _yearCtl, _onYearChanged),
              _column('月', _months, _monthCtl, _onMonthChanged),
              _column('日', _days, _dayCtl, _onDayChanged),
            ]),
          ],
        ),
      );
}
