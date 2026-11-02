import 'dart:math';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_connection_manager.dart';
import '../connection/connection_status_badge.dart';
import 'wifi_read_transport.dart';
import 'wifi_startup_probe.dart';

class WifiReadOnlyPage extends StatefulWidget {
  const WifiReadOnlyPage({
    required this.initial,
    required this.onConnectBluetooth,
    required this.onOpenWifiControl,
    required this.onRefresh,
    required this.connection,
    super.key,
  });

  final WifiStartupSnapshot initial;
  final Future<void> Function() onConnectBluetooth;
  final Future<void> Function() onOpenWifiControl;
  final Future<WifiStartupSnapshot?> Function() onRefresh;
  final DeviceConnectionManager connection;

  @override
  State<WifiReadOnlyPage> createState() => _WifiReadOnlyPageState();
}

class _WifiReadOnlyPageState extends State<WifiReadOnlyPage> {
  late WifiStartupSnapshot _snapshot = widget.initial;
  bool _refreshing = false;
  bool _writing = false;
  String? _error;
  String? _writeError;
  String? _lastId;
  String? _lastPath;
  String? _lastBody;
  String? _writeNotice;
  static const _lastRequestKey = 'mimivent.wifi.last_request.v1';

  @override
  void initState() {
    super.initState();
    _loadLastRequest();
  }

  Future<void> _loadLastRequest() async {
    try {
      final raw =
          (await SharedPreferences.getInstance()).getString(_lastRequestKey);
      if (raw == null) return;
      final value = jsonDecode(raw);
      if (value is! Map) return;
      final id = value['id']?.toString();
      final path = value['path']?.toString();
      final body = value['body']?.toString();
      if (id == null || path == null || body == null) return;
      if (!mounted) return;
      setState(() {
        _lastId = id;
        _lastPath = path;
        _lastBody = body;
      });
    } catch (_) {
      // 不因旧的测试记录阻止页面启动。
    }
  }

  Future<void> _remember(String id, String path, String body) async {
    _lastId = id;
    _lastPath = path;
    _lastBody = body;
    try {
      await (await SharedPreferences.getInstance()).setString(
          _lastRequestKey, jsonEncode({'id': id, 'path': path, 'body': body}));
    } catch (_) {}
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final next = await widget.onRefresh();
      if (!mounted) return;
      if (next == null) {
        setState(() => _error = 'WiFi 暂不可达，请确认手机与设备在同一局域网');
      } else {
        setState(() => _snapshot = next);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _requestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _send(String path, String body, {String? requestId}) async {
    if (_writing) return;
    final id = requestId ?? _requestId();
    await _remember(id, path, body);
    setState(() {
      _writing = true;
      _writeError = null;
      _writeNotice = null;
    });
    try {
      final result = await WifiReadTransport().write(
        _snapshot.binding,
        path: path,
        body: body,
        requestId: id,
      );
      if (result.statusCode != 200) {
        final code =
            result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
        throw WifiReadException(code, _controlError(code));
      }
      if (mounted) {
        setState(() => _writeNotice =
            result.body['duplicate'] == true ? '设备确认这是重复请求，未重复执行' : '设备已执行');
      }
      final next = await widget.onRefresh();
      if (!mounted) return;
      if (next != null) setState(() => _snapshot = next);
    } on WifiReadException catch (e) {
      if (mounted) setState(() => _writeError = e.message);
    } catch (_) {
      if (mounted) setState(() => _writeError = '操作未完成，请检查 WiFi 后重试');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  String _controlError(String code) =>
      const {
        'PROFILE_MISMATCH': '设备当前档位与请求不一致，请刷新状态',
        'PIR_HIGH': '检测到有人，暂时不能启动排风',
        'STARTUP_COOLDOWN': '设备正在启动保护期，请稍后再试',
        'OTA_BUSY': '设备正在升级，暂时不能控制',
        'REQUEST_ID_CONFLICT': '请求标识冲突，请重试',
        'RATE_LIMITED': '操作过于频繁，请稍后重试',
      }[code] ??
      '设备未完成 WiFi 控制（$code）';

  @override
  Widget build(BuildContext context) {
    final s = _snapshot.status;
    final device = _snapshot.binding.deviceId;
    final shortDevice = device.length >= 8 ? device.substring(0, 8) : device;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1B18),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1B18),
        foregroundColor: Colors.white,
        title: const Text('MimiVent'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ConnectionStatusBadge(
              connection: widget.connection,
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('连接状态'),
                  content: Text(widget.connection.detail),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'))
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          Card(
            color: const Color(0xFF182A26),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.wifi, color: Color(0xFF6FE3C1)),
                      SizedBox(width: 8),
                      Text('WiFi 已连接 · 已核验',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('设备：$shortDevice',
                      style: const TextStyle(color: Colors.white70)),
                  Text('地址：${_snapshot.binding.host}:8443',
                      style: const TextStyle(color: Colors.white70)),
                  Text('固件：${s['firmware'] ?? '未知'}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('风机：${s['fan'] == true ? '运行' : '关闭'}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('模式：${s['mode'] ?? '未知'}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('阶段：${s['phase'] ?? '未知'}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('剩余：${s['remainingMs'] ?? '?'} ms',
                      style: const TextStyle(color: Colors.white70)),
                  Text('状态采样：${s['sampleAgeMs'] ?? '?'} ms 前',
                      style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
          ],
          if (_writeNotice != null) ...[
            const SizedBox(height: 8),
            Text(_writeNotice!,
                style: const TextStyle(color: Color(0xFF6FE3C1))),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: Text(_refreshing ? '正在刷新…' : '刷新 WiFi 状态'),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: _writing
                    ? null
                    : () => _send('/api/auto',
                        'profile=production&switchProfile=1&replace=1'),
                child: const Text('自动模式')),
            OutlinedButton(
                onPressed: _writing
                    ? null
                    : () => _send(
                        '/api/timed', 'profile=production&mode=on&replace=1'),
                child: const Text('临时排风')),
            OutlinedButton(
                onPressed: _writing
                    ? null
                    : () => _send(
                        '/api/timed', 'profile=production&mode=off&replace=1'),
                child: const Text('临时暂停')),
          ]),
          if (_writeError != null) ...[
            const SizedBox(height: 8),
            Text(_writeError!,
                style: const TextStyle(color: Color(0xFFFF8A80))),
          ],
          if (_lastId != null && _lastPath != null && _lastBody != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _writing
                  ? null
                  : () => _send(_lastPath!, _lastBody!, requestId: _lastId!),
              icon: const Icon(Icons.replay),
              label: const Text('重试上一次请求'),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.onOpenWifiControl,
            icon: const Icon(Icons.wifi),
            label: const Text('WiFi 绑定与状态'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.onConnectBluetooth,
            icon: const Icon(Icons.bluetooth),
            label: const Text('连接蓝牙以控制'),
          ),
          const SizedBox(height: 18),
          const Text(
            '当前版本 WiFi 支持只读与实验写控制；主页其它设置和固件升级仍使用蓝牙。',
            style: TextStyle(color: Colors.white54, height: 1.45),
          ),
        ],
      ),
    );
  }
}
