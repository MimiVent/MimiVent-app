import 'dart:convert';

enum TimingProfile { production, dev }

/// 可查询的设备原始事件类型；all 表示不过滤类型。
enum DeviceEventKind {
  all,
  activity,
  automatic,
  manual,
  force,
  pause,
  lockedOff,
  resume
}

extension DeviceEventKindValue on DeviceEventKind {
  String get wireValue => switch (this) {
        DeviceEventKind.all => 'all',
        DeviceEventKind.activity => 'activity',
        DeviceEventKind.automatic => 'automatic',
        DeviceEventKind.manual => 'manual',
        DeviceEventKind.force => 'force',
        DeviceEventKind.pause => 'pause',
        DeviceEventKind.lockedOff => 'locked_off',
        DeviceEventKind.resume => 'resume',
      };
}

/// 通用原始事件查询条件，时间范围采用左闭右开 [start, end)。
/// 可用于最近 24 小时、昨日、某天或任意自定义区间，并支持事件类型和分页。
class DeviceEventQuery {
  const DeviceEventQuery({
    required this.start,
    required this.end,
    this.kind = DeviceEventKind.all,
    this.offset = 0,
    this.limit = 32,
    this.beforeId,
    this.dataEpoch,
  });

  final DateTime start;
  final DateTime end;
  final DeviceEventKind kind;
  final int offset;
  final int limit;
  final int? beforeId;
  final String? dataEpoch;

  /// 为某个本地自然日创建查询，正确处理跨日及夏令时日长变化。
  factory DeviceEventQuery.forLocalDay(
    DateTime day, {
    DeviceEventKind kind = DeviceEventKind.all,
    int offset = 0,
    int limit = 32,
    int? beforeId,
    String? dataEpoch,
  }) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    return DeviceEventQuery(
      start: start,
      end: end,
      kind: kind,
      offset: offset,
      limit: limit,
      beforeId: beforeId,
      dataEpoch: dataEpoch,
    );
  }

  Map<String, String> toQueryParameters() {
    if (!end.isAfter(start)) {
      throw ArgumentError.value(end, 'end', '必须晚于 start');
    }
    if (beforeId == null && (offset < 0 || offset > 512)) {
      throw RangeError.range(offset, 0, 512, 'offset');
    }
    if (limit < 1 || limit > 32) {
      throw RangeError.range(limit, 1, 32, 'limit');
    }
    if (beforeId != null && beforeId! <= 0) {
      throw RangeError.value(beforeId!, 'beforeId', '必须大于 0');
    }
    return {
      'start': '${start.millisecondsSinceEpoch ~/ 1000}',
      'end': '${end.millisecondsSinceEpoch ~/ 1000}',
      'kind': kind.wireValue,
      'limit': '$limit',
      if (dataEpoch != null && dataEpoch!.isNotEmpty) 'dataEpoch': dataEpoch!,
      if (beforeId != null) 'beforeId': '$beforeId' else 'offset': '$offset',
    };
  }
}

class DeviceEvent {
  const DeviceEvent({
    required this.time,
    required this.kind,
    required this.state,
    required this.durationSeconds,
    this.id,
    this.triggerCount = 0,
  });

  final int? id;
  final int time;
  final String kind;
  final String state;
  final int durationSeconds;
  final int triggerCount;

  factory DeviceEvent.fromJson(Map<String, dynamic> json) {
    final time = json['time'];
    final kind = json['kind'];
    final state = json['state'];
    final duration = json['durationSeconds'];
    final id = json['id'];
    final triggerCount = json['triggerCount'];
    if (time is! num ||
        kind is! String ||
        state is! String ||
        duration is! num ||
        (id != null && id is! num) ||
        (triggerCount != null && triggerCount is! num)) {
      throw const FormatException('设备事件字段缺失或类型无效');
    }
    if (time < 0 ||
        time > 0xFFFFFFFF ||
        duration < 0 ||
        duration > 0xFFFFFFFF ||
        time != time.toInt() ||
        duration != duration.toInt() ||
        (triggerCount is num &&
            (triggerCount < 0 ||
                triggerCount > 0xFFFF ||
                triggerCount != triggerCount.toInt())) ||
        (id is num && (id < 1 || id > 0xFFFFFFFF || id != id.toInt()))) {
      throw const FormatException('设备事件数值超出协议范围');
    }
    return DeviceEvent(
      id: id is num ? id.toInt() : null,
      time: time.toInt(),
      kind: kind,
      state: state,
      durationSeconds: duration.toInt(),
      triggerCount: triggerCount is num ? triggerCount.toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'time': time,
        'kind': kind,
        'state': state,
        'durationSeconds': durationSeconds,
        if (triggerCount > 0) 'triggerCount': triggerCount,
      };
}

class DeviceEventPage {
  const DeviceEventPage({
    required this.events,
    required this.offset,
    required this.nextOffset,
    required this.total,
    required this.hasMore,
    this.eventsTruncated = false,
    this.start = 0,
    this.end = 0,
    this.nextCursor,
    this.deviceId,
    this.dataEpoch,
  });

