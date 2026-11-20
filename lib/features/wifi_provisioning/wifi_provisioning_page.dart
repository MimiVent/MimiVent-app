import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ble/mimivent_ble_manager.dart';
import '../../shared/widgets/top_toast.dart';
import '../local_network/nas_gateway_transport.dart';
import '../local_network/wifi_binding.dart';
import '../local_network/wifi_binding_controller.dart';
import '../local_network/wifi_binding_store.dart';
import '../local_network/wifi_binding_and_nas_page.dart';
import 'wifi_credentials.dart';
import 'wifi_network_picker.dart';

class WifiProvisioningPage extends StatefulWidget {
  const WifiProvisioningPage({required this.ble, super.key});
  final MimiVentBleManager ble;

  @override
  State<WifiProvisioningPage> createState() => _WifiProvisioningPageState();
}

class _WifiProvisioningPageState extends State<WifiProvisioningPage> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _pickerOpen = false;
  final _random = Random.secure();
  WifiScanSnapshot? _lastSnapshot;
  Future<WifiScanSnapshot>? _scanFuture;
  String _state = 'loading';
  DateTime? _lastScanAt;
  static const _wifiScan = MethodChannel('mimivent/wifi_scan');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  String? _ip;
  String? _connectedSsid;
  String? _error;
  bool _busy = false;
  bool _hidePassword = true;
  String? _bindingNotice;
  bool _bindingFailed = false;
  bool _bindingActive = false;
  bool _nasMqttReady = false;

  Future<String> _clientId() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'mimivent.wifi.client_id.v1';
    final old = prefs.getString(key);
    if (old != null && old.isNotEmpty) return old;
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final value =
        'c-' + bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(key, value);
    return value;
  }

  String _requestId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return hex.substring(0, 8) +
        '-' +
        hex.substring(8, 12) +
        '-' +
        hex.substring(12, 16) +
        '-' +
        hex.substring(16, 20) +
        '-' +
        hex.substring(20);
  }

  Future<Map<String, dynamic>> _request(String op,
      {Map<String, dynamic> payload = const {},
      String? requestId,
      Map<String, dynamic> extra = const {}}) async {
    final response = await widget.ble.requestWifi({
      'clientId': await _clientId(),
      'op': op,
      ...extra,
      if (requestId != null) 'requestId': requestId,
      if (payload.isNotEmpty) 'payload': payload,
    });
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('设备返回的 WiFi 响应无效');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        (value.containsKey('error') &&
            !(op == 'wifi.status' && value['state'] is String))) {
      throw StateError(value['error']?.toString() ?? '请求失败');
    }
    return value;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (_state == 'loading') _state = 'unknown';
      if (mounted)
        setState(() => _error = error is PlatformException
            ? error.message ?? '操作未完成'
            : error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<WifiScanSnapshot> _scan() =>
      _scanFuture ??= _scanPhone().whenComplete(() => _scanFuture = null);

  Future<WifiScanSnapshot> _scanPhone() async {
    if (!Platform.isAndroid) {
      throw StateError('当前平台请手动输入 SSID');
    }
    final previous = _lastScanAt;
    if (previous != null &&
        DateTime.now().difference(previous).inSeconds < 30) {
      throw StateError('请稍后再搜索，避免系统限制扫描频率；也可以手动输入 SSID');
    }
    final permission = await Permission.locationWhenInUse.request();
    if (!mounted) throw StateError('配网页面已关闭');
    if (!permission.isGranted) {
      throw StateError('搜索 WiFi 需要精确位置权限，请在系统设置授权；也可以手动输入 SSID');
    }
    _lastScanAt = DateTime.now();
    widget.ble.diagnostics?.info('手机 WiFi 扫描', '开始搜索手机附近的 2.4 GHz 网络');
    final result = await _wifiScan.invokeMapMethod<String, dynamic>('scan');
    if (!mounted) throw StateError('配网页面已关闭');
    final values = result?['networks'];
    if (values is! List) throw StateError('手机返回的 WiFi 列表无效');
    final snapshot = WifiScanSnapshot(
      networks: values
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList(),
      cached: result?['cached'] == true,
    );
    _lastSnapshot = snapshot;
    return snapshot;
  }

  Future<void> _selectNetwork() async {
    if (_busy || _pickerOpen) return;
    _pickerOpen = true;
    FocusScope.of(context).unfocus();
    try {
      final ssid = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => WifiNetworkPicker(
          scan: _scan,
          selectedSsid: _ssid.text,
          initialSnapshot: _lastSnapshot,
        ),
      );
      if (!mounted || ssid == null) return;
      setState(() {
        if (_ssid.text != ssid) _password.clear();
        _ssid.text = ssid;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passwordFocus.requestFocus();
      });
    } finally {
      _pickerOpen = false;
    }
  }

  Future<void> _configure() => _run(() async {
        setState(() {
          _bindingNotice = null;
          _bindingFailed = false;
          _bindingActive = false;
          _nasMqttReady = false;
        });
        final ssid = _ssid.text;
        final password = _password.text;
        if (!isValidWifiSsid(ssid) || !isValidWifiPassword(password)) {
          throw StateError(
              'SSID 需为 1–32 个 UTF-8 字节；密码需为 8–63 位 ASCII 或 64 位十六进制');
        }
        final start = await _request('wifi.configure',
            requestId: _requestId(),
            payload: {'ssid': ssid, 'password': password});
        if (!mounted) return;
        setState(() => _state = start['state']?.toString() ?? 'connecting');
        for (var i = 0; i < 90; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          final status = await _request('wifi.status');
          if (!mounted) return;
          final current = status['state']?.toString() ?? '';
          if (current == 'connected') {
            setState(() {
              _state = current;
              _ip = status['ip']?.toString();
              _connectedSsid = status['ssid']?.toString();
              _password.clear();
            });
            await _bindAfterProvisioning(status);
            return;
          }
          if (current == 'failed' || current == 'interrupted') {
            throw StateError(status['error']?.toString() ?? '连接失败');
          }
        }
        throw StateError('连接结果待确认，请刷新设备状态');
      });

  Future<WifiBinding?> _activeBinding(String? deviceId) async {
    if (deviceId == null || deviceId.isEmpty) return null;
    try {
      final records = await WifiBindingStore().load();
      for (final binding in records) {
        if (binding.deviceId == deviceId && binding.state == 'active') {
          return binding;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<bool> _checkNasMqttState(WifiBinding binding) async {
    final gateway = NasGatewayTransport();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    try {
      while (mounted && DateTime.now().isBefore(deadline)) {
        if (!mounted) return false;
        final result = await gateway.tryReadState(binding);
        final body = result?.body;
        if (result?.statusCode == 200 &&
            body?['deviceId'] == binding.deviceId &&
            // P2：Gateway 返回手机实例标识 appInstanceId。
            body?['appInstanceId'] == binding.tokenId &&
            body?['bindingState'] == 'active' &&
            body?['stale'] == false &&
            body?['stateFreshness'] == 'fresh') {
          final fanRunning = body?['fan'] == true;
          if (mounted) {
            setState(() {
              _nasMqttReady = true;
              _bindingNotice =
                  '配网成功，NAS MQTT 已连接；已自动读取设备状态：风机${fanRunning ? '运行中' : '已停止'}。';
            });
            TopToast.show(context, 'NAS MQTT 配网成功，设备状态已自动更新');
          }
          return true;
        }
        if (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
      }
      if (mounted) {
        setState(() {
          _nasMqttReady = false;
          _bindingNotice =
              'WiFi 配网和手机绑定已成功，但 NAS 尚未收到设备实时 MQTT 状态。请确认设备已连接 Broker，再点“检查 NAS MQTT 状态”。';
        });
      }
      return false;
    } finally {
      gateway.dispose();
    }
  }

  /// 配网只负责让设备联网；NAS MQTT 控制还需要本机授权绑定。
  /// 配网成功后自动完成一次绑定，避免出现“WiFi 已连接但 App 没有绑定”。
  Future<bool> _bindAfterProvisioning(Map<String, dynamic> status) async {
    final deviceId = status['deviceId']?.toString();
    final existingBinding = await _activeBinding(deviceId);
    if (existingBinding != null) {
      if (mounted) {
        setState(() {
          _bindingNotice = 'WiFi 已连接，本机绑定有效，正在检查 NAS MQTT 状态…';
          _bindingFailed = false;
          _bindingActive = true;
          _nasMqttReady = false;
        });
      }
      await _checkNasMqttState(existingBinding);
      return true;
    }
    String? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      final controller = WifiBindingController(widget.ble);
      try {
        await controller.bind();
        if (controller.error == null &&
            controller.selected?.state == 'active') {
          final binding = controller.selected!;
          if (mounted) {
            setState(() {
              _bindingNotice = 'WiFi 配网和本机绑定成功，正在检查 NAS MQTT 状态…';
              _bindingFailed = false;
              _bindingActive = true;
              _nasMqttReady = false;
            });
          }
          await _checkNasMqttState(binding);
          return true;
        }
        lastError = controller.error;
      } catch (error) {
        lastError = error.toString();
      } finally {
        controller.dispose();
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (mounted) {
      setState(() {
        _bindingNotice = 'WiFi 已连接，但本机绑定失败：${lastError ?? '未知错误'}';
        _bindingFailed = true;
        _bindingActive = false;
        _nasMqttReady = false;
      });
    }
    return false;
  }

  Future<void> _openBindingManager() async {
    final switchToMqtt = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WifiBindingAndNasPage(ble: widget.ble)),
    );
    if (!mounted) return;
    if (switchToMqtt == true) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _bindingNotice = null;
      _bindingFailed = false;
      _bindingActive = false;
      _nasMqttReady = false;
    });
    await _refresh();
  }

  Future<void> _refresh() => _run(() async {
        final result = await _request('wifi.status');
        if (!mounted) return;
        setState(() {
          _state = result['state']?.toString() ?? 'unknown';
          _ip = result['ip']?.toString();
          _connectedSsid = result['ssid']?.toString();
          _error = result['error']?.toString();
        });
      });

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _state == 'connected';
    return Scaffold(
      appBar: AppBar(title: const Text('WiFi 配网')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: Icon(connected ? Icons.wifi : Icons.wifi_off),
              title: Text(const {
                    'loading': '正在读取设备状态…',
                    'unknown': '设备状态未知，请刷新重试',
                    'unconfigured': '尚未配置 WiFi',
                    'connected': '设备当前网络 · 已连接',
                    'connecting': '正在连接 WiFi',
                    'failed': 'WiFi 连接失败',
                    'interrupted': '配网已中断',
                    'disconnected': 'WiFi 已断开',
                  }[_state] ??
                  '设备状态：$_state'),
              subtitle: Text(connected
                  ? '${_connectedSsid ?? ''}\nIP：${_ip ?? '—'}'
                  : '配网时请确认系统蓝牙配对弹窗。'),
              trailing: IconButton(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('配置网络', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              enabled: !_busy,
              leading: Icon(_ssid.text.isEmpty ? Icons.wifi_find : Icons.wifi),
              title: Text(_ssid.text.isEmpty ? '选择 WiFi 网络' : _ssid.text),
              subtitle: Text(
                  _ssid.text.isEmpty ? '搜索 2.4 GHz 网络，或手动输入' : '已选择 · 点击更换网络'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : _selectNetwork,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _password,
            focusNode: _passwordFocus,
            enabled: !_busy && _ssid.text.isNotEmpty,
            onChanged: (_) => setState(() {}),
            obscureText: _hidePassword,
            decoration: InputDecoration(
              labelText: 'WiFi 密码',
              helperText: '选择网络后，输入密码并点击下方按钮连接设备。',
              suffixIcon: IconButton(
                onPressed: () => setState(() => _hidePassword = !_hidePassword),
                icon: Icon(
                    _hidePassword ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _ssid.text.isEmpty || _password.text.isEmpty
                ? null
                : _configure,
            child: Text(_busy ? '正在处理…' : '连接此网络'),
          ),
          if (_state == 'connected' && !_bindingActive) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        final status = await _request('wifi.status');
                        await _bindAfterProvisioning(status);
                      }),
              child: const Text('绑定此手机以启用 NAS MQTT 控制'),
            ),
          ],
          if (_state == 'connected' && _bindingActive && !_nasMqttReady)
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        final binding =
                            await _activeBinding(widget.ble.connectedDeviceId);
                        if (binding == null) {
                          throw StateError('未找到本机有效绑定，请重新绑定此手机');
                        }
                        setState(() => _bindingNotice = '正在检查 NAS MQTT 状态…');
                        await _checkNasMqttState(binding);
                      }),
              icon: const Icon(Icons.sync),
              label: const Text('检查 NAS MQTT 状态'),
            ),
          if (_bindingNotice != null) ...[
            const SizedBox(height: 12),
            Text(
              _bindingNotice!,
              style: TextStyle(
                color: _bindingFailed
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
          if (_state == 'connected' && _bindingFailed)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        final status = await _request('wifi.status');
                        await _bindAfterProvisioning(status);
                      }),
              child: const Text('重试本机绑定'),
            ),
          if (_state == 'connected')
            TextButton(
              onPressed: _busy ? null : _openBindingManager,
              child: const Text('WiFi 配网与 NAS MQTT 设置'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
