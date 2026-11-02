import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
  static const maxFileBytes = 1024 * 1024;
  static const maxLogFiles = 10;
  static const statusCaptureDuration = Duration(minutes: 5);
  static const _minimumPersistInterval = Duration(seconds: 5);

  final List<DiagnosticLogEntry> _entries = [];
  SharedPreferences? _preferences;
  Future<void>? _initializeFuture;
  Future<void> _writeQueue = Future<void>.value();
  Future<void> _fileWriteQueue = Future<void>.value();
  Future<void>? _prepareFilesFuture;
  Directory? _fileLogDirectory;
  File? _activeLogFile;
  String? _activeLogDay;
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

  /// Android 日志保存在应用专属外部目录，可通过 ADB 直接读取，无需打开日志页。
  String? get fileLogDirectoryPath => _fileLogDirectory?.path;

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
    await (_prepareFilesFuture ??= _prepareLogFiles());
    notifyListeners();
  }

  void info(String category, String message) =>
      record(MimiVentDiagnosticLevel.info, category, message);

  void warning(String category, String message) =>
      record(MimiVentDiagnosticLevel.warning, category, message);

  void error(String category, String message, {StackTrace? stackTrace}) =>
      record(
        MimiVentDiagnosticLevel.error,
        category,
        stackTrace == null ? message : '$message\n$stackTrace',
      );

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
    unawaited(_appendFileEntry(entry));
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _persistImmediately();
    await _fileWriteQueue;
    await _clearFileLogs();
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

  Future<void> _appendFileEntry(DiagnosticLogEntry entry) {
    _fileWriteQueue = _fileWriteQueue.then((_) async {
      try {
        await (_prepareFilesFuture ??= _prepareLogFiles());
        final directory = _fileLogDirectory;
        if (directory == null) return;

        final now = DateTime.now();
        final day = '${now.year.toString().padLeft(4, '0')}'
            '${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}';
        final line = jsonEncode({
              'occurredAt': _timestampWithOffset(entry.timestamp),
              'writtenAt': _timestampWithOffset(now),
              'level': entry.level.name,
              'category': entry.category,
              'message': entry.message,
            }) +
            '\n';
        final byteLength = utf8.encode(line).length;
        var active = _activeLogFile;
        final currentLength =
            active != null && await active.exists() ? await active.length() : 0;
        if (active == null ||
            day != _activeLogDay ||
            currentLength + byteLength > maxFileBytes) {
          active = await _createLogFile(directory, now);
          _activeLogFile = active;
          _activeLogDay = day;
        }
        await active.writeAsString(
          line,
          mode: FileMode.append,
          encoding: utf8,
          flush: entry.level == MimiVentDiagnosticLevel.error,
        );
        await _pruneLogFiles(directory);
      } catch (error) {
        // 磁盘写入失败不能影响控制流程；错误保留在 Android logcat 供诊断。
        debugPrint('[MimiVent file log] 写入失败: $error');
      }
    });
    return _fileWriteQueue;
  }

  Future<void> _prepareLogFiles() async {
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
      final directory = Directory('${base.path}/MimiVent/logs');
      await directory.create(recursive: true);
      _fileLogDirectory = directory;
      final files = await _listLogFiles(directory);
      if (files.isNotEmpty) {
        final newest = files.last;
        final stat = await newest.stat();
        final now = DateTime.now();
        final day = '${now.year.toString().padLeft(4, '0')}'
            '${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}';
        final modified = stat.modified;
        final modifiedDay = '${modified.year.toString().padLeft(4, '0')}'
            '${modified.month.toString().padLeft(2, '0')}'
            '${modified.day.toString().padLeft(2, '0')}';
        if (stat.size < maxFileBytes && modifiedDay == day) {
          _activeLogFile = newest;
          _activeLogDay = day;
        }
      }
      await _pruneLogFiles(directory);
    } catch (error) {
      debugPrint('[MimiVent file log] 初始化失败: $error');
    }
  }

  Future<File> _createLogFile(Directory directory, DateTime now) async {
    final stamp = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}-'
        '${now.microsecondsSinceEpoch}';
    final file = File('${directory.path}/mimivent-$stamp.jsonl');
    await file.create(exclusive: true);
    return file;
  }

  Future<List<File>> _listLogFiles(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('mimivent-') &&
          entity.path.endsWith('.jsonl')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<void> _pruneLogFiles(Directory directory) async {
    final files = await _listLogFiles(directory);
    final excess = files.length - maxLogFiles;
    for (var index = 0; index < excess; index++) {
      await files[index].delete();
      if (identical(files[index], _activeLogFile)) {
        _activeLogFile = null;
        _activeLogDay = null;
      }
    }
  }

  Future<void> _clearFileLogs() async {
    try {
      await (_prepareFilesFuture ??= _prepareLogFiles());
      final directory = _fileLogDirectory;
      if (directory == null) return;
      for (final file in await _listLogFiles(directory)) {
        await file.delete();
      }
      _activeLogFile = null;
      _activeLogDay = null;
    } catch (_) {
      // 清理失败不影响 App 主流程。
    }
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

  static String _timestampWithOffset(DateTime value) {
    final local = value.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${local.toIso8601String()}$sign$hours:$minutes';
  }
}