  final List<DeviceEvent> events;
  final int offset;
  final int nextOffset;
  final int total;
  final bool hasMore;
  final bool eventsTruncated;
  final int? nextCursor;
  final int start;
  final int end;
  final String? deviceId;
  final String? dataEpoch;

  factory DeviceEventPage.fromJson(
    Map<String, dynamic> json, {
    required int requestedStart,
    required int requestedEnd,
  }) {
    final rawEvents = json['events'];
    if (rawEvents is! List) {
      throw const FormatException('设备事件响应缺少 events 列表');
    }
    final rawOffset = json['offset'];
    final rawNextOffset = json['nextOffset'];
    final rawTotal = json['total'];
    final rawHasMore = json['hasMore'];
    final rawNextCursor = json['nextCursor'];
    final rawStart = json['start'] ?? requestedStart;
    final rawEnd = json['end'] ?? requestedEnd;
    if (rawOffset is! num ||
        rawNextOffset is! num ||
        rawTotal is! num ||
        rawHasMore is! bool ||
        rawStart is! num ||
        rawEnd is! num ||
        (rawNextCursor != null && rawNextCursor is! num)) {
      throw const FormatException('设备事件分页字段缺失或类型无效');
    }
    if (rawOffset < 0 ||
        rawNextOffset < 0 ||
        rawTotal < 0 ||
        rawStart < 0 ||
        rawEnd < rawStart ||
        (rawNextCursor is num && rawNextCursor < 0)) {
      throw const FormatException('设备事件分页数值无效');
    }
    if (rawEvents.any((event) => event is! Map)) {
      throw const FormatException('设备事件列表包含无效记录');
    }
    return DeviceEventPage(
      events: rawEvents
          .whereType<Map>()
          .map(
              (event) => DeviceEvent.fromJson(Map<String, dynamic>.from(event)))
          .toList(growable: false),
      offset: rawOffset.toInt(),
      nextOffset: rawNextOffset.toInt(),
      total: rawTotal.toInt(),
      hasMore: rawHasMore,
      eventsTruncated: json['eventsTruncated'] == true,
      start: rawStart.toInt(),
      end: rawEnd.toInt(),
      nextCursor: rawNextCursor is num && rawNextCursor > 0
          ? rawNextCursor.toInt()
          : null,
      deviceId: json['deviceId'] is String ? json['deviceId'] as String : null,
      dataEpoch:
          json['dataEpoch'] is String ? json['dataEpoch'] as String : null,
    );
  }
}

extension TimingProfileValue on TimingProfile {
  String get wireValue => this == TimingProfile.dev ? 'dev' : 'production';
  String get label => this == TimingProfile.dev ? 'DEV 联调' : '正式运行';
}

class TimingSettings {
  const TimingSettings({
    required this.startupCooldownMs,
    required this.leaveConfirmMs,
    required this.autoExhaustMs,
    required this.manualExhaustMs,
    required this.pauseMs,
  });

  final int startupCooldownMs;
  final int leaveConfirmMs;
  final int autoExhaustMs;
  final int manualExhaustMs;
  final int pauseMs;

