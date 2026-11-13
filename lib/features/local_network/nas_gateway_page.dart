import 'dart:math';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_connection_manager.dart';
import '../connection/connection_status_badge.dart';
import 'nas_gateway_transport.dart';
import 'nas_gateway_startup_probe.dart';
import 'nas_gateway_models.dart';

final NasGatewayTransport _readOnlyGateway = NasGatewayTransport();

class NasGatewayPage extends StatefulWidget {
  const NasGatewayPage({
    required this.initial,
    required this.onConnectBluetooth,
    required this.onOpenNetworkSettings,
    required this.onRefresh,
    required this.connection,
    super.key,
  });

  final NasGatewaySnapshot initial;
  final Future<void> Function() onConnectBluetooth;
  final Future<void> Function() onOpenNetworkSettings;
  final Future<NasGatewaySnapshot?> Function() onRefresh;
  final DeviceConnectionManager connection;

  @override
  State<NasGatewayPage> createState() => _NasGatewayPageState();
}

class _NasGatewayPageState extends State<NasGatewayPage> {
  late NasGatewaySnapshot _snapshot = widget.initial;
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
        setState(() => _error = 'NAS 状态暂不可达，请确认手机与 NAS 在同一局域网');
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
      final result = await _readOnlyGateway.tryWrite(
        _snapshot.binding,
        path: path,
        body: body,
        requestId: id,
      );
      if (result == null) {
        throw const NasGatewayException(
            'GATEWAY_UNAVAILABLE', 'NAS 网关不可达，请连接蓝牙操作');
      }
      if (result.statusCode != 200) {
        final code =
            result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
        throw NasGatewayException(code, _controlError(code));
      }
      if (mounted) {
        setState(() => _writeNotice =
            result.body['duplicate'] == true ? '设备确认这是重复请求，未重复执行' : '设备已执行');
      }
      final next = await widget.onRefresh();
      if (!mounted) return;
      if (next != null) setState(() => _snapshot = next);
    } on NasGatewayException catch (e) {
      if (mounted) setState(() => _writeError = e.message);
    } catch (_) {
      if (mounted) setState(() => _writeError = '操作未完成，请检查 NAS 连接后重试');
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
      '设备未完成 NAS MQTT 控制（$code）';

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
                      Icon(Icons.cloud_sync_outlined, color: Color(0xFF6FE3C1)),
                      SizedBox(width: 8),
                      Text('NAS MQTT 状态快照',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('设备：$shortDevice',
                      style: const TextStyle(color: Colors.white70)),
                  // 设备 HTTPS 已下线，host 只作历史遗留展示；为空时不再显示这一行。
                  if (_snapshot.binding.host.isNotEmpty)
                    Text('设备局域网地址（历史）：${_snapshot.binding.host}',
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
            label: Text(_refreshing ? '正在刷新…' : '刷新 NAS 状态'),
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
            onPressed: widget.onOpenNetworkSettings,
            icon: const Icon(Icons.wifi),
            label: const Text('WiFi 配网与 NAS 设置'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.onConnectBluetooth,
            icon: const Icon(Icons.bluetooth),
            label: const Text('连接蓝牙以控制'),
          ),
          const SizedBox(height: 18),
          const Text(
            '主页控制使用当前选定通道（NAS MQTT 或蓝牙）；固件升级仍通过蓝牙完成。',
            style: TextStyle(color: Colors.white54, height: 1.45),
          ),
        ],
      ),
    );
  }
}
