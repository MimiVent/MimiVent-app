import 'dart:convert';

enum TimingProfile { production, dev }

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