  factory TimingSettings.fromJson(Map<String, dynamic> json) {
    return TimingSettings(
      startupCooldownMs: _requiredDuration(json, 'startupCooldownMs'),
      leaveConfirmMs: _requiredDuration(
        json,
        'leaveConfirmMs',
        allowZero: true,
      ),
      autoExhaustMs: _requiredDuration(json, 'autoExhaustMs'),
      manualExhaustMs: _requiredDuration(json, 'manualExhaustMs'),
      pauseMs: _requiredDuration(json, 'pauseMs'),
    );
  }

  Map<String, int> toJson() => {
        'startupCooldownMs': startupCooldownMs,
        'leaveConfirmMs': leaveConfirmMs,
        'autoExhaustMs': autoExhaustMs,
        'manualExhaustMs': manualExhaustMs,
        'pauseMs': pauseMs,
      };

  String toFormBody() =>
      toJson().entries.map((entry) => '${entry.key}=${entry.value}').join('&');

  TimingSettings copyWith({
    int? startupCooldownMs,
    int? leaveConfirmMs,
    int? autoExhaustMs,
    int? manualExhaustMs,
    int? pauseMs,
  }) =>
      TimingSettings(
        startupCooldownMs: startupCooldownMs ?? this.startupCooldownMs,
        leaveConfirmMs: leaveConfirmMs ?? this.leaveConfirmMs,
        autoExhaustMs: autoExhaustMs ?? this.autoExhaustMs,
        manualExhaustMs: manualExhaustMs ?? this.manualExhaustMs,
        pauseMs: pauseMs ?? this.pauseMs,
      );
}

class DeviceStatus {
  const DeviceStatus({
    required this.fan,
    required this.pir,
    required this.mode,
    required this.phase,
    required this.activeProfile,
    required this.viewProfile,
    required this.fanRunMs,
    required this.remainingMs,
    required this.durationMs,
    required this.phaseDurationMs,
    required this.startupCooldownMs,
    required this.leaveConfirmMs,
    required this.autoExhaustMs,
    required this.manualExhaustMs,
    required this.pauseMs,
    required this.firmware,
    this.minimumAppVersion,
    this.capabilities = const {},
    this.gattVersion,
  });

  final bool fan;
  final bool pir;
  final String mode;
  final String phase;
  final TimingProfile activeProfile;
  final TimingProfile viewProfile;
  final int fanRunMs;
  final int remainingMs;
  final int durationMs;
  final int phaseDurationMs;
  final int startupCooldownMs;
  final int leaveConfirmMs;
  final int autoExhaustMs;
  final int manualExhaustMs;
  final int pauseMs;
  final String firmware;
  final String? minimumAppVersion;
  final Set<String> capabilities;
  final int? gattVersion;

  DeviceStatus copyWith({
    bool? fan,
    bool? pir,
    String? mode,
    String? phase,
    TimingProfile? activeProfile,
    TimingProfile? viewProfile,
    int? fanRunMs,
    int? remainingMs,
    int? durationMs,
    int? phaseDurationMs,
    int? startupCooldownMs,
    int? leaveConfirmMs,
    int? autoExhaustMs,
    int? manualExhaustMs,
    int? pauseMs,
    String? firmware,
    String? minimumAppVersion,
    Set<String>? capabilities,
    int? gattVersion,
  }) =>
      DeviceStatus(
        fan: fan ?? this.fan,
        pir: pir ?? this.pir,
        mode: mode ?? this.mode,
        phase: phase ?? this.phase,
        activeProfile: activeProfile ?? this.activeProfile,
        viewProfile: viewProfile ?? this.viewProfile,
        fanRunMs: fanRunMs ?? this.fanRunMs,
        remainingMs: remainingMs ?? this.remainingMs,
        durationMs: durationMs ?? this.durationMs,
        phaseDurationMs: phaseDurationMs ?? this.phaseDurationMs,
        startupCooldownMs: startupCooldownMs ?? this.startupCooldownMs,
        leaveConfirmMs: leaveConfirmMs ?? this.leaveConfirmMs,
        autoExhaustMs: autoExhaustMs ?? this.autoExhaustMs,
        manualExhaustMs: manualExhaustMs ?? this.manualExhaustMs,
        pauseMs: pauseMs ?? this.pauseMs,
        firmware: firmware ?? this.firmware,
        minimumAppVersion: minimumAppVersion ?? this.minimumAppVersion,
        capabilities: capabilities ?? this.capabilities,
        gattVersion: gattVersion ?? this.gattVersion,
      );

  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    final mode = _requiredString(json, 'mode');
    const modes = {'auto', 'timed_on', 'timed_off', 'force_test', 'lock_off'};
    if (!modes.contains(mode)) {
      throw FormatException('设备状态字段 mode 值无效：$mode');
    }

