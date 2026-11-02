import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/app_identity.dart';
import '../core/diagnostics/app_diagnostics_log.dart';
import 'ble_disconnect_gate.dart';
import 'ble_gatt_scheduler.dart';
import 'ble_request_queue.dart';
import 'ble_protocol.dart';
import '../transport/device_transport.dart';
import '../transport/ota_capabilities.dart';
import '../transport/ota_transfer_policy.dart';

class _OtaPausedException implements Exception {}

enum BleConnectionStatus { disconnected, scanning, connecting, connected }

/// BLE 传输适配层。界面和控制 API 不直接依赖 FlutterBluePlus。
class MimiVentBleManager extends ChangeNotifier
    implements FirmwareUpdateTransport {
  MimiVentBleManager({this.diagnostics});

  final AppDiagnosticsLog? diagnostics;
  final List<ScanResult> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _command;
  BluetoothCharacteristic? _response;
  BluetoothCharacteristic? _otaControl;
  BluetoothCharacteristic? _otaData;
  BluetoothCharacteristic? _otaStatus;
  BluetoothCharacteristic? _wifiCommand;
  BluetoothCharacteristic? _wifiResponse;
  StreamSubscription<List<int>>? _otaSubscription;
  StreamSubscription<List<int>>? _wifiNotificationSubscription;
  bool _wifiNotificationsEnabled = false;
  bool _wifiBondedForSession = false;
  final StreamController<String> _otaEvents = StreamController.broadcast();
  Completer<DeviceResponse>? _pendingResponse;
  final List<List<int>> _responseChunks = [];
  final BleResponseDecoder _decoder = BleResponseDecoder();
  final LegacyBleResponseDecoder _legacyDecoder = LegacyBleResponseDecoder();
  final BleRequestQueue _requestQueue = BleRequestQueue();
  final BleGattScheduler _gattScheduler = BleGattScheduler();
  int _connectionAttempt = 0;
  int _scanAttempt = 0;
  int _nextRequestId = 1;
  int _nextOtaRequestId = 1;
  int _lastLoggedOtaProgress = 0;
  int _activeRequestId = 0;
  int negotiatedMtu = 23;
  int _otaMaximumChunkBytes = 512;
  int _otaMaximumWindow = 4;
  int _consecutiveRequestTimeouts = 0;
  @override
  bool isOtaUploading = false;
  @override
  bool isOtaVerifying = false;
  bool _firmwareAppCompatible = true;
  bool _deviceOtaBusy = false;
  bool _otaInstalling = false;

  @override
  bool get isOtaExclusive => isOtaUploading || isOtaVerifying || deviceOtaBusy;

  @override
  bool get appVersionCompatible => _firmwareAppCompatible;

  @override
  bool get deviceOtaBusy => _deviceOtaBusy;

  @override
  void setDeviceOtaBusy(bool value) {
    if (_deviceOtaBusy == value) return;
    _deviceOtaBusy = value;
    _notifyIfAlive();
  }

  @override
  void setFirmwareAppCompatible(bool value) {
    if (_firmwareAppCompatible == value) return;
    _firmwareAppCompatible = value;
    _notifyIfAlive();
  }

  bool _otaPauseRequested = false;
  bool _legacyControlProtocol = false;
  bool _protocolProbePending = false;
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
  @override
  bool get isConnected => connectionStatus == BleConnectionStatus.connected;
  bool get isScanning => connectionStatus == BleConnectionStatus.scanning;
  @override
  String? get connectedDeviceId => _device?.remoteId.str;
  bool get hasWifiProvisioningService =>
      _wifiCommand != null && _wifiResponse != null;

  @override
  Future<String> readOtaStatus() async {
    final characteristic = _otaStatus;
    if (characteristic == null || !isConnected) {
      throw StateError('OTA 状态通道不可用');
    }
    final bytes = await _withOtaGattQueue(characteristic, characteristic.read);
    return String.fromCharCodes(bytes);
  }

  Future<void> _writeOtaControl(
      BluetoothCharacteristic characteristic, List<int> value,
      {bool allowLongWrite = false}) async {
    await _withOtaGattQueue(
      characteristic,
      () => characteristic.write(value, allowLongWrite: allowLongWrite),
    );
  }

  Future<T> _withOtaGattQueue<T>(
    BluetoothCharacteristic characteristic,
    Future<T> Function() operation,
  ) async {
    final device = _device;
    final attempt = _connectionAttempt;
    final result = await _requestQueue.enqueue<T>(
      isSessionCurrent: () =>
          attempt == _connectionAttempt &&
          device != null &&
          identical(device, _device) &&
          (identical(characteristic, _otaControl) ||
              identical(characteristic, _otaStatus) ||
              identical(characteristic, _otaData)) &&
          isConnected,
      send: () => _gattScheduler.run(operation),
    );
    if (result is BleRequestSucceeded<T>) return result.value;
    final rejected = result as BleRequestRejected<T>;
    Error.throwWithStackTrace(rejected.error, rejected.stackTrace);
  }

  @override
  Future<DeviceResponse> send(DeviceRequest request) => this.request(
        method: request.method,
        path: request.path,
        query: request.query,
        body: request.body,
      );

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

  Future<void> _connectWithRetry(BluetoothDevice device, int attempt) async {
    for (var retry = 0;; retry++) {
      try {
        await device.connect(
          timeout: const Duration(seconds: 20),
          // flutter_blue_plus 默认 mtu=512，会在 connect() 内隐式请求 MTU，
          // Android 上可能卡满其 15 秒默认超时；MTU 在下方单独协商并可降级。
          mtu: null,
          autoConnect: false,
        );
        return;
      } catch (error) {
        final text = error.toString();
        final transient = text.contains('android-code: 133') ||
            text.contains('android-code: 129') ||
            text.contains('android-code: 62');
        if (!transient || retry >= 2) rethrow;
        if (attempt != _connectionAttempt) throw Exception('连接已取消');
        try {
          await device.disconnect();
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: 800 * (retry + 1)));
        if (attempt != _connectionAttempt) throw Exception('连接已取消');
      }
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    if (_device != null || _connectionSubscription != null) {
      await disconnect();
    }
    // 使当前扫描回调和 finally 失效，避免扫描结束把 connecting 改回 disconnected。
    ++_scanAttempt;
    final attempt = ++_connectionAttempt;
    final connectStopwatch = Stopwatch()..start();
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
        final isCurrentDevice = attempt == _connectionAttempt &&
            _device?.remoteId == device.remoteId;
        final shouldHandleDisconnect = disconnectGate.shouldHandle(
          connected: state == BluetoothConnectionState.connected,
          isCurrentDevice: isCurrentDevice,
        );
        if (shouldHandleDisconnect) {
          lastError = _otaInstalling ? null : '蓝牙连接已断开';
          if (_otaInstalling) {
            diagnostics?.info('BLE OTA', '安装期间设备按预期断开，等待重启');
          } else {
            diagnostics?.warning('蓝牙连接', '设备连接意外断开');
          }
          _clearGatt();
          connectionStatus = BleConnectionStatus.disconnected;
          _pendingResponse?.completeError(Exception('蓝牙连接已断开'));
          _pendingResponse = null;
          _notifyIfAlive();
        }
      });
      await _connectWithRetry(device, attempt);
      diagnostics?.info(
        'BLE 连接',
        'GATT 链路完成，耗时=${connectStopwatch.elapsedMilliseconds}ms；开始发现服务',
      );
      if (attempt != _connectionAttempt) throw Exception('连接已取消');
      negotiatedMtu = device.mtuNow;
      if (Platform.isAndroid) {
        try {
          negotiatedMtu = await device.requestMtu(247, timeout: 5);
          diagnostics?.info(
            'BLE MTU',
            '协商完成，实际 MTU=$negotiatedMtu；累计耗时=${connectStopwatch.elapsedMilliseconds}ms',
          );
        } catch (error) {
          negotiatedMtu = device.mtuNow;
          diagnostics?.warning(
            'BLE MTU',
            '协商失败，使用系统实际 MTU=$negotiatedMtu；累计耗时=${connectStopwatch.elapsedMilliseconds}ms：$error',
          );
        }
      } else {
        diagnostics?.info('BLE MTU', '系统协商 MTU=$negotiatedMtu');
      }
      if (attempt != _connectionAttempt) throw Exception('连接已取消');
      final services = await _gattScheduler.run(device.discoverServices);
      diagnostics?.info('BLE GATT',
          '发现 ${services.length} 个服务，累计耗时=${connectStopwatch.elapsedMilliseconds}ms：${services.map((item) => item.uuid.str).join(', ')}');
      if (attempt != _connectionAttempt) throw Exception('连接已取消');
      BluetoothService? service;
      BluetoothService? wifiService;
      for (final item in services) {
        if (item.uuid.str.toLowerCase() == BleProtocol.serviceUuid) {
          service = item;
        } else if (item.uuid.str.toLowerCase() == BleProtocol.wifiServiceUuid) {
          wifiService = item;
        }
      }
      if (service == null) {
        throw Exception('设备未提供 ${AppIdentity.productName} 控制服务');
      }
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str.toLowerCase();
        if (uuid == BleProtocol.commandUuid) _command = characteristic;
        if (uuid == BleProtocol.responseUuid) _response = characteristic;
        if (uuid == BleProtocol.otaControlUuid) _otaControl = characteristic;
        if (uuid == BleProtocol.otaDataUuid) _otaData = characteristic;
        if (uuid == BleProtocol.otaStatusUuid) _otaStatus = characteristic;
      }
      if (wifiService != null) {
        for (final characteristic in wifiService.characteristics) {
          final uuid = characteristic.uuid.str.toLowerCase();
          if (uuid == BleProtocol.wifiCommandUuid)
            _wifiCommand = characteristic;
          if (uuid == BleProtocol.wifiResponseUuid) {
            _wifiResponse = characteristic;
          }
        }
        if (_wifiCommand == null || _wifiResponse == null) {
          _wifiCommand = null;
          _wifiResponse = null;
          diagnostics?.warning('WiFi 配网', '设备 WiFi GATT 服务特征不完整，已隐藏配网能力');
        }
      }
      if (_command == null || _response == null) {
        throw Exception('未找到 ${AppIdentity.productName} 命令或响应通道');
      }
      String greeting = '';
      for (var attempt = 0; attempt < 3 && greeting.isEmpty; attempt++) {
        try {
          greeting = ascii.decode(await _gattScheduler.run(_response!.read),
              allowInvalid: true);
        } catch (error) {
          diagnostics?.warning('BLE 协议', '读取协议问候失败 ${attempt + 1}/3：$error');
          if (attempt < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
      }
      if (greeting.startsWith('MimiVent BLE API v1')) {
        _legacyControlProtocol = true;
        _protocolProbePending = false;
      } else if (greeting.startsWith('MimiVent BLE API v2')) {
        _legacyControlProtocol = false;
        _protocolProbePending = false;
      } else if (greeting.isEmpty) {
        // 问候特征暂时不可读时保留普通 BLE 连接；首个有效响应决定协议。
        _legacyControlProtocol = false;
        _protocolProbePending = true;
        diagnostics?.warning('BLE 协议', '问候读取失败，先尝试 v2；仅在识别到合法 v1 响应后降级');
      } else {
        throw StateError('收到不支持的 BLE API 问候：$greeting');
      }
      diagnostics?.info(
          'BLE 协议', '识别到 ${_legacyControlProtocol ? 'v1 旧协议' : 'v2'} 控制通道');
      await _gattScheduler.run(() => _response!.setNotifyValue(true));
      diagnostics?.info('BLE GATT',
          '已启用响应通知；command=${_command!.uuid.str}, response=${_response!.uuid.str}');
      _notificationSubscription =
          _response!.onValueReceived.listen(_handleResponseNotification);
      // WiFi 配网响应通知在 requestWifi() 完成配对后单独启用；
      // 这里不订阅，避免同一通知被两个 listener 重复处理。
      if (_otaControl != null && _otaData != null && _otaStatus != null) {
        try {
          await _gattScheduler.run(() => _otaStatus!.setNotifyValue(true));
          _otaSubscription =
              _otaStatus!.onValueReceived.listen(_handleOtaNotification);
          diagnostics?.info('BLE OTA', '升级通道就绪');
        } catch (error) {
          diagnostics?.warning('BLE OTA', '升级状态通知不可用，保留普通 BLE 控制：$error');
          await _otaSubscription?.cancel();
          _otaSubscription = null;
          _otaControl = null;
          _otaData = null;
          _otaStatus = null;
        }
      }
      _deviceOtaBusy = false;
      connectionStatus = BleConnectionStatus.connected;
      diagnostics?.info('蓝牙连接', 'GATT 服务与命令通道已就绪');
      _notifyIfAlive();
    } catch (error, stackTrace) {
      if (attempt == _connectionAttempt) {
        lastError = '连接失败：$error';
        diagnostics?.error('蓝牙连接', lastError!, stackTrace: stackTrace);
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

  void _handleResponseNotification(List<int> bytes) {
    try {
      if (_pendingResponse == null) return;
      _responseChunks.add(List.of(bytes));
      DeviceResponse? result;
      if (_legacyControlProtocol) {
        result = _legacyDecoder.add(bytes);
      } else if (_protocolProbePending &&
          _looksLikeLegacyResponsePrefix(_responseChunks)) {
        result = _legacyDecoder.add(bytes);
        if (result != null) {
          _legacyControlProtocol = true;
          _protocolProbePending = false;
          diagnostics?.info('BLE 协议', '首个响应符合 v1 状态行格式，切换到兼容控制通道');
        }
      } else {
        _protocolProbePending = false;
        result = _decoder.add(bytes, expectedRequestId: _activeRequestId);
      }
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
  }

  Future<void> disconnect() async {
    ++_scanAttempt;
    ++_connectionAttempt;
    final device = _device;
    _device = null;
    negotiatedMtu = 23;
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
    await _wifiNotificationSubscription?.cancel();
    await _otaSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _notificationSubscription = null;
    _wifiNotificationSubscription = null;
    _otaSubscription = null;
    _connectionSubscription = null;
    _device = null;
    _clearGatt();
    connectionStatus = BleConnectionStatus.disconnected;
    _notifyIfAlive();
  }

  void _clearGatt() {
    _command = null;
    _response = null;
    _otaControl = null;
    _otaData = null;
    _otaStatus = null;
    _wifiCommand = null;
    _wifiResponse = null;
    _wifiNotificationsEnabled = false;
    _wifiBondedForSession = false;
    _legacyControlProtocol = false;
    _protocolProbePending = false;
    _legacyDecoder.reset();
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    unawaited(_wifiNotificationSubscription?.cancel());
    _wifiNotificationSubscription = null;
    unawaited(_otaSubscription?.cancel());
    _otaSubscription = null;
    _device = null;
  }

  Future<String> _waitOtaStatus(bool Function(String) predicate,
      {Duration timeout = const Duration(seconds: 20)}) {
    final waiting = _otaEvents.stream.firstWhere(predicate).timeout(timeout);
    unawaited(
        waiting.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return waiting;
  }

  Future<String> _waitOtaReady({
    required void Function(OtaTransferStage stage)? onStage,
  }) async {
    var timeout = const Duration(seconds: 20);
    while (true) {
      final status = await _waitOtaStatus(
        (value) =>
            value.startsWith('READY|') ||
            value.startsWith('RESUMED|') ||
            value.startsWith('ERASING|') ||
            value.startsWith('ERROR|'),
        timeout: timeout,
      );
      if (!status.startsWith('ERASING|')) return status;
      onStage?.call(OtaTransferStage.erasing);
      diagnostics?.info('BLE OTA', '设备正在擦除 OTA 分区：$status');
      timeout = const Duration(seconds: 60);
    }
  }

  void _handleOtaNotification(List<int> bytes) {
    final value = String.fromCharCodes(bytes);
    if (value.startsWith('EVT|')) {
      unawaited(_readOtaEventSnapshot(value));
      return;
    }
    if (value.startsWith('ACK|')) {
      final fields = value.split('|');
      final offset = fields.length > 1 ? int.tryParse(fields[1]) : null;
      if (offset != null && offset - _lastLoggedOtaProgress >= 64 * 1024) {
        _lastLoggedOtaProgress = offset;
        diagnostics?.info('BLE OTA 进度', '设备接收偏移 $offset');
      }
    } else {
      diagnostics?.info('BLE OTA 状态', value);
    }
    _otaEvents.add(value);
  }

  Future<void> _readOtaEventSnapshot(String event) async {
    final expectedPhase = event.substring('EVT|'.length);
    for (var attempt = 0; attempt < 3 && isConnected; attempt++) {
      try {
        final snapshot = await readOtaStatus();
        final phaseMatches = snapshot.startsWith('$expectedPhase|') ||
            snapshot == expectedPhase ||
            snapshot.startsWith('ERROR|');
        if (phaseMatches && !snapshot.startsWith('EVT|')) {
          _otaEvents.add(snapshot);
          return;
        }
      } catch (error) {
        diagnostics?.warning(
            'BLE OTA 状态读取', '事件=$event 尝试=${attempt + 1}：$error');
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    diagnostics?.warning('BLE OTA 状态读取', '短通知对应的完整状态未能读取：$event');
  }

  int _takeOtaRequestId() => _nextOtaRequestId++;

  @override
  Future<OtaUploadOutcome> uploadFirmware({
    required String deviceId,
    required String taskId,
    required String firmwareVersion,
    required int imageLength,
    required String sha256,
    required int packageLength,
    required String packageSha256,
    required bool compressedPackage,
    required bool deltaPackage,
    required String baseVersion,
    required int baseImageLength,
    required String baseSha256,
    required bool allowDowngrade,
    required bool legacyProtocol,
    void Function(OtaTransferStage stage)? onStage,
    Future<void> Function()? onLegacyInstallCommit,
    required Stream<List<int>> Function(int offset, int maxLength) image,
    required void Function(int sentBytes, int totalBytes) onProgress,
  }) async {
    final control = _otaControl;
    final data = _otaData;
    if (!isConnected || control == null || data == null || _otaStatus == null) {
      throw StateError('当前设备固件不支持 BLE OTA');
    }
    if (_device?.remoteId.str != deviceId) throw StateError('设备连接已变化');
    if (isOtaUploading) throw StateError('已有固件升级任务正在运行');
    if (!legacyProtocol && negotiatedMtu < 64) {
      throw StateError('蓝牙 MTU=$negotiatedMtu 过低，请重连后重试 OTA');
    }
    final devicePayloadLimit = _otaMaximumChunkBytes - 8;
    if (!legacyProtocol && devicePayloadLimit < 48) {
      throw StateError('设备未声明有效 OTA 分块上限，请重新连接并查询设备能力');
    }
    final maxPayload = legacyProtocol
        ? 20
        : math.min(negotiatedMtu - 11, math.min(500, devicePayloadLimit));
    isOtaUploading = true;
    _otaPauseRequested = false;
    onStage?.call(OtaTransferStage.uploading);
    var verificationComplete = false;
    final transferClock = Stopwatch()..start();
    _lastLoggedOtaProgress = 0;
    _notifyIfAlive();
    try {
      // 等待开始 OTA 前已发出的普通 BLE RPC 完成；新请求会由 isOtaExclusive 门禁拒绝。
      await _requestQueue.idle;
      final readyFuture = _waitOtaReady(onStage: onStage);
      await _writeOtaControl(
        control,
        legacyProtocol
            ? 'BEGIN|$firmwareVersion|$imageLength|$sha256'.codeUnits
            : deltaPackage
                ? 'BEGIN_DELTA|$taskId|$firmwareVersion|$packageLength|$packageSha256|$imageLength|$sha256|$baseVersion|$baseImageLength|$baseSha256|${allowDowngrade ? 1 : 0}'
                    .codeUnits
                : compressedPackage
                    ? 'BEGIN2|$taskId|$firmwareVersion|$packageLength|$packageSha256|$imageLength|$sha256|${allowDowngrade ? 1 : 0}'
                        .codeUnits
                    : 'BEGIN|$taskId|$firmwareVersion|$imageLength|$sha256'
                        .codeUnits,
        allowLongWrite: true,
      );
      final ready = await readyFuture;
      if (!ready.startsWith('READY|') && !ready.startsWith('RESUMED|')) {
        throw StateError('设备拒绝升级：$ready');
      }
      final readyFields = ready.split('|');
      var offset = ready.startsWith('RESUMED|') && readyFields.length > 3
          ? int.tryParse(readyFields[3]) ?? 0
          : 0;
      final transferLength = otaTransferLength(
        imageLength: imageLength,
        packageLength: packageLength,
        compressedPackage: compressedPackage,
        deltaPackage: deltaPackage,
      );
      if (!legacyProtocol && (offset < 0 || offset > transferLength)) {
        throw StateError('设备续传偏移无效：$offset');
      }

      // ATT 的每个写入值最多为 MTU-3 字节，再减去 offset 与 CRC 帧头。
      // maxChunk 是设备接收的整帧上限，含 8 字节偏移与 CRC 头。
      diagnostics?.info('BLE OTA',
          'taskId=$taskId 阶段=上传 MTU=$negotiatedMtu payload=$maxPayload window=4 packageBytes=$transferLength imageBytes=$imageLength packageSha256=$packageSha256 imageSha256=$sha256 compressed=$compressedPackage');
      final maximumWindow = math.min(4, _otaMaximumWindow);
      var windowSize = maximumWindow.clamp(1, 4).toInt();
      var retries = 0;
      while (offset < transferLength) {
        if (_otaPauseRequested) return OtaUploadOutcome.paused;
        final windowStart = offset;
        final windowLength = (maxPayload * windowSize)
            .clamp(0, transferLength - windowStart)
            .toInt();
        final windowEnd = windowStart + windowLength;
        // 先订阅再发包，避免设备快速回 ACK 后通知已被错过。
        final ackFuture = _waitForOtaAck(windowEnd, transferLength);
        var pending = <int>[];
        var chunksInWindow = 0;
        var sentEnd = windowStart;
        await for (final source in image(windowStart, windowLength)) {
          if (_otaPauseRequested) break;
          pending.addAll(source);
          while (pending.length >= maxPayload && chunksInWindow < windowSize) {
            if (_otaPauseRequested) break;
            final chunk = pending.sublist(0, maxPayload);
            pending = pending.sublist(maxPayload);
            sentEnd = await _sendOtaChunk(data, chunk, sentEnd, transferLength,
                waitForAck: false);
            chunksInWindow++;
          }
        }
        if (!_otaPauseRequested &&
            pending.isNotEmpty &&
            chunksInWindow < windowSize) {
          sentEnd = await _sendOtaChunk(data, pending, sentEnd, transferLength,
              waitForAck: false);
          chunksInWindow++;
        }
        if (chunksInWindow == 0 && !_otaPauseRequested) {
          throw StateError('OTA 包流未提供数据，当前位置 $windowStart/$transferLength');
        }
        try {
          final availableChunks = await ackFuture;
          if (availableChunks != null) {
            windowSize =
                otaWindowSizeForCredits(availableChunks, maximumWindow);
            if (windowSize == 0) {
              windowSize = await _waitForOtaBufferCredits(maximumWindow);
            }
          }
          retries = 0;
          offset = sentEnd;
          onProgress(offset, transferLength);
          if (_otaPauseRequested) return OtaUploadOutcome.paused;
        } catch (error) {
          if (_otaPauseRequested) {
            if (legacyProtocol) {
              final status = await readOtaStatus();
              if (status.startsWith('PAUSED|') ||
                  status.startsWith('ERROR|ABORTED')) {
                return OtaUploadOutcome.paused;
              }
            } else {
              final status = await queryOtaTask();
              if (status.startsWith('PAUSED|')) return OtaUploadOutcome.paused;
            }
          }
          if (legacyProtocol) {
            throw StateError('旧协议无法查询续传偏移，上传中断后需重新开始：$error');
          }
          final status = await queryOtaTask();
          final fields = status.split('|');
          if (status.startsWith('PAUSED|')) return OtaUploadOutcome.paused;
          final actualOffset =
              status.startsWith('UPLOADING|') && fields.length > 1
                  ? int.tryParse(fields[1])
                  : null;
          if (actualOffset == null ||
              actualOffset < windowStart ||
              actualOffset > sentEnd ||
              ++retries > 3) {
            throw StateError('确认超时且设备偏移无法安全恢复：$status；原因为 $error');
          }
          diagnostics?.warning(
              'BLE OTA', '确认窗口异常，按设备包偏移恢复：$actualOffset/$transferLength');
          offset = actualOffset;
        }
      }
      if (offset != transferLength) {
        throw StateError('OTA 包长度不匹配：$offset/$transferLength');
      }
      final doneFuture = _waitOtaStatus(
        (value) =>
            value.startsWith('VERIFIED|') ||
            value.startsWith('PAUSED|') ||
            (legacyProtocol && value.startsWith('DONE|')) ||
            value.startsWith('ERROR|'),
        timeout: const Duration(seconds: 40),
      );
      onStage?.call(OtaTransferStage.verifying);
      isOtaUploading = false;
      isOtaVerifying = true;
      _notifyIfAlive();
      verificationComplete = true;
      String result;
      try {
        if (legacyProtocol) await onLegacyInstallCommit?.call();
        await _writeOtaControl(
            control,
            legacyProtocol
                ? 'FINISH'.codeUnits
                : 'FINISH|$taskId|${_takeOtaRequestId()}'.codeUnits);
        result = await doneFuture;
      } catch (error) {
        // FINISH 写入或响应超时属于结果未知；查询设备状态，不发 ABORT 或重新上传。
        try {
          result =
              legacyProtocol ? await readOtaStatus() : await queryOtaTask();
        } catch (queryError) {
          diagnostics?.warning('BLE OTA',
              'taskId=$taskId 阶段=校验结果待确认，原因为 $error；查询失败=$queryError');
          return OtaUploadOutcome.resultPending;
        }
        if (legacyProtocol && result.startsWith('DONE|')) {
          return OtaUploadOutcome.legacyInstallStarted;
        }
        if (!legacyProtocol && result.startsWith('VERIFIED|')) {
          // 继续走统一 VERIFIED 结果处理。
        } else if (result.startsWith('ERROR|') ||
            result.startsWith('PAUSED|')) {
          throw StateError('设备未完成校验：$result');
        } else {
          diagnostics?.warning(
              'BLE OTA', 'taskId=$taskId 阶段=校验结果待确认 status=$result；原因为 $error');
          return OtaUploadOutcome.resultPending;
        }
      }
      if (legacyProtocol && result.startsWith('DONE|')) {
        diagnostics?.info('BLE OTA',
            'taskId=$taskId 阶段=旧协议设备确认并开始重启 version=$firmwareVersion sha256=$sha256，等待重连核验');
        return OtaUploadOutcome.legacyInstallStarted;
      }
      if (!result.startsWith('VERIFIED|')) throw StateError('固件校验失败：$result');
      transferClock.stop();
      final elapsedMs = transferClock.elapsedMilliseconds;
      final bytesPerSecond =
          elapsedMs > 0 ? transferLength * 1000 / elapsedMs : 0;
      diagnostics?.info('BLE OTA',
          'taskId=$taskId 阶段=校验通过 packageBytes=$transferLength imageBytes=$imageLength elapsedMs=$elapsedMs averagePackageBytesPerSecond=${bytesPerSecond.toStringAsFixed(0)} retries=$retries');
      return OtaUploadOutcome.verifiedAwaitingInstall;
    } on _OtaPausedException {
      diagnostics?.info('BLE OTA', '设备已确认暂停，保留可续传任务');
      return OtaUploadOutcome.paused;
    } catch (error, stackTrace) {
      if (!verificationComplete) {
        try {
          await _writeOtaControl(control, 'ABORT'.codeUnits);
        } catch (_) {}
      }
      diagnostics?.error(
          'BLE OTA', 'taskId=$taskId 阶段=失败 error=$error\n$stackTrace');
      rethrow;
    } finally {
      isOtaUploading = false;
      isOtaVerifying = false;
      _notifyIfAlive();
    }
  }

  @override
  Future<void> installVerifiedFirmware({
    required String taskId,
    required bool allowDowngrade,
  }) async {
    final control = _otaControl;
    final device = _device;
    if (!isConnected || control == null || device == null) {
      throw StateError('设备连接已断开');
    }
    if (_otaInstalling) throw StateError('正在等待设备安装并重连');
    _otaInstalling = true;
    setDeviceOtaBusy(true);
    try {
      await _requestQueue.idle;
      _otaPauseRequested = true;
      final installing = _waitOtaStatus(
        (value) =>
            value.startsWith('INSTALLING|') || value.startsWith('ERROR|'),
        timeout: const Duration(seconds: 10),
      );
      final installAttempt = _connectionAttempt;
      String? result;
      try {
        await _writeOtaControl(
            control,
            'INSTALL|$taskId|${allowDowngrade ? 1 : 0}|${_takeOtaRequestId()}'
                .codeUnits);
        result = await installing;
      } catch (error) {
        // 安装响应可能随重启丢失，先重连查询，不能据此重复提交安装。
        diagnostics?.warning('BLE OTA', '安装响应未确认，将重连查询：$error');
      }
      if (result != null && result.startsWith('ERROR|')) {
        setDeviceOtaBusy(false);
        throw StateError('设备未能提交安装：$result');
      }
      if (_disposed || installAttempt != _connectionAttempt) {
        throw StateError('安装结果待确认：连接会话已改变');
      }
      // 主动释放旧 GATT，避免手机继续持有重启前的服务与通知订阅。
      await disconnect();
      var expectedAttempt = _connectionAttempt;
      Object? lastFailure;
      for (var retry = 0; retry < 4; retry++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_disposed || expectedAttempt != _connectionAttempt) {
          throw StateError('自动重连已取消，请查询设备安装结果');
        }
        // connect 自身会先清理旧订阅，再建立全新的 GATT 会话。
        final beforeConnect = _connectionAttempt;
        try {
          await connect(device);
        } catch (error) {
          lastFailure = error;
          // 本次 connect 只递增一次；用户发起的新连接不能被自动重试覆盖。
          if (_connectionAttempt != beforeConnect + 1) rethrow;
          expectedAttempt = _connectionAttempt;
          continue;
        }
        final status = await queryOtaTask();
        if (!status.startsWith('INSTALLED|')) {
          throw StateError('设备已重连，安装结果需核实：$status');
        }
        return;
      }
      throw StateError('安装结果待确认，自动重连超时：$lastFailure');
    } finally {
      _otaInstalling = false;
      _notifyIfAlive();
    }
  }

  @override
  Future<String> queryOtaTask() async {
    final control = _otaControl;
    if (!isConnected || control == null) throw StateError('OTA 状态通道不可用');
    final response = _waitOtaStatus((value) =>
        value.startsWith('UPLOADING|') ||
        value.startsWith('VERIFYING|') ||
        value.startsWith('PAUSED|') ||
        value.startsWith('VERIFIED|') ||
        value.startsWith('INSTALLING|') ||
        value.startsWith('INSTALLED|') ||
        value == 'IDLE' ||
        value.startsWith('ERROR|'));
    await _writeOtaControl(control, 'QUERY'.codeUnits);
    final result = await response;
    setDeviceOtaBusy(result.startsWith('UPLOADING|') ||
        result.startsWith('VERIFYING|') ||
        result.startsWith('INSTALLING|'));
    return result;
  }

  @override
  Future<String> queryOtaCapabilities() async {
    final control = _otaControl;
    if (!isConnected) throw StateError('OTA 能力查询通道不可用');
    if (control == null || _otaData == null || _otaStatus == null) {
      return _legacyControlProtocol
          ? 'ERROR|USB_BOOTSTRAP_REQUIRED'
          : 'ERROR|OTA_CHANNEL_MISSING';
    }
    final response = _waitOtaStatus(
        (value) => value.startsWith('CAPS|') || value.startsWith('ERROR|'),
        timeout: const Duration(seconds: 3));
    await _writeOtaControl(control, 'CAPS'.codeUnits);
    try {
      final capabilities = await response;
      if (capabilities.startsWith('CAPS|2|')) {
        _recordOtaCapabilities(capabilities);
      }
      return capabilities;
    } on TimeoutException {
      // 旧 OTA 实现可能没有为无效 CAPS 命令发送通知，读取状态特征识别它。
      final capabilities = await readOtaStatus();
      if (capabilities.startsWith('CAPS|2|')) {
        _recordOtaCapabilities(capabilities);
      }
      return capabilities;
    }
  }

  void _recordOtaCapabilities(String value) {
    final parsed = OtaCapabilities.parse(value);
    _otaMaximumChunkBytes = parsed.intValue('maxChunk') ?? 0;
    _otaMaximumWindow = parsed.intValue('window') ?? 0;
  }

  @override
  Future<String> queryOtaDeviceInfo() async {
    final control = _otaControl;
    if (!isConnected || control == null) throw StateError('OTA 信息通道不可用');
    final response = _waitOtaStatus(
      (value) => value.startsWith('INFO|') || value.startsWith('ERROR|'),
      timeout: const Duration(seconds: 3),
    );
    await _writeOtaControl(control, 'INFO'.codeUnits);
    return response;
  }

  @override
  Future<void> pauseOtaTask({required String taskId}) async {
    final control = _otaControl;
    if (!isConnected || control == null) throw StateError('设备连接已断开');
    _otaPauseRequested = true;
    final response = _waitOtaStatus(
        (value) => value.startsWith('PAUSED|') || value.startsWith('ERROR|'));
    await _writeOtaControl(
        control, 'PAUSE|$taskId|${_takeOtaRequestId()}'.codeUnits);
    final result = await response;
    if (!result.startsWith('PAUSED|')) throw StateError('暂停未确认：$result');
  }

  @override
  Future<void> abortOtaTask() async {
    final control = _otaControl;
    if (!isConnected || control == null) throw StateError('设备连接已断开');
    _otaPauseRequested = true;
    final response = _waitOtaStatus(
        (value) => value.startsWith('PAUSED|') || value.startsWith('ERROR|'));
    await _writeOtaControl(control, 'ABORT'.codeUnits);
    final result = await response;
    if (!result.startsWith('PAUSED|') && !result.startsWith('ERROR|ABORTED')) {
      throw StateError('终止上传未确认：$result');
    }
  }

  @override
  Future<void> abandonOtaTask({required String taskId}) async {
    final control = _otaControl;
    if (!isConnected || control == null) throw StateError('设备连接已断开');
    final response = _waitOtaStatus(
        (value) => value == 'IDLE' || value.startsWith('ERROR|'));
    await _writeOtaControl(
        control, 'ABANDON|$taskId|${_takeOtaRequestId()}'.codeUnits);
    final result = await response;
    if (result != 'IDLE') throw StateError('放弃任务未确认：$result');
  }

  Future<int> _sendOtaChunk(BluetoothCharacteristic characteristic,
      List<int> payload, int offset, int total,
      {required bool waitForAck}) async {
    final frame = encodeOtaDataFrame(offset, payload);
    final nextOffset = offset + payload.length;
    final ackFuture = waitForAck ? _waitForOtaAck(nextOffset, total) : null;
    await _gattScheduler
        .run(() => characteristic.write(frame, withoutResponse: true));
    if (ackFuture != null) await ackFuture;
    return nextOffset;
  }

  Future<int?> _waitForOtaAck(int offset, int total) async {
    final ackFuture = _waitOtaStatus(
      (value) {
        final fields = value.split('|');
        final acknowledged = fields.length > 1 ? int.tryParse(fields[1]) : null;
        return value.startsWith('ERROR|') ||
            value.startsWith('PAUSED|') ||
            value.startsWith('FLOW|') ||
            (value.startsWith('ACK|') &&
                acknowledged != null &&
                acknowledged >= offset);
      },
      timeout: const Duration(seconds: 15),
    );
    final ack = await ackFuture;
    if (ack.startsWith('PAUSED|')) {
      _otaPauseRequested = true;
      throw _OtaPausedException();
    }
    if (ack.startsWith('FLOW|')) {
      throw StateError('设备缓冲区已满，需查询设备实际接收偏移后恢复：$ack');
    }
    try {
      return parseOtaAcknowledgement(
        ack,
        minimumOffset: offset,
        totalBytes: total,
      );
    } on FormatException catch (error) {
      throw StateError('累计数据确认失败：${error.message}，期望至少 $offset/$total');
    }
  }

  Future<int> _waitForOtaBufferCredits(int maximumWindow) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (_otaPauseRequested) throw _OtaPausedException();
      if (!isConnected) throw StateError('等待 OTA 流控时设备断开');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final status = await queryOtaTask();
      if (status.startsWith('PAUSED|')) throw _OtaPausedException();
      if (!status.startsWith('UPLOADING|')) {
        throw StateError('等待 OTA 流控时任务状态变化：$status');
      }
      final fields = status.split('|');
      final credits = fields.length > 8 ? int.tryParse(fields[8]) : null;
      if (credits == null || credits < 0) {
        throw StateError('设备未返回有效 OTA 缓冲量：$status');
      }
      final window = otaWindowSizeForCredits(credits, maximumWindow);
      if (window > 0) return window;
    }
    throw StateError('设备 OTA 缓冲区持续为满，等待流控超时');
  }

  Future<DeviceResponse> request({
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
      rawPacket: null,
    );
  }

  /// 发送 WiFi 配网服务的 JSON 请求；首次调用会触发 Android 系统配对流程。
  Future<DeviceResponse> requestWifi(Map<String, dynamic> envelope) async {
    final attempt = _connectionAttempt;
    final device = _device;
    final command = _wifiCommand;
    final response = _wifiResponse;
    if (!isConnected || device == null) {
      throw StateError('蓝牙未连接，请先连接设备后重试');
    }
    if (command == null || response == null) {
      throw StateError('当前固件没有可用的 WiFi 配网服务');
    }
    if (!Platform.isAndroid) {
      throw UnsupportedError('WiFi 配网目前仅支持 Android 系统蓝牙配对流程');
    }
    final operation = envelope['op']?.toString() ?? 'unknown';
    if (operation != 'wifi.status' &&
        (operation != 'wifi.scan' || envelope['start'] == true)) {
      diagnostics?.info('WiFi 配网', '开始操作 ' + operation);
    }
    try {
      if (!_wifiBondedForSession) {
        await device.createBond(timeout: 120);
        _wifiBondedForSession = true;
      }
      if (!_wifiNotificationsEnabled) {
        await _gattScheduler.run(() => response.setNotifyValue(true));
        _wifiNotificationSubscription =
            response.onValueReceived.listen(_handleResponseNotification);
        _wifiNotificationsEnabled = true;
      }
    } catch (error) {
      diagnostics?.warning('WiFi 配网', '系统蓝牙配对未完成：$error');
      throw StateError('系统蓝牙配对未完成，请完成系统配对弹窗后重试');
    }
    final result = await _runQueuedRequest(
      attempt: attempt,
      device: device,
      command: command,
      method: 'WIFI',
      path: '/wifi',
      query: const {},
      body: '',
      rawPacket: jsonEncode(envelope),
    );
    if (operation == 'wifi.scan') {
      try {
        final decoded = jsonDecode(result.body);
        if (decoded is Map<String, dynamic>) {
          final networks = decoded['networks'];
          final total = decoded['total'];
          final error = decoded['error'];
          final start = envelope['start'] == true;
          final state = decoded['state']?.toString() ?? 'unknown';
          if (start || state != 'scanning') {
            diagnostics?.info(
              'WiFi 扫描',
              'HTTP ${result.statusCode} state=$state'
                  '${total is num ? ' total=${total.toInt()}' : ''}'
                  '${networks is List ? ' networks=${networks.length}' : ''}'
                  '${error == null ? '' : ' error=$error'}',
            );
          }
        }
      } catch (error) {
        diagnostics?.warning('WiFi 扫描', '无法解析设备扫描响应：$error');
      }
    }
    return result;
  }

  Future<DeviceResponse> _runQueuedRequest({
    required int attempt,
    required BluetoothDevice? device,
    required BluetoothCharacteristic? command,
    required String method,
    required String path,
    required Map<String, String> query,
    required String body,
    String? rawPacket,
  }) async {
    final result = await _requestQueue.enqueue(
      isSessionCurrent: () =>
          attempt == _connectionAttempt &&
          device != null &&
          identical(device, _device) &&
          command != null &&
          (identical(command, _command) || identical(command, _wifiCommand)) &&
          isConnected,
      send: () => _sendRequest(
        attempt: attempt,
        device: device,
        command: command,
        method: method,
        path: path,
        query: query,
        body: body,
        rawPacket: rawPacket,
      ),
    );
    if (result is BleRequestSucceeded<DeviceResponse>) return result.value;
    if (result is BleRequestRejected<DeviceResponse>) {
      Error.throwWithStackTrace(result.error, result.stackTrace);
    }
    throw StateError('未知 BLE 请求结果');
  }

  Future<DeviceResponse> _sendRequest({
    required int attempt,
    required BluetoothDevice? device,
    required BluetoothCharacteristic? command,
    required String method,
    required String path,
    required Map<String, String> query,
    required String body,
    String? rawPacket,
  }) async {
    if (isOtaExclusive && !(method == 'GET' && path == '/api/status')) {
      throw const DeviceBusyException('设备正在执行 OTA，普通控制请求已暂停');
    }
    if (!appVersionCompatible && !(method == 'GET' && path == '/api/status')) {
      throw const DeviceBusyException('当前 App 版本不支持此设备固件，请先更新 App');
    }
    if (!isConnected ||
        attempt != _connectionAttempt ||
        device == null ||
        !identical(device, _device) ||
        command == null ||
        (!identical(command, _command) && !identical(command, _wifiCommand))) {
      throw Exception('请先连接 ${AppIdentity.productName}');
    }
    if (rawPacket != null && _legacyControlProtocol) {
      throw StateError('当前旧固件不支持 WiFi 配网协议');
    }
    final packet = rawPacket ??
        BleProtocol.encodeRequest(
          method: method,
          path: path,
          profile: query['profile'] ?? 'production',
          mode: query['mode'] ?? '',
          stage: query['stage'] ?? '',
          replace: query['replace'] == '1',
          switchProfile: query['switch'] == '1',
          body: body,
        );
    final requestId = _nextRequestId;
    _nextRequestId = _nextRequestId >= 0xFFFF ? 1 : _nextRequestId + 1;
    _activeRequestId = requestId;
    final packetBytes = _legacyControlProtocol
        ? utf8.encode(packet)
        : BleProtocol.frameRequest(requestId, packet);
    if (rawPacket != null && packetBytes.length >= 512) {
      throw StateError('WiFi 配网请求超过 BLE 特征值上限');
    }
    _responseChunks.clear();
    _decoder.reset();
    _legacyDecoder.reset();
    final pending = Completer<DeviceResponse>();
    // BLE 可能在 write 返回前断开；提前挂错误监听，避免响应 Future 暂时无人消费。
    unawaited(pending.future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    ));
    _pendingResponse = pending;
    final stopwatch = Stopwatch()..start();
    try {
      // Android 在上一条 GATT 操作刚完成时可能短暂返回 REQUEST_BUSY。
      // 该错误表示本次写入未入队，短暂退避后重试不会重复执行设备命令。
      await _writeCommandWithBusyRetry(
        command,
        packetBytes,
        allowLongWrite: rawPacket != null,
      );
      final expectedCommand = method == 'WIFI' ? _wifiCommand : _command;
      if (attempt != _connectionAttempt ||
          !identical(device, _device) ||
          !identical(command, expectedCommand)) {
        throw StateError('蓝牙会话已变化，请重新发起请求');
      }
      final response = await pending.future.timeout(const Duration(seconds: 6));
      _consecutiveRequestTimeouts = 0;
      stopwatch.stop();
      // 高频状态轮询默认交给 API 层记录状态变化摘要，避免每秒保存一整笔原始报文。
      // 用户可在设备日志页短时开启原始抓取，排查分包或协议异常。
      if (rawPacket == null &&
          (!_isRoutineStatusPoll(method, path) ||
              (diagnostics?.isCapturingStatusPolls ?? false))) {
        diagnostics?.info(
          'BLE 事务',
          '耗时=${stopwatch.elapsedMilliseconds}ms\n'
              'TX ${packetBytes.length}B requestId=$requestId ${_visibleText(packet)}\n'
              'RX ${_responseChunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}B '
              'chunks=${_responseChunks.length} mtu=$negotiatedMtu hex=${_formatChunks(_responseChunks)}\n'
              'HTTP ${response.statusCode}\n${response.body}',
        );
      }
      return response;
    } on TimeoutException {
      stopwatch.stop();
      if (rawPacket == null)
        diagnostics?.error(
          'BLE 超时',
          '耗时=${stopwatch.elapsedMilliseconds}ms\n'
              'TX ${packetBytes.length}B requestId=$requestId ${_visibleText(packet)}\n'
              'RX ${_responseChunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}B '
              'chunks=${_responseChunks.length} mtu=$negotiatedMtu hex=${_formatChunks(_responseChunks)}',
        );
      _consecutiveRequestTimeouts++;
      if (_consecutiveRequestTimeouts >= 3 &&
          !isOtaExclusive &&
          attempt == _connectionAttempt &&
          identical(device, _device)) {
        _pendingResponse = null;
        await disconnect();
      }
      throw Exception(_consecutiveRequestTimeouts >= 3 && !isOtaExclusive
          ? '蓝牙请求连续超时，已断开连接；请重新连接设备'
          : '蓝牙请求超时，请稍后重试');
    } catch (error, stackTrace) {
      stopwatch.stop();
      if (rawPacket == null)
        diagnostics?.error(
          'BLE 请求异常',
          '耗时=${stopwatch.elapsedMilliseconds}ms\n'
              'TX ${packetBytes.length}B requestId=$requestId ${_visibleText(packet)}\n'
              'RX ${_responseChunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}B '
              'chunks=${_responseChunks.length} mtu=$negotiatedMtu hex=${_formatChunks(_responseChunks)}\n'
              'error=$error',
          stackTrace: stackTrace,
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

  Future<void> _writeCommandWithBusyRetry(
    BluetoothCharacteristic command,
    List<int> bytes, {
    required bool allowLongWrite,
  }) async {
    const backoff = [120, 250, 500];
    for (var attempt = 0;; attempt++) {
      try {
        await _gattScheduler.run(() => command.write(
              bytes,
              withoutResponse: false,
              allowLongWrite: allowLongWrite,
            ));
        return;
      } catch (error) {
        final message = error.toString().toLowerCase();
        final isGattBusy = message.contains('gatt_write_request_busy');
        if (!isGattBusy || attempt >= backoff.length) rethrow;
        final delay = backoff[attempt];
        diagnostics?.warning(
          'BLE GATT',
          '设备暂忙，${delay}ms 后重试控制写入（${attempt + 1}/${backoff.length}）',
        );
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
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

  bool _looksLikeLegacyResponsePrefix(List<List<int>> chunks) {
    final bytes = chunks.expand((chunk) => chunk).toList(growable: false);
    final newline = bytes.indexOf(10);
    final statusLength = newline < 0 ? bytes.length : newline;
    if (statusLength < 1 || statusLength > 3) return false;
    return bytes
        .take(statusLength)
        .every((byte) => byte >= 0x30 && byte <= 0x39);
  }

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
    _wifiNotificationSubscription?.cancel();
    _connectionSubscription?.cancel();
    unawaited(_otaSubscription?.cancel());
    _otaEvents.close();
    super.dispose();
  }
}
