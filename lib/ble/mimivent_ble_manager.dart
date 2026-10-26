import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/app_identity.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import 'ble_disconnect_gate.dart';
import 'ble_request_queue.dart';
import 'ble_protocol.dart';

enum BleConnectionStatus { disconnected, scanning, connecting, connected }

/// BLE 传输适配层。界面和控制 API 不直接依赖 FlutterBluePlus。
class MimiVentBleManager extends ChangeNotifier {
  MimiVentBleManager({this.diagnostics});

  final AppDiagnosticsLog? diagnostics;
  final List<ScanResult> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _command;
  BluetoothCharacteristic? _response;
  Completer<BleResponse>? _pendingResponse;
  final List<List<int>> _responseChunks = [];
  final BleResponseDecoder _decoder = BleResponseDecoder();
  final BleRequestQueue _requestQueue = BleRequestQueue();
  int _connectionAttempt = 0;
  int _scanAttempt = 0;
  bool _disposed = false;

  BleConnectionStatus connectionStatus = BleConnectionStatus.disconnected;
  String? lastError;

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  String get connectedName => _device?.platformName.isNotEmpty == true
      ? _device!.platformName
      : BleProtocol.deviceName;
  bool get isConnected => connectionStatus == BleConnectionStatus.connected;
  bool get isScanning => connectionStatus == BleConnectionStatus.scanning;

  Future<void> scan({Duration timeout = const Duration(seconds: 12)}) async {
    // 防止页面自动扫描、手动刷新和断开后的扫描同时启动，导致旧任务覆盖新状态。
    if (isConnected ||
        isScanning ||
        connectionStatus == BleConnectionStatus.connecting) return;
    final attempt = ++_scanAttempt;
    lastError = null;
    _scanResults.clear();
    connectionStatus = BleConnectionStatus.scanning;
    diagnostics?.info('蓝牙扫描', '开始扫描 MimiVent');
    _notifyIfAlive();
    await _scanSubscription?.cancel();
    if (attempt != _scanAttempt || !isScanning) return;
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      (results) {
        if (attempt != _scanAttempt || !isScanning) return;
        for (final result in results) {
          if (!_isMimiVent(result)) continue;
          if (!_scanResults
              .any((item) => item.device.remoteId == result.device.remoteId)) {
            _scanResults.add(result);
            diagnostics?.info(
              'BLE 扫描结果',
              'name=${_deviceName(result)}, rssi=${result.rssi} dBm, '
                  'services=${result.advertisementData.serviceUuids.map((uuid) => uuid.str).join(',')}',
            );
          }
        }
        _scanResults.sort((a, b) => _deviceName(a).compareTo(_deviceName(b)));
        _notifyIfAlive();
      },
      onError: (Object error) {
        if (attempt != _scanAttempt || !isScanning) return;
        lastError = '扫描失败：$error';
        diagnostics?.error('蓝牙扫描', lastError!);
        connectionStatus = BleConnectionStatus.disconnected;
        _notifyIfAlive();
      },
    );
    try {
      if (!await FlutterBluePlus.isSupported) {
        throw Exception('此设备不支持蓝牙 LE');
      }
      await _requestAndroidPermissions();
      if (attempt != _scanAttempt || !isScanning) return;
      if (Platform.isAndroid &&
          FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
      // 不在 Android 原生层按 UUID 过滤：不同固件/手机对广播包和扫描响应的
      // 组合处理有差异，可能造成有名字的 MimiVent 被底层过滤掉。改为 App 侧识别。
      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
      if (attempt == _scanAttempt) {
        diagnostics?.info('蓝牙扫描', '扫描结束，发现 ${_scanResults.length} 台设备');
      }
    } catch (error) {
      if (attempt == _scanAttempt) {
        lastError = '无法扫描设备：$error';
        diagnostics?.error('蓝牙扫描', lastError!);
      }
    } finally {
      // 过期扫描的 finally 不能覆盖随后开始的连接或新一轮扫描状态。
      if (attempt == _scanAttempt && isScanning) {
        connectionStatus = BleConnectionStatus.disconnected;
        _notifyIfAlive();
      }
    }
  }

