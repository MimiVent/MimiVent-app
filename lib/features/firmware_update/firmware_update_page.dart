import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/theme/mimivent_theme.dart';
import '../../transport/device_transport.dart';
import '../../transport/ota_capabilities.dart';
import 'ota_task_controller.dart';
import 'ota_package.dart';
import 'ota_delta_package.dart';
import 'ota_storage_compatibility.dart';
import 'ota_task_snapshot.dart';
import '../../shared/widgets/top_toast.dart';

/// BLE 固件升级界面。镜像只经由独立 OTA GATT 通道传输，不占用控制 RPC。
class FirmwareUpdatePage extends StatefulWidget {
  const FirmwareUpdatePage({required this.ble, super.key});

  final FirmwareUpdateTransport ble;

  @override
  State<FirmwareUpdatePage> createState() => _FirmwareUpdatePageState();
}

class _FirmwareUpdatePageState extends State<FirmwareUpdatePage>
    with WidgetsBindingObserver {
  static const _minimumFirmwareVersion = '0.7.0';
  final _versionController = TextEditingController();
  PlatformFile? _firmware;
  String? _otaPackagePath;
  int? _otaPackageLength;
  String? _otaPackageSha256;
  OtaDeltaPackage? _deltaPackage;
  String? _pendingFileSha256;
  int? _targetImageLength;
  bool _useFullFallback = false;
  String? _fullFallbackImagePath;
  String? _fullFallbackPackagePath;
  int? _fullFallbackPackageLength;
  String? _fullFallbackPackageSha256;
  String? _firmwareVersion;
  String? _firmwareSha256;
  String? _taskId;
  String? _currentFirmwareVersion;
  int? _currentStatisticsSchema;

  /// 升级成功后的常驻提示：展示设备实际运行的版本，直到用户关闭或离开页面。
  bool _upgradeSucceeded = false;
  String? _upgradeSucceededVersion;
  int? _firmwareStatisticsSchema;
  int? _firmwareMinimumReadableSchema;
  String? _firmwarePartitionProfile;
  String _status = '通过蓝牙连接设备后即可升级';
  String? _deviceStatus;
  String? _completedImageIdentity;
  String? _otaCapabilities;
  String? _deviceStableId;
  String? _taskDeviceStableId;
  int _sent = 0;
  int _transferTotal = 0;
  bool _working = false;
  bool _startInProgress = false;
  bool _abandonInProgress = false;
  bool _exitDialogOpen = false;
  bool _installCommandPending = false;
  // 同版本重装需用户确认一次；确认后本次流程内不再重复弹窗。
  bool _sameVersionConfirmed = false;
  bool _successNotified = false;
  bool _legacyProtocolActive = false;
  bool _backgroundPausePending = false;
  bool _statusRefreshInFlight = false;
  bool _statusRefreshPending = false;
  String? _lastQueriedDeviceId;
  Timer? _connectionRefreshTimer;
  DateTime? _transferStartedAt;

  /// 本次传输的起始字节数。续传时设备已确认的部分不计入速度，
  /// 否则 "恢复的字节 ÷ 刚过去的几十毫秒" 会算出荒谬的速度与剩余时间。
  int? _transferBaseBytes;
  DateTime? _lastProgressUpdate;
  double? _transferBytesPerSecond;
  Duration? _transferRemaining;
  late final OtaTaskController _taskController = OtaTaskController(widget.ble);

  OtaTaskSnapshot get _taskSnapshot =>
      OtaTaskSnapshot.parse(_deviceStatus ?? 'UNKNOWN');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.ble.addListener(_onBleConnectionChanged);
    unawaited(_restorePendingFirmware().then((_) {
      if (mounted && widget.ble.isConnected) unawaited(_refreshStatus());
    }));
    if (widget.ble.isConnected) _scheduleConnectionRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.ble.removeListener(_onBleConnectionChanged);
    _connectionRefreshTimer?.cancel();
    _versionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive 只表示暂时失去焦点（例如通知栏、系统弹窗或切换窗口），
    // 此时 App 仍可能正常运行，不能因此中断 OTA。Flutter 3.22 在真正
    // 隐藏页面时会先发 hidden，再发 paused；只在隐藏/退后台时安全暂停。
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_pauseBeforeBackground());
    } else if (state == AppLifecycleState.resumed && widget.ble.isConnected) {
      unawaited(_refreshStatus());
    }
  }

  Future<void> _pauseBeforeBackground() async {
    final taskId = _taskId;
    if (_backgroundPausePending ||
        !widget.ble.isOtaUploading ||
        taskId == null) {
      return;
    }
    _backgroundPausePending = true;
    try {
      if (_legacyProtocolActive) {
        await _taskController.pause(taskId: taskId, legacy: true);
      } else {
        await _taskController.pause(taskId: taskId, legacy: false);
      }
      if (mounted) {
        setState(() => _status = _legacyProtocolActive
            ? '旧协议不支持后台续传；已中止本次升级，重试时需重新上传'
            : 'App 已切到后台，设备确认暂停并保存可续传进度');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '后台暂停未确认；重连后将查询设备实际续传进度：$error');
      }
    } finally {
      _backgroundPausePending = false;
    }
  }

  Future<void> _refreshStatus() async {
    if (_statusRefreshInFlight) {
      _statusRefreshPending = true;
      return;
    }
    _statusRefreshInFlight = true;
    try {
      String capabilities;
      try {
        capabilities = await _taskController.queryCapabilities();
        _deviceStableId = _capabilityValue(capabilities, 'deviceId');
      } catch (error) {
        capabilities = 'UNKNOWN|$error';
      }
      String? firmwareVersion;
      int? statisticsSchema;
      final pendingTask = await _taskController.loadPendingFirmware();
      final installationRequested = pendingTask?.installRequested ?? false;
      final legacyProtocolPending = pendingTask?.legacyProtocol ?? false;
      final legacyRemoteId = pendingTask?.legacyRemoteId;
      final isLegacyDevice = capabilities.startsWith('ERROR|COMMAND');
      final lacksOtaEndpoint = capabilities == 'ERROR|USB_BOOTSTRAP_REQUIRED' ||
          capabilities == 'ERROR|OTA_CHANNEL_MISSING';
      final status = lacksOtaEndpoint
          ? 'UNSUPPORTED'
          : (await _taskController.refresh(legacy: isLegacyDevice)).raw;
      _installCommandPending = installationRequested;
      String? runningImageInfo;
      if (installationRequested &&
          legacyProtocolPending &&
          status.startsWith('IDLE') &&
          legacyRemoteId == widget.ble.connectedDeviceId) {
        try {
          runningImageInfo = await _taskController.queryDeviceInfo();
        } catch (_) {
          // 老固件可能不支持 INFO；这种情况下不能仅凭版本号认定已完成。
        }
      }
      try {
        final response = await widget.ble
            .send(const DeviceRequest(method: 'GET', path: '/api/status'));
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          firmwareVersion = decoded['firmware'] as String?;
          // statisticsSchema 是给旧 App 的兼容值（固定 4）；OTA 安装门槛必须比对
          // 真实落盘格式 storageSchema，否则永远与包内 marker 5 不相等而阻止升级。
          statisticsSchema = (decoded['storageSchema'] as int?) ??
              (decoded['statisticsSchema'] as int?);
        }
      } catch (_) {
        // OTA 状态仍可读时保留页面入口；未知版本不允许执行无法核实的降级。
      }
      if (!mounted) return;
      var clearCompletedSelection = false;
      var completedNow = false;
      setState(() {
        _deviceStatus = status;
        _otaCapabilities = capabilities;
        _currentFirmwareVersion = firmwareVersion;
        _currentStatisticsSchema = statisticsSchema;
        if (status.startsWith('ERROR|BOOT_ROLLBACK|')) {
          _installCommandPending = false;
          unawaited(_taskController.clearInstallIntent());
          final fields = status.split('|');
          _status = '设备已回滚至旧固件，拒绝镜像仍被记录。'
              '${fields.length > 3 ? '目标版本 ${fields[3]} 未能启动；可放弃该任务后重试其他签名固件。' : ''}';
        } else if (status.startsWith('INSTALLED|')) {
          final fields = status.split('|');
          final installedIdentity = fields.length > 4
              ? '${fields[1]}|${fields[2].toLowerCase()}|${fields[4]}'
              : null;
          final selectedMatches = fields.length > 4 &&
              fields[1] == _firmwareVersion &&
              fields[2].toLowerCase() == _firmwareSha256?.toLowerCase();
          final sameIdentity = fields.length > 4 &&
              fields[1] == firmwareVersion &&
              fields[4] == _deviceStableId &&
              (selectedMatches ||
                  (_firmware == null &&
                      installedIdentity == _completedImageIdentity));
          _status = sameIdentity
              ? '已重连核验设备版本与固件身份，升级完成'
              : '设备报告已安装 ${fields.length > 1 ? fields[1] : '目标固件'}；等待选择原固件身份以完成核验';
          if (sameIdentity) {
            _installCommandPending = false;
            _completedImageIdentity = installedIdentity;
            clearCompletedSelection = _firmware != null;
            completedNow = true;
          }
        } else if (lacksOtaEndpoint) {
          _status = capabilities == 'ERROR|USB_BOOTSTRAP_REQUIRED'
              ? '当前固件没有 OTA 蓝牙通道。首次升级需通过 USB 刷入支持 OTA V2 的固件；完成首刷后可使用 App 无线升级。'
              : '当前设备未提供完整 OTA 蓝牙通道，请检查固件版本或设备连接。';
        } else if (installationRequested) {
          final taskSnapshot = OtaTaskSnapshot.parse(status);
          final legacyVerified = legacyProtocolPending &&
              status != 'DONE' &&
              status.startsWith('IDLE') &&
              _firmwareSha256 != null &&
              _deviceStableId != null &&
              matchesInstalledImageInfo(
                response: runningImageInfo,
                targetVersion: _firmwareVersion ?? '',
                targetSha256: _firmwareSha256!,
                deviceStableId: _deviceStableId!,
              ) &&
              legacyRemoteId == widget.ble.connectedDeviceId;
          if (legacyVerified) {
            _status = '旧协议升级后已重连核验运行版本与固件 SHA-256，升级完成';
            _installCommandPending = false;
            clearCompletedSelection = _firmware != null;
            completedNow = true;
          } else if (taskSnapshot.phase == OtaTaskPhase.installing) {
            _status = '设备已提交安装，正在启动目标固件；重连核验中';
          } else {
            _status = '安装结果待确认；请重连后查询设备状态，暂勿重新上传';
          }
        } else {
          final phase = OtaTaskSnapshot.parse(status).phase;
          _status = phase == OtaTaskPhase.idle || phase == OtaTaskPhase.ready
              ? '蓝牙会话已就绪，可以选择固件'
              : phase == OtaTaskPhase.installing
                  ? '设备正在安装并重启，重连后核验固件身份'
                  : '设备升级任务：$status';
        }
      });
      if (clearCompletedSelection) {
        await _clearSelectedFirmware(afterSuccessfulInstall: true);
      }
      if (completedNow && !_successNotified) {
        _successNotified = true;
        final running = firmwareVersion ?? _firmwareVersion ?? '未知';
        if (mounted) {
          setState(() {
            _upgradeSucceeded = true;
            _upgradeSucceededVersion = running;
          });
          TopToast.show(context, '固件升级成功 · 当前运行 v$running');
        }
        await _clearInstalledRecordAfterSuccess();
      }
    } catch (error) {
      if (mounted) setState(() => _status = '读取设备状态失败：$error');
    } finally {
      _statusRefreshInFlight = false;
      if (_statusRefreshPending && mounted) {
        _statusRefreshPending = false;
        unawaited(_refreshStatus());
      }
    }
  }

  Future<void> _clearInstalledRecordAfterSuccess() async {
    final taskId = _taskSnapshot.taskId ?? _taskId;
    if (taskId == null) return;
    try {
      await _taskController.abandon(taskId: taskId);
      _taskId = _createTaskId();
      await _taskController.saveTaskId(_taskId!);
      await _taskController.clearInstallIntent();
      _installCommandPending = false;
      if (mounted) {
        setState(() {
          _deviceStatus = 'IDLE';
          _status = '升级成功，已清除设备升级记录';
        });
      }
    } catch (_) {
      // 记录清除失败不影响已经确认成功的升级；保留手动清除入口。
    }
  }

  void _onBleConnectionChanged() {
    if (!widget.ble.isConnected) {
      _connectionRefreshTimer?.cancel();
      _connectionRefreshTimer = null;
      _lastQueriedDeviceId = null;
      return;
    }
    _scheduleConnectionRefresh();
  }

  void _scheduleConnectionRefresh() {
    final deviceId = widget.ble.connectedDeviceId;
    if (deviceId == null || deviceId == _lastQueriedDeviceId) return;
    _connectionRefreshTimer?.cancel();
    _connectionRefreshTimer = Timer(const Duration(milliseconds: 300), () {
      _connectionRefreshTimer = null;
      if (!mounted ||
          !widget.ble.isConnected ||
          widget.ble.connectedDeviceId != deviceId) return;
      _lastQueriedDeviceId = deviceId;
      unawaited(_refreshStatus());
    });
  }

  Future<void> _pickFirmware() async {
    FilePickerResult? result;
    try {
      // Android 系统文件选择器不支持 mvota/mvdelta 自定义 MIME 过滤；
      // 先打开所有文件，再由下方扩展名和包格式校验筛选。
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '无法打开文件选择器：$error');
      return;
    }
    if (!mounted || result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final extension = file.extension?.toLowerCase();
    if (extension != 'mvota' && extension != 'mvdelta') {
      setState(() => _status = '文件类型不支持：只能选择 .mvota 或 .mvdelta 固件包');
      return;
    }
    if (file.bytes == null || file.bytes!.isEmpty) {
      setState(() => _status = '无法读取固件文件，请重新选择');
      return;
    }
    final bytes = file.bytes!;
    final isDelta = extension == 'mvdelta';
    final isSignedPackage = extension == 'mvota';
    OtaDeltaPackage? delta;
    OtaPackage? otaPackage;
    var imageBytes = bytes;
    String? version;
    int? statisticsSchema;
    int? minimumReadableSchema;
    String? partitionProfile;
    String imageDigest;
    int targetImageLength;
    if (isDelta) {
      try {
        delta = OtaDeltaPackage.parse(bytes);
      } catch (error) {
        setState(() => _status = '差分包无效：$error');
        return;
      }
      version = delta.targetVersion;
      statisticsSchema = delta.statisticsSchema;
      minimumReadableSchema = delta.minReadableStorageSchema;
      partitionProfile = delta.partitionProfile;
      imageDigest = delta.targetSha256;
      targetImageLength = delta.targetLength;
    } else {
      if (!isSignedPackage) {
        setState(
            () => _status = '请选择 OTA v2 的 .mvota 或 .mvdelta 包；原始 .bin 不接受无线安装');
        return;
      }
      try {
        otaPackage = OtaPackage.parseContainer(bytes);
      } catch (error) {
        setState(() => _status = 'OTA 包格式无效：$error');
        return;
      }
      imageBytes = otaPackage.decodedImage;
      final chipId =
          imageBytes.length >= 14 ? imageBytes[12] | (imageBytes[13] << 8) : -1;
      final binaryText = latin1.decode(imageBytes, allowInvalid: true);
      version = RegExp(r'MIMIVENT_FIRMWARE_VERSION=(\d+\.\d+\.\d+)')
          .firstMatch(binaryText)
          ?.group(1);
      statisticsSchema = int.tryParse(
        RegExp(r'MIMIVENT_STATISTICS_SCHEMA=(\d+)')
                .firstMatch(binaryText)
                ?.group(1) ??
            '',
      );
      partitionProfile = RegExp(r'MIMIVENT_PARTITION_PROFILE=([A-Za-z0-9_-]+)')
          .firstMatch(binaryText)
          ?.group(1);
      minimumReadableSchema = int.tryParse(
        RegExp(r'MIMIVENT_MIN_READABLE_STORAGE_SCHEMA=(\d+)')
                .firstMatch(binaryText)
                ?.group(1) ??
            '',
      );
      if (imageBytes.isEmpty ||
          imageBytes.first != 0xE9 ||
          chipId != 5 ||
          version == null ||
          otaPackage.version != version ||
          otaPackage.partitionProfile != partitionProfile) {
        setState(() => _status = '所选文件不是可识别的 MimiVent ESP32-C3 固件');
        return;
      }
      imageDigest = otaPackage.imageSha256;
      targetImageLength = imageBytes.length;
    }
    if (_compareVersions(version, _minimumFirmwareVersion) < 0) {
      setState(() => _status =
          '目标固件 v$version 低于当前 App 最低支持版本 v$_minimumFirmwareVersion，已阻止安装');
      return;
    }
    final currentSchema = _currentStatisticsSchema;
    if (!canReadStorageSchema(
      deviceSchema: currentSchema,
      targetSchema: statisticsSchema,
      minimumReadableSchema: minimumReadableSchema,
    )) {
      setState(() => _status = '目标固件无法确认兼容当前统计格式 $currentSchema，已阻止安装。'
          '目标可读范围：${minimumReadableSchema ?? statisticsSchema}–$statisticsSchema；请使用兼容固件。');
      return;
    }
    final fileDigest = sha256.convert(bytes).toString();
    String? taskId;
    String? firmwarePath;
    String? packagePath;
    String? fallbackImagePath;
    String? fallbackPackagePath;
    int? fallbackPackageLength;
    String? fallbackPackageSha256;
    try {
      final directory = await getApplicationSupportDirectory();
      final extension = isDelta ? 'mvdelta' : 'mvota';
      firmwarePath = '${directory.path}/pending-ota-$fileDigest.$extension';
      await File(firmwarePath).writeAsBytes(bytes, flush: true);
      if (isSignedPackage) {
        packagePath = firmwarePath;
      }
      if (isDelta && file.path != null && partitionProfile != null) {
        final siblingImage = File(
          '${File(file.path!).parent.path}/${file.name.replaceFirst(RegExp(r'\.mvdelta$', caseSensitive: false), '.mvota')}',
        );
        if (await siblingImage.exists()) {
          try {
            final fallbackBytes = await siblingImage.readAsBytes();
            final signedPackage = OtaPackage.parseContainer(fallbackBytes);
            if (signedPackage.imageSha256 == imageDigest) {
              fallbackPackagePath =
                  '${directory.path}/pending-firmware-$imageDigest.mvota';
              await File(fallbackPackagePath)
                  .writeAsBytes(fallbackBytes, flush: true);
              fallbackImagePath = fallbackPackagePath;
              fallbackPackageLength = fallbackBytes.length;
              fallbackPackageSha256 = signedPackage.packageSha256;
            }
          } catch (_) {
            // 不存在结构有效的完整包时，仅保留差分上传。
          }
        }
      }
      final pendingTask = await _taskController.loadPendingFirmware();
      taskId = pendingTask?.sha256 == fileDigest
          ? pendingTask!.taskId
          : List<int>.generate(16, (_) => Random.secure().nextInt(256))
              .map((value) => value.toRadixString(16).padLeft(2, '0'))
              .join();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '无法保存固件升级任务：$error');
      return;
    }
    if (!mounted) return;
    setState(() {
      _firmware =
          PlatformFile(name: file.name, size: file.size, path: firmwarePath);
      _pendingFileSha256 = fileDigest;
      _targetImageLength = targetImageLength;
      _deltaPackage = delta;
      _useFullFallback = false;
      _fullFallbackImagePath = fallbackImagePath;
      _fullFallbackPackagePath = fallbackPackagePath;
      _fullFallbackPackageLength = fallbackPackageLength;
      _fullFallbackPackageSha256 = fallbackPackageSha256;
      _otaPackagePath = packagePath;
      _otaPackageLength = isDelta ? file.size : otaPackage?.bytes.length;
      _otaPackageSha256 = isDelta ? fileDigest : otaPackage?.packageSha256;
      _firmwareVersion = version;
      _firmwareStatisticsSchema = statisticsSchema;
      _firmwareMinimumReadableSchema = minimumReadableSchema;
      _firmwarePartitionProfile = partitionProfile;
      _firmwareSha256 = imageDigest;
      _taskId = taskId;
      _versionController.text = version!;
      _status = isDelta
          ? '差分包结构检查通过 v${delta!.baseVersion} → v$version；设备将验证目标镜像签名'
          : '固件包结构检查通过 v$version；设备将在安装前验证发布者签名';
    });
  }

  Future<void> _clearSelectedFirmware(
      {bool afterSuccessfulInstall = false}) async {
    if ((!afterSuccessfulInstall && _working) || _firmware == null) return;
    final successStatus = _status;
    final cachedPaths = {
      _firmware!.path,
      _otaPackagePath,
      _fullFallbackImagePath,
      _fullFallbackPackagePath,
    }.whereType<String>().toSet();
    try {
      await _taskController.clearPendingFirmware();
      for (final path in cachedPaths) {
        final cachedFile = File(path);
        if (await cachedFile.exists()) await cachedFile.delete();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '清除所选固件失败：$error');
      return;
    }
    if (!mounted) return;
    setState(() {
      _firmware = null;
      _otaPackagePath = null;
      _otaPackageLength = null;
      _otaPackageSha256 = null;
      _deltaPackage = null;
      _pendingFileSha256 = null;
      _targetImageLength = null;
      _useFullFallback = false;
      _fullFallbackImagePath = null;
      _fullFallbackPackagePath = null;
      _fullFallbackPackageLength = null;
      _fullFallbackPackageSha256 = null;
      _firmwareVersion = null;
      _firmwareSha256 = null;
      _taskId = null;
      _firmwareStatisticsSchema = null;
      _firmwarePartitionProfile = null;
      _versionController.clear();
      _sent = 0;
      _transferTotal = 0;
      _taskDeviceStableId = null;
      _transferBytesPerSecond = null;
      _transferRemaining = null;
      _transferStartedAt = null;
      _status = afterSuccessfulInstall
          ? '$successStatus；已清空所选文件'
          : '已移除所选文件，可重新选择固件包';
    });
  }

  Future<void> _restorePendingFirmware() async {
    try {
      final pendingTask = await _taskController.loadPendingFirmware();
      if (pendingTask == null) return;
      _taskDeviceStableId = pendingTask.deviceStableId;
      _installCommandPending = pendingTask.installRequested;
      final file = File(pendingTask.path);
      if (!await file.exists()) {
        if (mounted) setState(() => _status = '上次升级固件文件已不存在，请重新选择');
        return;
      }
      final length = await file.length();
      final digest = await sha256.bind(file.openRead()).first;
      if (length != pendingTask.length ||
          digest.toString() != pendingTask.sha256) {
        if (mounted) setState(() => _status = '本地升级文件校验失败，请重新选择固件');
        return;
      }
      if (!mounted) return;
      final imageBytes = await file.readAsBytes();
      if (file.path.endsWith('.mvdelta')) {
        final delta = OtaDeltaPackage.parse(imageBytes);
        final fallbackImage = File(
            '${file.parent.path}/pending-firmware-${delta.targetSha256}.mvota');
        String? fallbackImagePath;
        String? fallbackPackagePath;
        int? fallbackPackageLength;
        String? fallbackPackageSha256;
        if (await fallbackImage.exists()) {
          try {
            final package =
                OtaPackage.parseContainer(await fallbackImage.readAsBytes());
            if (package.imageSha256 == delta.targetSha256) {
              fallbackImagePath = fallbackImage.path;
              fallbackPackagePath = fallbackImage.path;
              fallbackPackageLength = package.bytes.length;
              fallbackPackageSha256 = package.packageSha256;
            }
          } catch (_) {
            // 无结构有效的完整包时，继续保留差分升级入口。
          }
        }
        setState(() {
          _firmware = PlatformFile(
              name: pendingTask.name, size: length, path: pendingTask.path);
          _pendingFileSha256 = pendingTask.sha256;
          _targetImageLength = delta.targetLength;
          _deltaPackage = delta;
          _useFullFallback = false;
          _fullFallbackImagePath = fallbackImagePath;
          _fullFallbackPackagePath = fallbackPackagePath;
          _fullFallbackPackageLength = fallbackPackageLength;
          _fullFallbackPackageSha256 = fallbackPackageSha256;
          _firmwareVersion = delta.targetVersion;
          _firmwareStatisticsSchema = delta.statisticsSchema;
          _firmwareMinimumReadableSchema = delta.minReadableStorageSchema;
          _firmwarePartitionProfile = delta.partitionProfile;
          _firmwareSha256 = delta.targetSha256;
          _taskId = pendingTask.taskId;
          _versionController.text = pendingTask.version;
          _otaPackagePath = pendingTask.path;
          _otaPackageLength = length;
          _otaPackageSha256 = pendingTask.sha256;
          _status = '已恢复待处理差分包 v${delta.targetVersion}；设备将在安装前验证发布者签名';
        });
        return;
      }
      final otaPackage = OtaPackage.parseContainer(imageBytes);
      final firmwareImage = otaPackage.decodedImage;
      final binaryText = latin1.decode(firmwareImage, allowInvalid: true);
      final partitionProfile =
          RegExp(r'MIMIVENT_PARTITION_PROFILE=([A-Za-z0-9_-]+)')
              .firstMatch(binaryText)
              ?.group(1);
      final packagePath = file.path;
      if (otaPackage.version != pendingTask.version ||
          otaPackage.partitionProfile != partitionProfile) {
        throw const FormatException('待恢复 OTA 包身份不匹配');
      }
      setState(() {
        _firmware = PlatformFile(
            name: pendingTask.name, size: length, path: pendingTask.path);
        _pendingFileSha256 = pendingTask.sha256;
        _targetImageLength = otaPackage.imageLength;
        _deltaPackage = null;
        _otaPackagePath = packagePath;
        _otaPackageLength = otaPackage.bytes.length;
        _otaPackageSha256 = otaPackage.packageSha256;
        _firmwareVersion = pendingTask.version;
        _firmwareStatisticsSchema = pendingTask.statisticsSchema;
        _firmwareMinimumReadableSchema = int.tryParse(
          RegExp(r'MIMIVENT_MIN_READABLE_STORAGE_SCHEMA=(\d+)')
                  .firstMatch(binaryText)
                  ?.group(1) ??
              '',
        );
        _firmwarePartitionProfile = partitionProfile;
        _firmwareSha256 = otaPackage.imageSha256;
        _taskId = pendingTask.taskId;
        _versionController.text = pendingTask.version;
        _status = '已恢复待处理固件包 v${pendingTask.version}；设备将在安装前验证发布者签名';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '恢复本地升级任务失败：$error');
    }
  }

  Future<void> _startUpdate() async {
    if (_startInProgress || _working) return;
    _startInProgress = true;
    try {
      await _startUpdateOnce();
    } finally {
      _startInProgress = false;
    }
  }

  /// 设备已经是目标版本时直接拦下：安装成功后设备会重启，
  /// 再点一次或界面误触会重跑一遍完整上传（2 分钟），没有任何收益。
  bool _isAlreadyRunningTarget() {
    final target = _firmwareVersion;
    final running = _currentFirmwareVersion;
    if (target == null || running == null) return false;
    return _compareVersions(target, running) == 0;
  }

  Future<void> _startUpdateOnce() async {
    // 安装指令已交给设备、正在等它重启：此时任何重传都会覆盖同一个 slot，
    // 白白花两分钟且可能打断安装。
    if (_installCommandPending) {
      if (mounted) {
        setState(() => _status = '安装指令已发送，正在等待设备重启；请勿重复上传');
      }
      return;
    }
    if (_isAlreadyRunningTarget() && !_sameVersionConfirmed) {
      // 同版本不再硬拦：重装是合法的调试与恢复手段（例如固件参数调整后
      // 需要重新写同一版本号）。改为一次确认，确认后本次流程放行。
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重装同一版本'),
          content: Text('设备当前已是 v$_firmwareVersion。重装会覆盖当前固件并重启设备，'
              '耗时约 1–3 分钟。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仍要重装'),
            ),
          ],
        ),
      );
      if (proceed != true) {
        if (mounted) {
          setState(() => _status = '已取消：设备已是 v$_firmwareVersion');
        }
        return;
      }
      _sameVersionConfirmed = true;
    }
    _successNotified = false;
    final firmware = _firmware;
    final path = firmware?.path;
    final imageDigest = _firmwareSha256;
    final version = _versionController.text.trim();
    if (firmware == null || path == null || imageDigest == null) {
      setState(() => _status = '请先选择 .mvota 或 .mvdelta OTA 包');
      return;
    }
    if (_firmwareVersion == null || version != _firmwareVersion) {
      setState(() => _status = '固件版本识别失败，请重新选择固件文件');
      return;
    }
    String capabilities;
    try {
      capabilities = await _taskController.queryCapabilities();
    } catch (error) {
      if (mounted) setState(() => _status = '读取设备 OTA 能力失败：$error');
      return;
    }
    if (!mounted) return;
    if (capabilities == 'ERROR|USB_BOOTSTRAP_REQUIRED') {
      setState(() => _status =
          '当前设备固件没有 OTA 蓝牙通道，App 无法通过旧协议上传固件。请先通过 USB 刷入支持 OTA V2 的固件，之后即可使用 App 无线升级。');
      return;
    }
    if (capabilities == 'ERROR|OTA_CHANNEL_MISSING') {
      setState(() => _status = '当前设备未提供完整 OTA 蓝牙通道，请检查固件版本或设备连接。');
      return;
    }
    final legacyProtocol = capabilities.startsWith('ERROR|COMMAND');
    if (legacyProtocol) {
      setState(() => _status = '固件签名验证需要 OTA V2 设备协议；请先通过 USB 刷入支持签名验证的固件');
      return;
    }
    final otaCapabilities = OtaCapabilities.parse(capabilities);
    if (!otaCapabilities.supportsRequiredV2) {
      setState(() => _status = '设备未声明支持签名 OTA 包（格式 v2），为避免安装未验证固件已停止');
      return;
    }
    var useDelta = _deltaPackage != null;
    if (useDelta && (legacyProtocol || !otaCapabilities.supportsDeltaV2)) {
      if (_fullFallbackImagePath == null) {
        setState(() => _status = '设备不支持差分 OTA，且未找到匹配的完整签名 .mvota；请选择完整固件包');
        return;
      }
      _useFullFallback = true;
      useDelta = false;
    }
    if (useDelta) {
      try {
        final info = (await _taskController.queryDeviceInfo()).split('|');
        final delta = _deltaPackage!;
        final matches = info.length >= 7 &&
            info[0] == 'INFO' &&
            info[1] == delta.baseVersion &&
            int.tryParse(info[2]) == delta.baseLength &&
            info[3].toLowerCase() == delta.baseSha256.toLowerCase() &&
            info[4] == delta.partitionProfile &&
            info[6] == _deviceStableId;
        if (!matches) {
          if (_fullFallbackImagePath == null) {
            setState(() => _status = '差分包基线与设备当前固件不匹配；请选择完整固件升级');
            return;
          }
          _useFullFallback = true;
          useDelta = false;
        }
      } catch (error) {
        if (_fullFallbackImagePath == null) {
          setState(() => _status = '无法读取设备当前固件身份，不能安全应用差分包：$error');
          return;
        }
        _useFullFallback = true;
        useDelta = false;
      }
    }
    final compressedPackage =
        !useDelta && otaCapabilities['packageFormat'] == '2';
    final uploadPath =
        useDelta ? path : (_useFullFallback ? _fullFallbackPackagePath! : path);
    final packagePath = useDelta
        ? path
        : (_useFullFallback ? _fullFallbackPackagePath : _otaPackagePath);
    final packageLength = useDelta
        ? firmware.size
        : (_useFullFallback ? _fullFallbackPackageLength : _otaPackageLength);
    final packageDigest = useDelta
        ? _pendingFileSha256
        : (_useFullFallback ? _fullFallbackPackageSha256 : _otaPackageSha256);
    final uploadImageLength =
        useDelta ? _deltaPackage!.targetLength : _targetImageLength!;
    if (compressedPackage &&
        (packagePath == null ||
            packageLength == null ||
            packageDigest == null)) {
      setState(() => _status = '无法生成 OTA V2 分块压缩包，请重新选择固件');
      return;
    }
    if (!capabilities.startsWith('CAPS|2|') && !legacyProtocol) {
      setState(() => _status = '无法确认设备 OTA 能力，已阻止上传：$capabilities');
      return;
    }
    if (legacyProtocol && _firmwarePartitionProfile != 'min-spiffs-ota-v1') {
      setState(() => _status =
          '该固件未声明与旧设备分区兼容，旧协议无法安全迁移分区表。请先通过 USB 刷入一次；之后设备可使用 OTA V2 升级。');
      return;
    }
    if (!legacyProtocol && !_supportsRequiredOtaV2(capabilities)) {
      setState(
          () => _status = '设备声明的 OTA V2 能力不完整，缺少安全续传、暂停、独立安装或有效分块参数，已阻止上传');
      return;
    }
    if (!legacyProtocol &&
        _firmwarePartitionProfile !=
            _capabilityValue(capabilities, 'partitionProfile')) {
      setState(() => _status = '固件分区配置与设备分区配置不一致，已阻止上传');
      return;
    }
    _deviceStableId = _capabilityValue(capabilities, 'deviceId');
    final pendingTask = await _taskController.loadPendingFirmware();
    _taskDeviceStableId = pendingTask?.deviceStableId;
    String deviceStatus;
    try {
      deviceStatus =
          (await _taskController.refresh(legacy: legacyProtocol)).raw;
    } catch (error) {
      if (mounted) setState(() => _status = '读取设备升级任务失败：$error');
      return;
    }
    if (!mounted) return;
    if (legacyProtocol) {
      final currentVersion = _currentFirmwareVersion;
      if (currentVersion == null) {
        setState(() => _status = '无法读取设备当前固件版本，不能安全使用旧协议升级');
        return;
      }
      if (_compareVersions(version, currentVersion) <= 0) {
        setState(() => _status = '旧协议只允许安装更高版本；同版本重装和降级需要 OTA V2');
        return;
      }
      if (!deviceStatus.startsWith('READY')) {
        setState(() => _status = '旧协议设备状态不允许开始升级：$deviceStatus');
        return;
      }
    }
    var verifiedAlready = deviceStatus.startsWith('VERIFIED|');
    if (!legacyProtocol && deviceStatus.startsWith('INSTALLED|')) {
      final fields = deviceStatus.split('|');
      if (fields.length > 2 &&
          fields[1] == version &&
          fields[2].toLowerCase() == imageDigest.toLowerCase() &&
          _currentFirmwareVersion == version &&
          fields.length > 4 &&
          fields[4] == _deviceStableId) {
        setState(() => _status = '设备已安装相同版本和固件，无需再次上传');
        return;
      }
      setState(() => _status = '设备当前保留另一固件的安装记录，请先核验或放弃该记录');
      return;
    }
    if (!legacyProtocol && deviceStatus.startsWith('PAUSED|')) {
      final fields = deviceStatus.split('|');
      final sameImage = fields.length >= 6 &&
          fields[2] ==
              '${(compressedPackage || useDelta) ? packageLength : (_useFullFallback ? _targetImageLength : firmware.size)}' &&
          fields[3] == version &&
          fields[4].toLowerCase() == imageDigest.toLowerCase() &&
          fields.length >= 7 &&
          fields[6] == _deviceStableId &&
          (!(compressedPackage || useDelta) ||
              (fields.length >= 8 &&
                  fields[7].toLowerCase() == packageDigest!.toLowerCase()));
      if (sameImage) {
        final deviceTaskId = fields[5];
        if (deviceTaskId.isNotEmpty && deviceTaskId != _taskId) {
          _taskId = deviceTaskId;
        }
      } else {
        final sameVersion = fields.length >= 4 && fields[3] == version;
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('替换未完成的升级任务？'),
            content: Text(sameVersion
                ? '设备中的 v$version 文件与当前选择的 SHA-256 不同。放弃旧任务后才能上传新文件。'
                : '设备仍保留 v${fields.length > 3 ? fields[3] : '未知'} 的未完成任务。放弃旧任务后才能上传 v$version。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('保留旧任务')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('放弃并替换')),
            ],
          ),
        );
        if (replace != true || !mounted) return;
        final remoteTaskId = fields.length > 5 ? fields[5] : _taskId!;
        await _taskController.abandon(taskId: remoteTaskId);
        deviceStatus = 'IDLE';
        _taskId = _createTaskId();
      }
    }
    if (!legacyProtocol && verifiedAlready) {
      final fields = deviceStatus.split('|');
      final sameImage = fields.length >= 5 &&
          fields[1] == version &&
          fields[2].toLowerCase() == imageDigest.toLowerCase() &&
          fields[4] == _deviceStableId;
      if (sameImage) {
        if (fields.length > 3) _taskId = fields[3];
      } else {
        if (!mounted) return;
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('替换待安装固件？'),
            content: const Text('设备中已校验通过的固件与当前选择文件不同。放弃待安装任务后才能上传新文件。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('保留待安装任务')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('放弃并替换')),
            ],
          ),
        );
        if (replace != true || !mounted) return;
        final remoteTaskId = fields.length > 3 ? fields[3] : _taskId!;
        await _taskController.abandon(taskId: remoteTaskId);
        deviceStatus = 'IDLE';
        verifiedAlready = false;
        _taskId = _createTaskId();
      }
    }
    if (!legacyProtocol &&
        _taskDeviceStableId != null &&
        _taskDeviceStableId != _deviceStableId &&
        (deviceStatus == 'IDLE' || deviceStatus.startsWith('READY'))) {
      _taskId = _createTaskId();
    }
    if (!legacyProtocol && deviceStatus.startsWith('UPLOADING|')) {
      setState(() => _status = '设备仍在处理升级任务，请稍后重新查询');
      return;
    }
    if (!legacyProtocol &&
        !verifiedAlready &&
        !deviceStatus.startsWith('PAUSED|') &&
        deviceStatus != 'IDLE' &&
        !deviceStatus.startsWith('READY')) {
      setState(() => _status = '设备当前状态不允许开始上传：$deviceStatus');
      return;
    }
    final currentVersion = _currentFirmwareVersion;
    if (currentVersion == null) {
      setState(() => _status = '无法读取设备当前固件版本，请刷新设备状态后再试');
      return;
    }
    final isDowngrade = _compareVersions(version, currentVersion) < 0;
    if (isDowngrade &&
        !legacyProtocol &&
        _capabilityValue(capabilities, 'downgrade') != '1') {
      setState(() => _status = '设备未声明支持降级，已阻止安装');
      return;
    }
    if (!canReadStorageSchema(
      deviceSchema: _currentStatisticsSchema,
      targetSchema: _firmwareStatisticsSchema,
      minimumReadableSchema: _firmwareMinimumReadableSchema,
    )) {
      setState(() => _status = '目标固件无法读取设备当前统计格式，已阻止安装');
      return;
    }
    if (!mounted) return;
    final confirmed = verifiedAlready
        ? true
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(isDowngrade ? '确认降级？' : '确认上传固件？'),
              content: Text(
                  '当前 v$currentVersion，目标 v$version（${_formatBytes(firmware.size)}）。'
                  '${isDowngrade ? '目标版本不低于 App 最低支持版本 v$_minimumFirmwareVersion，且统计数据格式 ${_firmwareStatisticsSchema ?? '未知'} 与设备格式 ${_currentStatisticsSchema ?? '未知'} 一致。' : ''}'
                  '${legacyProtocol ? '设备仅支持旧协议，上传校验通过后会立即安装并重启；不支持暂停、续传或安装前二次确认。' : '本步骤只上传并校验，校验通过后还会再次确认安装。'}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('继续上传'),
                ),
              ],
            ),
          );
    if (confirmed != true || !mounted) return;
    await _taskController.saveFirmware(
      path: uploadPath,
      name: firmware.name,
      taskId: _taskId!,
      version: version,
      sha256: packageDigest!,
      length: packageLength!,
      statisticsSchema: _firmwareStatisticsSchema,
    );
    if (!legacyProtocol && _deviceStableId != null) {
      await _taskController.bindDevice(_deviceStableId);
      _taskDeviceStableId = _deviceStableId;
    }
    setState(() {
      _working = true;
      _legacyProtocolActive = legacyProtocol;
      _sent = 0;
      _transferTotal = (compressedPackage || useDelta)
          ? packageLength
          : (_useFullFallback
              ? _fullFallbackPackageLength ?? _targetImageLength!
              : firmware.size);
      _transferStartedAt = DateTime.now();
      _transferBaseBytes = null;
      _lastProgressUpdate = null;
      _transferBytesPerSecond = null;
      _transferRemaining = null;
      _status = '正在校验并传输固件，请保持手机靠近设备';
    });
    try {
      if (verifiedAlready) {
        final fields = deviceStatus.split('|');
        final installedCandidateDigest = fields.length > 2 ? fields[2] : '';
        if (fields.length < 3 ||
            fields[1] != version ||
            installedCandidateDigest.toLowerCase() != imageDigest) {
          throw StateError('设备待安装任务与当前固件文件不匹配');
        }
      } else {
        final outcome = await _taskController.upload(
          deviceId: widget.ble.connectedDeviceId!,
          taskId: _taskId!,
          firmwareVersion: version,
          imageLength: uploadImageLength,
          sha256: imageDigest,
          packageLength: (compressedPackage || useDelta)
              ? packageLength
              : uploadImageLength,
          packageSha256:
              (compressedPackage || useDelta) ? packageDigest : imageDigest,
          compressedPackage: compressedPackage,
          deltaPackage: useDelta,
          baseVersion: useDelta ? _deltaPackage!.baseVersion : '',
          baseImageLength: useDelta ? _deltaPackage!.baseLength : 0,
          baseSha256: useDelta ? _deltaPackage!.baseSha256 : '',
          allowDowngrade: isDowngrade,
          legacy: legacyProtocol,
          onStage: (stage) {
            if (!mounted) return;
            setState(() => _status = stage == OtaTransferStage.verifying
                ? '数据已上传，设备正在校验固件'
                : '正在上传固件，请保持手机靠近设备');
          },
          onLegacyInstallCommit: legacyProtocol
              ? () async {
                  await _taskController.markInstallRequested(
                    legacyProtocol: true,
                    legacyRemoteId: widget.ble.connectedDeviceId ?? '',
                  );
                  _installCommandPending = true;
                }
              : null,
          image: (offset, maxLength) =>
              File((compressedPackage || useDelta) ? packagePath! : uploadPath)
                  .openRead(offset, offset + maxLength),
          onProgress: (sent, totalBytes) {
            final now = DateTime.now();
            final last = _lastProgressUpdate;
            if (last != null &&
                now.difference(last).inMilliseconds < 200 &&
                sent < totalBytes) return;
            // 以第一次回调的字节数作为基准：续传时它等于设备已确认的进度，
            // 本次增量才反映真实吞吐。
            if (_transferBaseBytes == null) {
              _transferBaseBytes = sent;
              _transferStartedAt = now;
            }
            final elapsed =
                now.difference(_transferStartedAt ?? now).inMilliseconds;
            final delta = sent - _transferBaseBytes!;
            // 采样窗口太短会把一次突发算成超高速度，累计 800ms 后再更新。
            if (elapsed >= 800 && delta > 0) {
              final speed = delta * 1000 / elapsed;
              _transferBytesPerSecond = speed;
              final remainingBytes = totalBytes - sent;
              _transferRemaining = speed > 0
                  ? Duration(seconds: (remainingBytes / speed).ceil())
                  : null;
            }
            _lastProgressUpdate = now;
            if (mounted) setState(() => _sent = sent);
          },
        );
        if (outcome == OtaUploadOutcome.paused) {
          if (mounted) setState(() => _status = '上传已暂停，等待设备确认的进度可在重连后查询');
          return;
        }
        if (outcome == OtaUploadOutcome.legacyInstallStarted) {
          _installCommandPending = true;
          if (mounted) {
            setState(() {
              _deviceStatus = 'DONE|$version';
              _status = '旧协议设备已确认固件并开始重启；重新连接后核验运行版本';
            });
          }
          return;
        }
        if (outcome == OtaUploadOutcome.resultPending) {
          if (mounted) {
            setState(() {
              _deviceStatus = 'UNKNOWN';
              _status = '设备已收到校验请求，结果待确认；请保持连接等待，断连后重连查询，不要重新上传';
            });
          }
          if (mounted && widget.ble.isConnected) await _refreshStatus();
          return;
        }
        if (mounted) {
          setState(() => _deviceStatus = 'VERIFIED|$version|$imageDigest');
        }
      }
      if (!mounted) return;
      final installConfirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(isDowngrade ? '确认降级安装' : '确认安装'),
          content: Text('设备已完整校验 v$version，当前运行版本仍是 v$currentVersion。'
              '${isDowngrade ? '目标固件的数据格式与当前设备兼容；本次降级不会执行跨格式迁移。' : ''}确认后设备将重启。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('稍后安装')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(isDowngrade ? '确认降级安装' : '确认安装')),
          ],
        ),
      );
      if (installConfirmed != true) {
        setState(() => _status = '校验通过，等待安装；任务保留在设备上');
        return;
      }
      await _taskController.markInstallRequested();
      _installCommandPending = true;
      await _taskController.install(
        taskId: _taskId!,
        allowDowngrade: isDowngrade,
      );
      if (mounted) await _refreshStatus();
    } catch (error) {
      String? recoveredStatus;
      try {
        recoveredStatus = (await _taskController.refresh(legacy: false)).raw;
      } catch (_) {}
      if (mounted) {
        setState(() {
          if (recoveredStatus != null) _deviceStatus = recoveredStatus;
          _status = _installCommandPending
              ? '安装结果待确认：$error。请重连查询设备版本和固件身份，暂勿重新上传'
              : '升级未完成：$error';
        });
      }
    } finally {
      _legacyProtocolActive = false;
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _handleBack() async {
    if (_exitDialogOpen) return;
    if (_startInProgress && !_working) {
      if (mounted) setState(() => _status = '正在检查设备与固件信息，请等待操作完成');
      return;
    }
    if (_working && widget.ble.isOtaVerifying) {
      if (mounted) {
        setState(() => _status = '设备正在校验固件，请留在页面等待；超时后可重新查询结果');
      }
      return;
    }
    if (!_working || !widget.ble.isOtaUploading) {
      Navigator.of(context).pop();
      return;
    }
    _exitDialogOpen = true;
    try {
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('固件仍在上传'),
          content: Text(_legacyProtocolActive
              ? '旧协议不支持暂停或续传。可以继续留在页面，或中止上传并返回；中止后需要从头上传。'
              : '可以继续留在页面，或暂停并返回。暂停会保留设备已确认的检查点。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, 'continue'),
                child: const Text('继续上传')),
            FilledButton(
                onPressed: () => Navigator.pop(context, 'pause'),
                child: Text(_legacyProtocolActive ? '中止并返回' : '暂停并返回')),
          ],
        ),
      );
      if (choice != 'pause' || !mounted) return;
      try {
        if (_legacyProtocolActive) {
          await _taskController.pause(taskId: _taskId!, legacy: true);
        } else {
          await _taskController.pause(taskId: _taskId!, legacy: false);
        }
        if (!mounted) return;
        setState(() => _status =
            _legacyProtocolActive ? '旧协议上传已中止；重新升级时需要从头上传' : '暂停已确认；设备检查点已保存');
        Navigator.of(context).pop();
      } catch (error) {
        if (mounted) {
          setState(() => _status = _legacyProtocolActive
              ? '旧协议升级已中止，重新开始需要从头上传：$error'
              : '上传已中断，重连后查询可续传进度：$error');
        }
        if (mounted) Navigator.of(context).pop();
      }
    } finally {
      _exitDialogOpen = false;
    }
  }

  Future<void> _abandonTask() async {
    if (_abandonInProgress || _working) return;
    _abandonInProgress = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃升级任务？'),
          content: const Text('设备已保存的续传检查点将失效，之后需要重新上传固件。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留任务')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃任务')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        final remoteTaskId = _taskSnapshot.taskId ?? _taskId!;
        await _taskController.abandon(taskId: remoteTaskId);
        _taskId = _createTaskId();
        await _taskController.saveTaskId(_taskId!);
        await _taskController.clearInstallIntent();
        _installCommandPending = false;
        if (mounted) {
          setState(() {
            _deviceStatus = 'IDLE';
            _status = '已放弃设备升级任务';
          });
        }
      } catch (error) {
        if (mounted) setState(() => _status = '放弃任务未确认：$error');
      }
    } finally {
      _abandonInProgress = false;
    }
  }

  int _compareVersions(String left, String right) {
    final a = left.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final b = right.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final comparison =
          (i < a.length ? a[i] : 0).compareTo(i < b.length ? b[i] : 0);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  String? _capabilityValue(String capabilities, String key) {
    for (final field in capabilities.split('|')) {
      if (field.startsWith('$key=')) return field.substring(key.length + 1);
    }
    return null;
  }

  bool _supportsRequiredOtaV2(String capabilities) {
    return OtaCapabilities.parse(capabilities).supportsRequiredV2;
  }

  String _createTaskId() => List<int>.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  String _formatBytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_working && !_startInProgress,
        onPopInvoked: (didPop) {
          if (!didPop) unawaited(_handleBack());
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('固件升级')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_upgradeSucceeded) ...[
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                  decoration: BoxDecoration(
                    color: MimiVentColors.mint.withOpacity(.10),
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: MimiVentColors.mint.withOpacity(.45)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.check_circle_rounded,
                        color: MimiVentColors.mint, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('固件升级成功',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text('设备当前运行 v${_upgradeSucceededVersion ?? '未知'}',
                              style: const TextStyle(
                                  color: MimiVentColors.muted, fontSize: 11)),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close,
                          color: MimiVentColors.muted, size: 18),
                      onPressed: () =>
                          setState(() => _upgradeSucceeded = false),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
              ],
              _panel(
                icon: Icons.bluetooth_connected_rounded,
                title: '蓝牙连接状态',
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          '升级通过当前蓝牙连接执行，无需接触开发板。确认开始后风机保持关闭；请将手机放在设备附近并保持 App 前台运行。'),
                      const SizedBox(height: 12),
                      Text('OTA 能力：${_otaCapabilities ?? '尚未读取'}',
                          style: const TextStyle(color: MimiVentColors.muted)),
                      const SizedBox(height: 6),
                      Text('设备状态：${_deviceStatus ?? '尚未读取'}',
                          style: const TextStyle(color: MimiVentColors.mint)),
                      if (_taskSnapshot.canAbandon &&
                          _taskSnapshot.phase != OtaTaskPhase.installed)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _working ? null : _abandonTask,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('放弃升级任务'),
                          ),
                        ),
                      if (_taskSnapshot.phase == OtaTaskPhase.installed)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _working ? null : _abandonTask,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('清除已核验升级记录'),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _working ? null : _refreshStatus,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('刷新设备状态'),
                        ),
                      ),
                    ]),
              ),
              const SizedBox(height: 14),
              _panel(
                icon: Icons.system_update_alt_rounded,
                title: '升级固件',
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _working ? null : _pickFirmware,
                              icon: const Icon(Icons.folder_open_rounded),
                              label:
                                  Text(_firmware?.name ?? '选择 OTA 固件包（设备验签）'),
                            ),
                          ),
                          if (_firmware != null) ...[
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: '移除已选文件',
                              onPressed:
                                  _working ? null : _clearSelectedFirmware,
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _versionController,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: '固件版本',
                          hintText: '例如 0.3.3',
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text('当前 App 最低支持固件：v$_minimumFirmwareVersion',
                          style: TextStyle(color: MimiVentColors.muted)),
                      if (_working) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: _transferTotal == 0
                              ? null
                              : _sent / _transferTotal,
                          color: MimiVentColors.mint,
                        ),
                        const SizedBox(height: 6),
                        Text(
                            '${_formatBytes(_sent)} / ${_formatBytes(_transferTotal)} OTA 包'),
                        if (_transferBytesPerSecond != null)
                          Text(
                              '${_formatBytes(_transferBytesPerSecond!.round())}/秒'
                              '${_transferRemaining == null ? '' : ' · 剩余约 ${_transferRemaining!.inSeconds} 秒'}'),
                      ],
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _working || _startInProgress
                              ? null
                              : _startUpdate,
                          icon: _working
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.upload_rounded),
                          label: Text(_working ? '正在升级…' : '开始 BLE 升级'),
                        ),
                      ),
                      if (_working && widget.ble.isOtaUploading) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () async {
                              try {
                                if (_legacyProtocolActive) {
                                  await _taskController.pause(
                                      taskId: _taskId!, legacy: true);
                                } else {
                                  await _taskController.pause(
                                      taskId: _taskId!, legacy: false);
                                }
                                if (mounted) {
                                  setState(() => _status = _legacyProtocolActive
                                      ? '旧协议上传已中止；重试需要从头上传'
                                      : '暂停已确认，可重连后续传');
                                }
                              } catch (error) {
                                if (mounted) {
                                  setState(() => _status = '暂停结果待确认：$error');
                                }
                              }
                            },
                            child:
                                Text(_legacyProtocolActive ? '中止上传' : '暂停上传'),
                          ),
                        ),
                      ],
                    ]),
              ),
              const SizedBox(height: 14),
              Text(_status,
                  style: const TextStyle(
                      color: MimiVentColors.muted, height: 1.4)),
            ],
          ),
        ),
      );

  Widget _panel(
          {required IconData icon,
          required String title,
          required Widget child}) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: MimiVentColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(.07)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: MimiVentColors.mint, size: 19),
            const SizedBox(width: 9),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      );
}