    final phase = _requiredString(json, 'phase');
    const phases = {
      'startup_cooldown',
      'occupied',
      'clear_confirm',
      'exhausting',
      'armed',
    };
    if (!phases.contains(phase)) {
      throw FormatException('设备状态字段 phase 值无效：$phase');
    }

    final firmware = json['firmware'];
    if (firmware != null && firmware is! String) {
      throw const FormatException('设备状态字段 firmware 类型无效');
    }
    final minimumAppVersion = json['minimumAppVersion'];
    if (minimumAppVersion != null && minimumAppVersion is! String) {
      throw const FormatException('设备状态字段 minimumAppVersion 类型无效');
    }
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities != null &&
        (rawCapabilities is! List ||
            rawCapabilities.any((item) => item is! String))) {
      throw const FormatException('设备状态字段 capabilities 类型无效');
    }
    final gattVersion = json['gattVersion'];
    if (gattVersion != null &&
        (gattVersion is! int || gattVersion < 0 || gattVersion > 255)) {
      throw const FormatException('设备状态字段 gattVersion 超出范围');
    }

    return DeviceStatus(
      fan: _requiredBool(json, 'fan'),
      pir: _requiredBool(json, 'pir'),
      mode: mode,
      phase: phase,
      activeProfile: _requiredProfile(json, 'activeProfile'),
      viewProfile: _requiredProfile(json, 'viewProfile'),
      fanRunMs: _requiredUnsignedInt(json, 'fanRunMs'),
      remainingMs: _requiredUnsignedInt(json, 'remainingMs'),
      durationMs: _requiredUnsignedInt(json, 'durationMs'),
      phaseDurationMs: _requiredUnsignedInt(json, 'phaseDurationMs'),
      startupCooldownMs: _requiredDuration(json, 'startupCooldownMs'),
      leaveConfirmMs: _requiredDuration(
        json,
        'leaveConfirmMs',
        allowZero: true,
      ),
      autoExhaustMs: _requiredDuration(json, 'autoExhaustMs'),
      manualExhaustMs: _requiredDuration(json, 'manualExhaustMs'),
      pauseMs: _requiredDuration(json, 'pauseMs'),
      // 兼容不返回固件版本号的旧固件；其他控制字段不做默认值回退。
      firmware: firmware as String? ?? '—',
      minimumAppVersion: minimumAppVersion as String?,
      capabilities: rawCapabilities == null
          ? const {}
          : Set<String>.unmodifiable(rawCapabilities.cast<String>()),
      gattVersion: gattVersion as int?,
    );
  }
}

const _allowedDurationsMs = {
  0,
  5000,
  10000,
  20000,
  30000,
  60000,
  120000,
  180000,
  300000,
  600000,
};

int _requiredDuration(
  Map<String, dynamic> json,
  String key, {
  bool allowZero = false,
}) {
  final value = _requiredUnsignedInt(json, key);
  if (!_allowedDurationsMs.contains(value) || (value == 0 && !allowZero)) {
    throw FormatException('设备时长字段 $key 超出固件允许选项：$value');
  }
  return value;
}

int _requiredUnsignedInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0 || value > 0xFFFFFFFF) {
    throw FormatException('设备状态字段 $key 缺失或无效');
  }
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('设备状态字段 $key 缺失或无效');
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('设备状态字段 $key 缺失或无效');
  }
  return value;
}

TimingProfile _requiredProfile(Map<String, dynamic> json, String key) {
  switch (_requiredString(json, key)) {
    case 'dev':
      return TimingProfile.dev;
    case 'production':
      return TimingProfile.production;
    default:
      throw FormatException('设备状态字段 $key 环境值无效');
  }
}

Map<String, dynamic> decodeJsonObject(String source) {
  final value = jsonDecode(source);
  if (value is! Map<String, dynamic>) throw const FormatException('设备响应格式无效');
  return value;
}