  Future<void> _requestAndroidPermissions() async {
    if (!Platform.isAndroid) return;
    final android = await DeviceInfoPlugin().androidInfo;
    final requiredPermissions = android.version.sdkInt >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    final permissions = await requiredPermissions.request();
    final denied =
        permissions.entries.where((entry) => !entry.value.isGranted).toList();
    if (denied.isNotEmpty) {
      throw Exception('请在系统设置中允许 ${AppIdentity.productName} 使用附近设备和蓝牙权限');
    }
  }

  String _deviceName(ScanResult result) {
    final advertised = result.advertisementData.advName.trim();
    if (advertised.isNotEmpty) return advertised;
    final platform = result.device.platformName.trim();
    return platform.isNotEmpty
        ? platform
        : '${AppIdentity.productName} (${result.device.remoteId.str})';
  }

  bool _isMimiVent(ScanResult result) {
    final serviceAdvertised = result.advertisementData.serviceUuids
        .any((uuid) => uuid.str.toLowerCase() == BleProtocol.serviceUuid);
    final name = _deviceName(result).toLowerCase();
    return serviceAdvertised || name == BleProtocol.deviceName.toLowerCase();
  }

  Future<void> connect(BluetoothDevice device) async {
    // 使当前扫描回调和 finally 失效，避免扫描结束把 connecting 改回 disconnected。
    ++_scanAttempt;
    final attempt = ++_connectionAttempt;
    _device = device;
    lastError = null;
    connectionStatus = BleConnectionStatus.connecting;
    diagnostics?.info('蓝牙连接', '正在连接 ${AppIdentity.productName}');
    _notifyIfAlive();
    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      if (attempt != _connectionAttempt) throw Exception('连接已取消');
      final disconnectGate = BleDisconnectGate();
      _connectionSubscription = device.connectionState.listen((state) {
        diagnostics?.info('BLE 链路', 'connectionState=${state.name}');
        final isCurrentDevice = _device?.remoteId == device.remoteId;
        final shouldHandleDisconnect = disconnectGate.shouldHandle(
          connected: state == BluetoothConnectionState.connected,
          isCurrentDevice: isCurrentDevice,
        );
        if (shouldHandleDisconnect) {
          lastError = '蓝牙连接已断开';
          diagnostics?.warning('蓝牙连接', '设备连接意外断开');
          _clearGatt();
          connectionStatus = BleConnectionStatus.disconnected;
          _pendingResponse?.completeError(Exception('蓝牙连接已断开'));
          _pendingResponse = null;
          _notifyIfAlive();
        }
      });
      await device.connect(
          timeout: const Duration(seconds: 12), autoConnect: false);
      diagnostics?.info('BLE 连接', 'GATT 连接完成，开始发现服务');
      if (attempt != _connectionAttempt) throw Exception('连接已取消');
      final services = await device.discoverServices();
      diagnostics?.info('BLE GATT',
          '发现 ${services.length} 个服务：${services.map((item) => item.uuid.str).join(', ')}');
      if (attempt != _connectionAttempt) throw Exception('连接已取消');
      BluetoothService? service;
      for (final item in services) {
        if (item.uuid.str.toLowerCase() == BleProtocol.serviceUuid) {
          service = item;
          break;
        }
      }
      if (service == null) {
        throw Exception('设备未提供 ${AppIdentity.productName} 控制服务');
      }
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str.toLowerCase();
        if (uuid == BleProtocol.commandUuid) _command = characteristic;
        if (uuid == BleProtocol.responseUuid) _response = characteristic;
      }
      if (_command == null || _response == null) {
        throw Exception('未找到 ${AppIdentity.productName} 命令或响应通道');
      }
      await _response!.setNotifyValue(true);
      diagnostics?.info('BLE GATT',
          '已启用响应通知；command=${_command!.uuid.str}, response=${_response!.uuid.str}');
      _notificationSubscription = _response!.onValueReceived.listen((bytes) {
        try {
          // 只把当前请求期间的通知交给解码器；完成响应后到达的冗余尾包不属于下一请求。
          if (_pendingResponse == null) return;
          _responseChunks.add(List.of(bytes));
          final result = _decoder.add(bytes);
          if (result != null && _pendingResponse?.isCompleted == false) {
            _pendingResponse!.complete(result);
            _pendingResponse = null;
          }
        } catch (error) {
          if (_pendingResponse?.isCompleted == false) {
            _pendingResponse!.completeError(error);
            _pendingResponse = null;
          }
        }
      });
      connectionStatus = BleConnectionStatus.connected;
      diagnostics?.info('蓝牙连接', 'GATT 服务与命令通道已就绪');
      _notifyIfAlive();
    } catch (error) {
      if (attempt == _connectionAttempt) {
        lastError = '连接失败：$error';
        diagnostics?.error('蓝牙连接', lastError!);
        connectionStatus = BleConnectionStatus.disconnected;
        await _connectionSubscription?.cancel();
        _connectionSubscription = null;
        try {
          await device.disconnect();
        } catch (_) {}
        _clearGatt();
        _notifyIfAlive();
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    ++_scanAttempt;
    ++_connectionAttempt;
    final device = _device;
    _device = null;
    if (device != null) diagnostics?.info('蓝牙连接', '主动断开设备连接');
    final pending = _pendingResponse;
    _pendingResponse = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('蓝牙会话已断开'));
    }
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    // 断开前的 ScanResult 仍包含旧 BluetoothDevice；不能把它显示成新扫描结果。
    _scanResults.clear();
    await _notificationSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _notificationSubscription = null;
    _connectionSubscription = null;
    _device = null;
    _clearGatt();
    connectionStatus = BleConnectionStatus.disconnected;
    _notifyIfAlive();
  }

  void _clearGatt() {
    _command = null;
    _response = null;
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _device = null;
  }

  Future<BleResponse> request({
    required String method,
    required String path,
    required Map<String, String> query,
    String body = '',
  }) {
    // 在入队时固定设备、命令通道和连接序号；旧请求不能在重连后误发给新设备。
    final attempt = _connectionAttempt;
    final device = _device;
    final command = _command;
    return _runQueuedRequest(
      attempt: attempt,
      device: device,
      command: command,
      method: method,
      path: path,
      query: query,
      body: body,
    );
  }

  Future<BleResponse> _runQueuedRequest({
    required int attempt,
    required BluetoothDevice? device,
    required BluetoothCharacteristic? command,
    required String method,
    required String path,
    required Map<String, String> query,
    required String body,
  }) async {
    final result = await _requestQueue.enqueue(
      isSessionCurrent: () =>
          attempt == _connectionAttempt &&
          device != null &&
          identical(device, _device) &&
          command != null &&
          identical(command, _command) &&
          isConnected,
      send: () => _sendRequest(
        attempt: attempt,
        device: device,
        command: command,
        method: method,
        path: path,
        query: query,
        body: body,
      ),
    );
    if (result is BleRequestSucceeded<BleResponse>) return result.value;
    if (result is BleRequestRejected<BleResponse>) {
      Error.throwWithStackTrace(result.error, result.stackTrace);
    }
    throw StateError('未知 BLE 请求结果');
  }

  Future<BleResponse> _sendRequest({
    required int attempt,
    required BluetoothDevice? device,
    required BluetoothCharacteristic? command,
    required String method,
    required String path,
    required Map<String, String> query,
    required String body,
  }) async {
    if (!isConnected ||
        attempt != _connectionAttempt ||
        device == null ||
        !identical(device, _device) ||
        command == null ||
        !identical(command, _command)) {
      throw Exception('请先连接 ${AppIdentity.productName}');
    }
    // 固件会为降低尾包丢失而重复发送最后通知。等待通知队列排空，避免旧响应串入下一条请求。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final packet = BleProtocol.encodeRequest(
      method: method,
      path: path,
      profile: query['profile'] ?? 'production',
      mode: query['mode'] ?? '',
      stage: query['stage'] ?? '',
      replace: query['replace'] == '1',
      switchProfile: query['switch'] == '1',
      body: body,
    );
    final packetBytes = utf8.encode(packet);
    _responseChunks.clear();
    _decoder.reset();
    final pending = Completer<BleResponse>();
    // BLE 可能在 write 返回前断开；提前挂错误监听，避免响应 Future 暂时无人消费。
    unawaited(pending.future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    ));
    _pendingResponse = pending;
    final stopwatch = Stopwatch()..start();
    try {
      // 固件命令特征支持 Write With Response；每次只发送一条请求。
      await command.write(packetBytes, withoutResponse: false);
      if (attempt != _connectionAttempt ||
          !identical(device, _device) ||
          !identical(command, _command)) {
        throw StateError('蓝牙会话已变化，请重新发起请求');
      }
      final response = await pending.future.timeout(const Duration(seconds: 6));
      stopwatch.stop();
      // 高频状态轮询默认交给 API 层记录状态变化摘要，避免每秒保存一整笔原始报文。
      // 用户可在设备日志页短时开启原始抓取，排查分包或协议异常。
      if (!_isRoutineStatusPoll(method, path) ||
          (diagnostics?.isCapturingStatusPolls ?? false)) {
        diagnostics?.info(
          'BLE 事务',
          '耗时=${stopwatch.elapsedMilliseconds}ms\n'
              'TX ${packetBytes.length}B ${_visibleText(packet)}\n'
              'RX ${_responseChunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}B '
              'chunks=${_responseChunks.length} hex=${_formatChunks(_responseChunks)}\n'
              'HTTP ${response.statusCode}\n${response.body}',
        );
      }
      return response;
    } on TimeoutException {
      stopwatch.stop();
      diagnostics?.error(
        'BLE 超时',
        '耗时=${stopwatch.elapsedMilliseconds}ms\n'
            'TX ${packetBytes.length}B ${_visibleText(packet)}\n'
            'RX ${_responseChunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}B '
            'chunks=${_responseChunks.length} hex=${_formatChunks(_responseChunks)}',
      );
      if (attempt == _connectionAttempt && identical(device, _device)) {
        _pendingResponse = null;
        await disconnect();
      }
      throw Exception('蓝牙请求超时，已断开连接；请重新连接设备');
    } catch (error) {
      stopwatch.stop();
      diagnostics?.error(
        'BLE 请求异常',
        '耗时=${stopwatch.elapsedMilliseconds}ms\n'
            'TX ${packetBytes.length}B ${_visibleText(packet)}\n'
            'RX ${_responseChunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}B '
            'chunks=${_responseChunks.length} hex=${_formatChunks(_responseChunks)}\n'
            'error=$error',
      );
      if (_isLinkLossError(error)) {
        // 有些 Android GATT 写入会直接报“设备未连接”，却不发断开状态事件。
        // 主动清理会话，让控制页、导航和顶部连接指示同步进入离线状态。
        _pendingResponse = null;
        lastError = '蓝牙连接已断开';
        await disconnect();
      }
      rethrow;
    } finally {
      if (identical(_pendingResponse, pending)) _pendingResponse = null;
    }
  }

  bool _isRoutineStatusPoll(String method, String path) =>
      method == 'GET' && path == '/api/status';

  bool _isLinkLossError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('not connected') ||
        message.contains('fbp-code: 6') ||
        message.contains('device is disconnected');
  }

  String _visibleText(String value) => value.replaceAll('\n', r'\n');

  String _formatChunks(List<List<int>> chunks) => chunks
      .map((chunk) =>
          chunk.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' '))
      .join(' | ');

  Future<void> stopScan() async {
    ++_scanAttempt;
    await FlutterBluePlus.stopScan();
    if (connectionStatus == BleConnectionStatus.scanning) {
      connectionStatus = BleConnectionStatus.disconnected;
    }
    _notifyIfAlive();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanSubscription?.cancel();
    _notificationSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}
