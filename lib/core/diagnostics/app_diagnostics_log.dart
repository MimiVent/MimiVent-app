import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MimiVentDiagnosticLevel { info, warning, error }

class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
  });

  final DateTime timestamp;
  final MimiVentDiagnosticLevel level;
  final String category;
  final String message;

  Map<String, Object> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'level': level.name,
        'category': category,
        'message': message,
      };

  factory DiagnosticLogEntry.fromJson(Map<String, dynamic> json) {
    final levelName = json['level']?.toString();
    return DiagnosticLogEntry(
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      level: MimiVentDiagnosticLevel.values.firstWhere(
        (level) => level.name == levelName,
        orElse: () => MimiVentDiagnosticLevel.info,
      ),
      category: json['category']?.toString() ?? '应用',
      message: json['message']?.toString() ?? '',
    );
  }
}

/// App 级本地诊断记录；只保存有限条目，过滤设备地址，不记录 Wi-Fi 凭证。
class AppDiagnosticsLog extends ChangeNotifier {
  static const _storageKey = 'mimivent.diagnostics.entries.v1';
  static const maxEntries = 300;
  static const maxMessageLength = 2000;
  static const statusCaptureDuration = Duration(minutes: 5);
  static const _minimumPersistInterval = Duration(seconds: 5);

  final List<DiagnosticLogEntry> _entries = [];
  SharedPreferences? _preferences;
  Future<void>? _initializeFuture;
  Future<void> _writeQueue = Future<void>.value();
  Timer? _persistDebounce;
  Timer? _statusCaptureTimer;
  DateTime? _statusCaptureUntil;
  DateTime? _lastPersistAt;

  List<DiagnosticLogEntry> get entries => List.unmodifiable(_entries);
  bool get isCapturingStatusPolls =>
      _statusCaptureUntil?.isAfter(DateTime.now()) ?? false;

  /// 为短时排障开启完整状态轮询收发记录，五分钟后自动关闭。
  void startStatusPollCapture() {
    _statusCaptureTimer?.cancel();
    _statusCaptureUntil = DateTime.now().add(statusCaptureDuration);
    _statusCaptureTimer = Timer(statusCaptureDuration, () {
      _statusCaptureUntil = null;
      _statusCaptureTimer = null;
      info('诊断抓取', '状态轮询原始抓取已自动结束');
    });
    info('诊断抓取', '已开启状态轮询原始抓取，五分钟后自动结束');
  }

  void stopStatusPollCapture() {
    if (!isCapturingStatusPolls) return;
    _statusCaptureTimer?.cancel();
    _statusCaptureTimer = null;
    _statusCaptureUntil = null;
    info('诊断抓取', '已手动结束状态轮询原始抓取');
  }

  Future<void> initialize() => _initializeFuture ??= _loadFromStorage();

  Future<void> _loadFromStorage() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      final raw = _preferences?.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is Map<String, dynamic>) {
              _entries.add(DiagnosticLogEntry.fromJson(value));
            } else if (value is Map) {
              _entries.add(DiagnosticLogEntry.fromJson(
                value.map((key, item) => MapEntry(key.toString(), item)),
              ));
            }
          }
          if (_entries.length > maxEntries) {
            _entries.removeRange(maxEntries, _entries.length);
          }
        }
      }
    } catch (_) {
      // 日志读取失败不能阻断 App 启动；下一条新记录仍会尝试重新取得存储实例。
      _entries.clear();
    }
    notifyListeners();
  }

  void info(String category, String message) =>
      record(MimiVentDiagnosticLevel.info, category, message);

  void warning(String category, String message) =>
      record(MimiVentDiagnosticLevel.warning, category, message);

  void error(String category, String message) =>
      record(MimiVentDiagnosticLevel.error, category, message);

  void record(MimiVentDiagnosticLevel level, String category, String message) {
    final entry = DiagnosticLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: _sanitize(category),
      message: _sanitize(message),
    );
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    _persistSnapshot();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _persistImmediately();
  }

  String exportText() => _entries
      .map((entry) =>
          '${_formatTimestamp(entry.timestamp)} [${entry.level.name.toUpperCase()}] '
          '[${entry.category}]\n${entry.message}')
      .join('\n\n');

  void _persistSnapshot() {
    if (_persistDebounce?.isActive ?? false) return;
    final now = DateTime.now();
    final elapsed = _lastPersistAt == null
        ? _minimumPersistInterval
        : now.difference(_lastPersistAt!);
    final throttleWait = elapsed >= _minimumPersistInterval
        ? Duration.zero
        : _minimumPersistInterval - elapsed;
    final delay = throttleWait > const Duration(milliseconds: 500)
        ? throttleWait
        : const Duration(milliseconds: 500);
    _persistDebounce = Timer(delay, () {
      _persistDebounce = null;
      unawaited(_enqueueSnapshot());
    });
  }

  Future<void> _persistImmediately() {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    return _enqueueSnapshot();
  }

  Future<void> _enqueueSnapshot() {
    final snapshot =
        jsonEncode(_entries.map((entry) => entry.toJson()).toList());
    _lastPersistAt = DateTime.now();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await initialize();
        final preferences =
            _preferences ?? await SharedPreferences.getInstance();
        _preferences = preferences;
        await preferences.setString(_storageKey, snapshot);
      } catch (_) {
        // 日志属于诊断辅助功能，存储异常不能影响设备控制。
      }
    });
    return _writeQueue;
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    _statusCaptureTimer?.cancel();
    unawaited(_persistImmediately());
    super.dispose();
  }

  String _sanitize(String value) {
    final withoutAddresses = value.replaceAll(
      RegExp(r'\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b'),
      '**:**:**:**:**:**',
    );
    if (withoutAddresses.length <= maxMessageLength) return withoutAddresses;
    return '${withoutAddresses.substring(0, maxMessageLength)}…';
  }

  static String _formatTimestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    final milliseconds = value.millisecond.toString().padLeft(3, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.$milliseconds';
  }
}
