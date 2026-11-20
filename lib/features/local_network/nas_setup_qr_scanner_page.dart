import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'nas_setup_config.dart';

/// 支持实时相机扫码，也支持从手机截图/图片文件识别二维码。
class NasSetupQrScannerPage extends StatefulWidget {
  const NasSetupQrScannerPage({super.key, this.rawMode = false});

  /// true 时只返回扫描到的原始文本（用于“加入码”），不解析 NAS 配置。
  final bool rawMode;

  @override
  State<NasSetupQrScannerPage> createState() => _NasSetupQrScannerPageState();
}

class _NasSetupQrScannerPageState extends State<NasSetupQrScannerPage> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handling = false;
  String? _error;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _accept(String? value) async {
    if (_handling || !mounted) return;
    if (value == null) {
      setState(() => _error = '图片中没有识别到二维码');
      return;
    }
    setState(() {
      _handling = true;
      _error = null;
    });
    try {
      if (widget.rawMode) {
        if (!mounted) return;
        setState(() => _handling = false);
        Navigator.pop(context, value);
        return;
      }
      final config = NasSetupConfig.parse(value);
      await _scanner.stop();
      if (mounted) Navigator.of(context).pop(config);
    } on FormatException catch (error) {
      setState(() {
        _handling = false;
        _error = error.message;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _handling = false;
          _error = '读取二维码失败，请重试或选择清晰的截图';
        });
      }
    }
  }

  Future<void> _chooseImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
      if (!mounted || result == null) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        setState(() => _error = '无法读取所选图片，请保存图片到手机后重试');
        return;
      }
      setState(() => _error = null);
      await _scanner.stop();
      final captureCompleter = Completer<String?>();
      final subscription = _scanner.barcodes.listen((capture) {
        if (captureCompleter.isCompleted) return;
        captureCompleter.complete(capture.barcodes
            .map((barcode) => barcode.rawValue)
            .whereType<String>()
            .firstOrNull);
      });
      String? rawValue;
      try {
        final found = await _scanner.analyzeImage(path);
        if (found) {
          rawValue = await captureCompleter.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => null,
          );
        }
      } finally {
        await subscription.cancel();
        if (mounted) await _scanner.start();
      }
      await _accept(rawValue);
    } catch (_) {
      if (mounted) setState(() => _error = '无法识别这张图片，请选择包含完整二维码的截图');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('导入 NAS 配置')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _scanner,
                      onDetect: (capture) {
                        final value = capture.barcodes
                            .map((barcode) => barcode.rawValue)
                            .whereType<String>()
                            .firstOrNull;
                        if (value != null) _accept(value);
                      },
                    ),
                    Center(
                      child: Container(
                        width: 264,
                        height: 264,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                    if (_handling)
                      const Center(child: CircularProgressIndicator()),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('扫描 NAS 部署页生成的 MimiVent 二维码，自动导入网关与 MQTT 配置。'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _handling ? null : _chooseImage,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('从相册或文件选择二维码图片'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 4),
                    Text('二维码包含家庭 NAS 的 MQTT 凭据，请勿转发给他人。',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
