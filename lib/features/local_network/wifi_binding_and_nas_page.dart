import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'nas_gateway_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';

import '../../shared/widgets/top_toast.dart';
import '../../ble/mimivent_ble_manager.dart';
import 'nas_setup_config.dart';
import 'nas_setup_qr_scanner_page.dart';
import 'wifi_binding_controller.dart';
import 'wifi_binding.dart';

class WifiBindingAndNasPage extends StatefulWidget {
  const WifiBindingAndNasPage(
      {required this.ble,
      this.onOpenWifiProvisioning,
      this.initialBinding,
      this.onSwitchToNasMqtt,
      super.key});
  final MimiVentBleManager ble;
  final VoidCallback? onOpenWifiProvisioning;

  /// 从 MQTT 通道进入时已知的有效绑定；蓝牙未连接也能选中正确记录。
  final WifiBinding? initialBinding;

  /// 加入已有服务成功后，直接请求首页完成 MQTT 通道切换。
  /// 未提供时继续通过路由结果向上回传，兼容嵌套设置入口。
  final Future<void> Function()? onSwitchToNasMqtt;
  @override
  State<WifiBindingAndNasPage> createState() => _WifiBindingAndNasPageState();
}

class _WifiBindingAndNasPageState extends State<WifiBindingAndNasPage> {
  late final WifiBindingController controller;
  Map<String, dynamic>? mqttStatus;
  Map<String, String>? gatewayConfig;
  NasSetupConfig? _pendingNasSetupConfig;
  bool _nasMqttStateReady = false;
  bool _managingApps = false;
  bool _gatewayAccessChecking = false;
  bool _gatewayAccessValid = false;
  bool _gatewayAccessRejected = false;
  String? _gatewayAccessDeviceId;
  String? _gatewayAccessTokenId;
  String? _gatewayAccessMessage;
  int _gatewayAccessGeneration = 0;
  @override
  void initState() {
    super.initState();
    controller = WifiBindingController(widget.ble);
    controller.addListener(changed);
    widget.ble.addListener(changed);
    controller.load().then((_) async {
      if (!mounted) return;
      final known = widget.initialBinding;
      if (known != null && known.state == 'active') {
        // MQTT 通道进入：dashboard 已知当前生效绑定，直接选中它。
        controller.select(known);
      } else if (widget.ble.isConnected) {
        // 蓝牙进入：按当前设备选中并在多条记录中挑出 token 有效的那条。
        await controller.syncSelectedWithDevice();
      }
      await _refreshGatewayAccess();
    });
    controller.gatewayTransport.loadConfig().then((value) {
      if (!mounted) return;
      setState(() => gatewayConfig = value);
    });
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
  }

  /// dialog 关闭后还有退场动画，立即 dispose 控制器会让仍在构建的 widget
  /// 访问已释放对象，触发 framework 的 _dependents.isEmpty 断言。
  void _disposeLater(Iterable<TextEditingController> controllers) {
    final pending = controllers.toList(growable: false);
    Future<void>.delayed(const Duration(seconds: 1), () {
      for (final item in pending) {
        item.dispose();
      }
    });
  }

  String _pendingAgeLabel(int? ageMs, bool estimated) {
    if (ageMs == null) return '等待时长未知';
    final prefix = estimated ? '至少已等待' : '已等待';
    if (ageMs < 60000) return '$prefix ${ageMs ~/ 1000} 秒';
    return '$prefix ${ageMs ~/ 60000} 分 ${(ageMs % 60000) ~/ 1000} 秒';
  }

  String _stateAgeLabel(dynamic value) {
    final ageMs = value is num ? value.toDouble() : double.tryParse('$value');
    if (ageMs == null || !ageMs.isFinite || ageMs < 0) return '未知';
    if (ageMs < 1000) return '${ageMs.round()} ms 前';
    return '${(ageMs / 1000).toStringAsFixed(1)} 秒前';
  }

  bool get _gatewayAccessMatchesSelection {
    final binding = controller.selected;
    return binding != null &&
        _gatewayAccessDeviceId == binding.deviceId &&
        _gatewayAccessTokenId == binding.tokenId;
  }

  Future<void> _refreshGatewayAccess({
    WifiBinding? binding,
    bool showFeedback = false,
  }) async {
    final target = binding ?? controller.selected;
    final generation = ++_gatewayAccessGeneration;
    if (target == null || target.state != 'active') {
      if (!mounted) return;
      setState(() {
        _gatewayAccessChecking = false;
        _gatewayAccessValid = false;
        _gatewayAccessRejected = false;
        _gatewayAccessDeviceId = target?.deviceId;
        _gatewayAccessTokenId = target?.tokenId;
        _gatewayAccessMessage = '需要先完成设备服务授权';
      });
      return;
    }
    if (mounted) {
      setState(() {
        _gatewayAccessChecking = true;
        _gatewayAccessValid = false;
        _gatewayAccessRejected = false;
        _gatewayAccessDeviceId = target.deviceId;
        _gatewayAccessTokenId = target.tokenId;
        _gatewayAccessMessage = null;
      });
    }
    Map<String, dynamic>? apps;
    NasGatewayHttpResult? stateResult;
    Object? failure;
    try {
      // 用手机管理 API 核验 App 授权；它不依赖设备是否刚好有新状态快照。
      apps = await controller.gatewayTransport.listApps(target);
    } catch (error) {
      failure = error;
      // 网关旧版可能没有手机管理响应字段；用已验证的状态接口兜底，
      // 避免用户必须手动点“验证 NAS”才能解锁分享入口。
      try {
        stateResult = await controller.gatewayTransport.tryReadState(target);
      } catch (_) {
        // 下方保留原管理 API 错误，以区分授权拒绝和网关不可达。
      }
    }
    if (!mounted || generation != _gatewayAccessGeneration) return;
    final validFromApps = apps?['deviceId'] == target.deviceId &&
        apps?['currentAppInstanceId'] == target.tokenId;
    final validFromState = stateResult?.statusCode == 200 &&
        stateResult?.body['deviceId'] == target.deviceId &&
        stateResult?.body['appInstanceId'] == target.tokenId &&
        stateResult?.body['bindingState'] == 'active';
    final valid = validFromApps || validFromState;
    final code = failure is NasGatewayException ? failure.code : '';
    final rejected = const {
          'AUTH_REQUIRED',
          'INVALID_BEARER',
          'PERMISSION_DENIED',
        }.contains(code) ||
        stateResult?.statusCode == 401 ||
        stateResult?.statusCode == 403;
    setState(() {
      _gatewayAccessChecking = false;
      _gatewayAccessValid = valid;
      _gatewayAccessRejected = rejected;
      _gatewayAccessMessage = valid
          ? 'NAS 授权已验证'
          : rejected
              ? '此手机的 NAS 授权已清除或失效，请先重新加入/绑定'
              : '暂时无法验证 NAS 授权，可检查网关后重试';
    });
    if (showFeedback) {
      TopToast.show(
        context,
        valid
            ? 'NAS 授权有效'
            : rejected
                ? 'NAS 网关拒绝此手机：授权无效'
                : 'NAS 网关暂不可达，请检查网络后重试',
      );
    }
  }

  Future<void> _verifyNasState(WifiBinding binding) async {
    final generation = ++_gatewayAccessGeneration;
    setState(() => _gatewayAccessChecking = true);
    final result = await controller.gatewayTransport.tryReadState(binding);
    if (!mounted || generation != _gatewayAccessGeneration) return;
    final valid = result?.statusCode == 200 &&
        result?.body['deviceId'] == binding.deviceId &&
        result?.body['appInstanceId'] == binding.tokenId &&
        result?.body['bindingState'] == 'active';
    final rejected = result?.statusCode == 401 || result?.statusCode == 403;
    setState(() {
      _gatewayAccessChecking = false;
      if (valid) {
        _gatewayAccessValid = true;
        _gatewayAccessRejected = false;
        _gatewayAccessMessage = 'NAS 授权和设备状态均可用';
      } else if (rejected) {
        _gatewayAccessValid = false;
        _gatewayAccessRejected = true;
        _gatewayAccessMessage = '此手机的 NAS 授权已清除或失效，请先重新加入/绑定';
      } else {
        _gatewayAccessMessage = '网关已授权，但当前没有可用的设备状态；请检查设备 MQTT 连接';
      }
    });
    if (valid) controller.status = result!.body;
    controller.changed();
    TopToast.show(
      context,
      valid
          ? 'NAS 已连接，设备状态已读取'
          : rejected
              ? 'NAS 网关拒绝此手机：授权无效'
              : 'NAS 授权有效，但暂时没有设备状态',
    );
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    widget.ble.removeListener(changed);
    controller.dispose();
    super.dispose();
  }

  Future<bool> confirm(String title, String text,
          {String confirmLabel = '确认'}) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(text), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(confirmLabel))
              ])) ??
      false;
  Future<void> manageClients() async {
    final binding = controller.selected;
    if (binding == null) {
      TopToast.show(context, '请先选择已加入 NAS 服务的设备');
      return;
    }
    setState(() => _managingApps = true);
    Map<String, dynamic> data;
    try {
      data = await controller.gatewayTransport.listApps(binding);
    } catch (error) {
      if (mounted) TopToast.show(context, '$error');
      return;
    } finally {
      if (mounted) setState(() => _managingApps = false);
    }
    if (!mounted) return;
    final clients = (data['apps'] as List).cast<Map<String, dynamic>>();
    final currentAppId = data['currentAppInstanceId'] as String;
    final dialogHeight = min(440.0, max(120.0, clients.length * 72.0));
    final target = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('管理已授权手机'),
        content: SizedBox(
          width: double.maxFinite,
          height: dialogHeight,
          child: clients.isEmpty
              ? const Center(child: Text('还没有已授权手机'))
              : ListView.builder(
                  itemCount: clients.length,
                  itemBuilder: (context, index) {
                    final client = clients[index];
                    final appId = client['appInstanceId'] as String;
                    final isCurrent = appId == currentAppId;
                    final revoked = client['revoked'] == true;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(client['name'] as String),
                      subtitle: Text([
                        '已加入手机',
                        if (isCurrent) '当前手机',
                        if (revoked) '已撤销',
                      ].join(' · ')),
                      trailing: !isCurrent && !revoked
                          ? IconButton(
                              tooltip: '撤销此手机',
                              icon: const Icon(Icons.person_remove_outlined),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(appId),
                            )
                          : null,
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted || target == null) return;
    if (!await confirm('撤销此手机授权', '该手机将无法继续使用 NAS 控制和同步；其他手机不受影响。') ||
        !mounted) {
      return;
    }
    setState(() => _managingApps = true);
    try {
      await controller.gatewayTransport.revokeApp(binding, target);
      if (mounted) TopToast.show(context, '已撤销该手机的 NAS 访问权限');
    } catch (error) {
      if (mounted) TopToast.show(context, '$error');
    } finally {
      if (mounted) setState(() => _managingApps = false);
    }
  }

  Future<void> configureNasGateway() async {
    final config = await controller.gatewayTransport.loadConfig();
    if (!mounted) return;
    final url = TextEditingController(text: config['url']);
    final pin = TextEditingController(text: config['certificatePin']);
    final bulk = TextEditingController();
    var enabled = config['enabled'] == 'true';
    String? bulkError;
    // 支持两类输入：部署脚本生成的 mimivent:// 连接串，或 .env 的 KEY=VALUE。
    // MQTT 密码不应复制进这个表单；成功导入后立即清除粘贴文本。
    void applyBulk(String raw, StateSetter setDialogState) {
      final text = raw.trim();
      void fail(String message) {
        bulk.clear();
        setDialogState(() => bulkError = message);
      }

      if (text.isEmpty) {
        fail('请先粘贴 NAS 连接串或配置项');
        return;
      }
      String? host;
      String gwPort = '8444';
      String? certPin;
      final isConnectionUri = text.startsWith('mimivent://');
      if (isConnectionUri) {
        final uri = Uri.tryParse(text);
        if (uri == null ||
            uri.scheme != 'mimivent' ||
            uri.host != 'nas' ||
            uri.hasFragment ||
            uri.userInfo.isNotEmpty) {
          fail('连接串格式无效，请从 NAS 部署输出重新复制');
          return;
        }
        final q = uri.queryParameters;
        host = q['host'];
        gwPort = q['gwPort'] ?? gwPort;
        certPin = q['pin'] ?? q['certPinSha256'];
      } else {
        final map = <String, String>{};
        for (final line in text.split(RegExp(r'[\r\n]+'))) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          final i = trimmed.indexOf('=');
          if (i > 0) {
            final key = trimmed.substring(0, i).trim();
            if (const {
              'NAS_IP',
              'host',
              'MIMIVENT_NAS_HOST',
              'NAS_GW_PORT',
              'gwPort',
              'NAS_CERT_SHA256',
              'pin',
              'certPinSha256',
            }.contains(key)) {
              map[key] = trimmed
                  .substring(i + 1)
                  .trim()
                  .replaceAll(RegExp(r'''^['"]|['"]$'''), '');
            }
          }
        }
        host = map['NAS_IP'] ?? map['host'] ?? map['MIMIVENT_NAS_HOST'];
        gwPort = map['NAS_GW_PORT'] ?? map['gwPort'] ?? gwPort;
        certPin = map['NAS_CERT_SHA256'] ?? map['pin'] ?? map['certPinSha256'];
      }
      final hostPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.\-]{0,252}$');
      final port = int.tryParse(gwPort);
      final normalizedPin = certPin?.toLowerCase();
      if (host == null || !hostPattern.hasMatch(host)) {
        fail('缺少有效 NAS_IP；请粘贴 NAS 输出的连接串或对应配置项');
        return;
      }
      if (port == null || port < 1 || port > 65535) {
        fail('NAS 网关端口须为 1–65535 的数字');
        return;
      }
      if (normalizedPin != null &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedPin)) {
        fail('证书指纹无效，应为 64 位 SHA-256 十六进制值');
        return;
      }
      if (isConnectionUri && normalizedPin == null) {
        fail('连接串中缺少 pin 证书指纹');
        return;
      }
      url.text = 'https://$host:$port';
      if (normalizedPin != null) {
        pin.text = normalizedPin;
      } else {
        pin.clear();
      }
      bulk.clear();
      setDialogState(() => bulkError = null);
    }

    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('NAS 本地网关'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: bulk,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: '粘贴 NAS 配置（推荐）',
                  hintText:
                      'mimivent://nas?host=192.168.1.20&gwPort=8444&pin=<64位指纹>',
                  helperText:
                      '粘贴连接串，或只粘贴 NAS_IP / NAS_GW_PORT / NAS_CERT_SHA256 行；不要粘贴完整 .env（含密码）。',
                ),
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => applyBulk(bulk.text, setDialogState),
                  icon: const Icon(Icons.input),
                  label: const Text('导入并填入'),
                ),
              ),
              if (bulkError != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(bulkError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'HTTPS 地址',
                  hintText: 'https://NAS局域网IP:8444',
                  helperText: '使用 NAS 局域网 IPv4，不要填远程访问网址。',
                ),
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
              ),
              TextField(
                controller: pin,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: '证书 SHA-256 指纹',
                  helperText:
                      '在 NAS 上执行：openssl x509 -in tls/cert.pem -outform der | sha256sum',
                ),
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 NAS 控制'),
                subtitle: const Text('网关不可达时会提示切换蓝牙，不会自动改走设备直连'),
                value: enabled,
                onChanged: (value) => setDialogState(() => enabled = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: showNasSetupGuide,
                  icon: const Icon(Icons.help_outline),
                  label: const Text('不知道地址或证书指纹？查看配置说明'),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      try {
        await controller.gatewayTransport.saveConfig(
          url: url.text,
          certificatePin: pin.text,
          enabled: enabled,
        );
        gatewayConfig = await controller.gatewayTransport.loadConfig();
        if (mounted) setState(() {});
        if (mounted) {
          TopToast.show(context, 'NAS 网关设置已保存');
        }
      } on FormatException catch (error) {
        if (mounted) {
          TopToast.show(context, error.message);
        }
      }
    }
    _disposeLater([url, pin, bulk]);
  }

  /// 本机 App 实例标识（32 hex），与 controller 内部使用同一存储键。
  Future<String> localAppInstanceId() async {
    final preferences = await SharedPreferences.getInstance();
    const key = 'mimivent.gateway.app_instance_id.v1';
    final existing = preferences.getString(key);
    if (existing != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(existing)) {
      return existing;
    }
    final raw = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final generated =
        raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await preferences.setString(key, generated);
    return generated;
  }

  /// 生成「加入码」：网关地址 + 证书指纹 + 邀请码 + 设备标识，打包成一段文本。
  /// 另一部手机粘贴即可加入，不需要手抄 64 位指纹。
  Future<void> showJoinCode(WifiBinding binding) async {
    final config = await controller.gatewayTransport.loadConfig();
    if (!mounted) return;
    final baseUrl = config['url'] ?? '';
    final pin = config['certificatePin'] ?? '';
    if (baseUrl.isEmpty) {
      TopToast.show(context, '请先设置并保存 NAS 网关地址');
      return;
    }
    debugPrint(
        '[join] start device=${binding.deviceId} url=$baseUrl pinLen=${pin.length}');
    try {
      final invite = await controller.gatewayTransport
          .createInvite(binding)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final code = invite['inviteCode']?.toString() ?? '';
      debugPrint('[join] invite ok codeLen=${code.length}');
      if (code.isEmpty) {
        TopToast.show(context, '网关未返回邀请码');
        return;
      }
      final payload = base64Url
          .encode(utf8.encode('$baseUrl|$pin|$code|${binding.deviceId}'));
      debugPrint('[join] payloadLen=${payload.length} mounted=$mounted');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final screen = MediaQuery.sizeOf(dialogContext);
          final dialogWidth = min(420.0, screen.width - 40);
          final dialogHeight = min(680.0, screen.height - 48);
          final qrSize = min(232.0, dialogWidth - 72);
          return Dialog(
            child: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text('邀请另一部手机加入',
                        style: Theme.of(dialogContext).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('让另一部手机打开“用加入码加入”，扫描二维码。邀请码 24 小时内有效且仅可使用一次。'),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: SizedBox.square(
                                dimension: qrSize,
                                child: QrImageView(
                                  data: payload,
                                  version: QrVersions.auto,
                                  size: qrSize,
                                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('也可以复制加入码，发送给对方：'),
                            ),
                            const SizedBox(height: 6),
                            SelectableText(payload,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () async {
                            try {
                              await Clipboard.setData(
                                  ClipboardData(text: payload));
                            } catch (error) {
                              debugPrint('[join] clipboard failed: $error');
                            }
                            if (!dialogContext.mounted) return;
                            TopToast.show(dialogContext, '加入码已复制');
                          },
                          child: const Text('复制加入码'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      debugPrint('[join] dialog closed');
    } on NasGatewayException catch (error) {
      debugPrint('[join] createInvite failed: ${error.code} ${error.message}');
      if (error.code == 'AUTH_REQUIRED' || error.code == 'ADMIN_REQUIRED') {
        if (mounted) {
          setState(() {
            _gatewayAccessValid = false;
            _gatewayAccessRejected = error.code == 'AUTH_REQUIRED';
            _gatewayAccessMessage = error.code == 'AUTH_REQUIRED'
                ? '此手机的 NAS 授权已清除或失效，请先重新加入/绑定'
                : 'NAS 网关仍启用了旧版管理员限制，请更新 Gateway 后重试';
          });
        }
      }
      if (mounted) TopToast.show(context, '${error.message}（${error.code}）');
    } on TimeoutException {
      debugPrint('[join] createInvite timeout');
      if (mounted) TopToast.show(context, '生成加入码超时：网关无响应');
    } catch (error) {
      debugPrint('[join] createInvite error: $error');
      if (mounted) TopToast.show(context, '生成加入码失败：$error');
    }
  }

  /// 另一部手机：粘贴加入码 → 保存网关配置 → 兑换凭据 → 保存本机记录。
  Future<void> joinWithCode() async {
    final input = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('用加入码加入'),
        content: TextField(
          controller: input,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '加入码',
            hintText: '粘贴另一部手机生成的整段文本',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // 用 dialog 自己的 context：用页面 context 会让 dialog 的 element
              // 依赖页面 Navigator，关闭时残留依赖触发 _dependents.isEmpty。
              final scanned = await Navigator.of(dialogContext).push<String>(
                MaterialPageRoute(
                  builder: (_) => const NasSetupQrScannerPage(rawMode: true),
                ),
              );
              if (scanned != null && scanned.isNotEmpty) {
                input.text = scanned;
              }
            },
            child: const Text('扫码'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
            child: const Text('加入'),
          ),
        ],
      ),
    );
    _disposeLater([input]);
    if (code == null || code.isEmpty || !mounted) return;
    try {
      final parts =
          utf8.decode(base64Url.decode(base64Url.normalize(code))).split('|');
      if (parts.length != 4) {
        TopToast.show(context, '加入码格式无效');
        return;
      }
      final gatewayUrl = parts[0];
      final certificatePin = parts[1];
      final inviteCode = parts[2];
      final deviceId = parts[3];
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(deviceId)) {
        TopToast.show(context, '加入码里的设备标识无效');
        return;
      }
      await controller.gatewayTransport.saveConfig(
        url: gatewayUrl,
        certificatePin: certificatePin,
        enabled: true,
      );
      final appInstanceId = await localAppInstanceId();
      final issued = await controller.gatewayTransport.redeemInvite(
        inviteCode: inviteCode,
        appInstanceId: appInstanceId,
        name: '手机',
      );
      if (!mounted) return;
      final issuedInstance = issued['appInstanceId']?.toString();
      final appToken = issued['appToken']?.toString();
      if (issuedInstance == null || appToken == null) {
        TopToast.show(context, '网关未返回有效凭据');
        return;
      }
      final binding = WifiBinding(
        deviceId: deviceId,
        tokenId: issuedInstance,
        token: appToken,
        pin: '',
        host: '',
        clientId: 'gateway',
        state: 'active',
      );
      await controller.persist([
        ...controller.records.where((r) => r.deviceId != deviceId),
        binding,
      ]);
      controller.select(binding);
      if (mounted) {
        setState(() {});
        // 加入只是取得本机访问凭据；必须再经过首页的网关状态、设备 MQTT
        // 与租约检查，确认可用后才切换控制通道。
        final switchToNasMqtt = widget.onSwitchToNasMqtt;
        if (switchToNasMqtt != null) {
          await switchToNasMqtt();
        } else if (mounted) {
          // 嵌套设置入口由外层路由把意图传回首页。
          Navigator.of(context).pop(true);
        }
      }
    } on NasGatewayException catch (error) {
      if (mounted) TopToast.show(context, '${error.message}（${error.code}）');
    } catch (error) {
      if (mounted) TopToast.show(context, '加入失败：$error');
    }
  }

  Future<void> importNasSetupQr() async {
    final config = await Navigator.of(context).push<NasSetupConfig>(
      MaterialPageRoute(builder: (_) => const NasSetupQrScannerPage()),
    );
    if (!mounted || config == null) return;
    final canConfigureDevice = widget.ble.isConnected;
    final accepted = await confirm(
      canConfigureDevice ? '导入 NAS 配置' : '保存 NAS 网关配置',
      'NAS：${config.host}\n网关端口：${config.gatewayPort}\nMQTT 端口：${config.mqttPort}\n\n${canConfigureDevice ? '将启用 NAS 网关，通过蓝牙配置设备 MQTT，并确认或恢复此手机的设备绑定。之后会自动检查 Broker 连接和 NAS 实时状态。密码不会写入本地存储。' : '当前未连接设备蓝牙，将先保存网关地址与证书指纹。接受后 MQTT 配置仅暂存于当前页面内存，连接蓝牙后可直接重试，无需重新扫码；退出页面即清除。'}',
      confirmLabel: canConfigureDevice ? '导入并配置设备' : '仅保存网关',
    );
    if (!mounted || !accepted) return;
    _pendingNasSetupConfig = config;
    _nasMqttStateReady = false;
    await controller.run(() async {
      await controller.gatewayTransport.saveConfig(
        url: config.gatewayUrl,
        certificatePin: config.certificatePin,
        enabled: true,
      );
      gatewayConfig = await controller.gatewayTransport.loadConfig();
      if (widget.ble.isConnected) {
        final binding = await _ensureCurrentPhoneBinding();
        await controller.request('wifi.mqtt.configure', extra: {
          'payload': {
            'host': config.host,
            'port': config.mqttPort,
            'username': config.mqttUsername,
            'password': config.mqttPassword,
          }
        });
        mqttStatus = await _waitForMqttConnection();
        if (mqttStatus?['configured'] == true &&
            mqttStatus?['connected'] == true) {
          _pendingNasSetupConfig = null;
          _nasMqttStateReady = await _waitForFreshNasState(binding);
        }
      }
    }, clearData: false);
    if (!mounted) return;
    if (controller.error == null) {
      if (_nasMqttStateReady) {
        await _showNasMqttReadyPrompt();
      } else {
        TopToast.show(
          context,
          _pendingNasSetupConfig != null
              ? (widget.ble.isConnected
                  ? '配置已写入，但设备 MQTT 尚未确认连接；保留本次扫码信息，稍后可直接重试，无需重新扫码。'
                  : 'NAS 网关已保存；二维码配置暂存于当前页面。连接设备蓝牙后可直接重试，无需重新扫码。')
              : '设备已连接 MQTT Broker，但 NAS 尚未收到实时状态；无需重新扫码，可稍后刷新状态。',
        );
      }
    } else {
      gatewayConfig = await controller.gatewayTransport.loadConfig();
      if (!mounted) return;
      TopToast.show(
        context,
        '网关配置已导入；设备 MQTT 配置未完成：${controller.error}',
      );
    }
    setState(() {});
  }

  Future<void> applyPendingNasMqttConfig() async {
    final config = _pendingNasSetupConfig;
    if (config == null) return;
    if (!widget.ble.isConnected) {
      TopToast.show(context, '请先连接设备蓝牙，再重试 MQTT 配置');
      return;
    }
    _nasMqttStateReady = false;
    await controller.run(() async {
      final binding = await _ensureCurrentPhoneBinding();
      await controller.request('wifi.mqtt.configure', extra: {
        'payload': {
          'host': config.host,
          'port': config.mqttPort,
          'username': config.mqttUsername,
          'password': config.mqttPassword,
        }
      });
      mqttStatus = await _waitForMqttConnection();
      if (mqttStatus?['configured'] == true &&
          mqttStatus?['connected'] == true) {
        _pendingNasSetupConfig = null;
        _nasMqttStateReady = await _waitForFreshNasState(binding);
      }
    }, clearData: false);
    if (!mounted) return;
    if (controller.error == null) {
      if (_nasMqttStateReady) {
        await _showNasMqttReadyPrompt();
      } else {
        TopToast.show(
          context,
          _pendingNasSetupConfig != null
              ? '配置已写入，但设备 MQTT 尚未确认连接；本次扫码信息已保留，可直接重试。'
              : 'Broker 已连接，NAS 实时状态尚未到达；无需重新扫码。',
        );
      }
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<WifiBinding> _ensureCurrentPhoneBinding() async {
    final network = await controller.request('wifi.status');
    final deviceId = network['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) {
      throw StateError('设备未返回身份，无法确认手机绑定');
    }
    WifiBinding? localBinding;
    for (final record in controller.records) {
      if (record.deviceId == deviceId && record.state == 'active') {
        localBinding = record;
        break;
      }
    }
    if (localBinding != null) {
      try {
        final remote = await controller.request('wifi.bind.status',
            extra: {'tokenId': localBinding.tokenId});
        if (remote['bindingState'] == 'active') {
          if (controller.selected?.tokenId != localBinding.tokenId) {
            controller.select(localBinding);
          }
          return localBinding;
        }
      } catch (_) {
        // 本机记录可能已被设备撤销，下面通过当前蓝牙会话重新绑定。
      }
    }
    await controller.bindWithinCurrentOperation();
    final binding = controller.selected;
    if (binding == null ||
        binding.deviceId != deviceId ||
        binding.state != 'active') {
      throw StateError('此手机尚未完成设备绑定');
    }
    return binding;
  }

  Future<Map<String, dynamic>?> _waitForMqttConnection() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    Map<String, dynamic>? latest;
    while (mounted &&
        widget.ble.isConnected &&
        DateTime.now().isBefore(deadline)) {
      try {
        latest = await controller.request('wifi.mqtt.status');
      } catch (_) {
        // BLE 可能在设备重启 MQTT 客户端时断开；保留扫码配置供用户重试。
        break;
      }
      mqttStatus = latest;
      if (latest['configurationState'] == 'rolled_back') {
        throw StateError('新 Broker 未能在设备确认窗口内连接，已恢复之前的配置。请检查地址、端口和账号后重试');
      }
      // 配置命令返回后，旧 MQTT 客户端可能仍短暂显示 connected；只有设备
      // 已将候选 Broker 提升为 active，才算新配置连接成功。
      if (latest['configurationState'] != 'trial' &&
          latest['configured'] == true &&
          latest['connected'] == true) {
        return latest;
      }
      if (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return latest;
  }

  Future<bool> _waitForFreshNasState(WifiBinding binding) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final result = await controller.gatewayTransport.tryReadState(binding);
      final body = result?.body;
      if (result?.statusCode == 200 &&
          body?['deviceId'] == binding.deviceId &&
          body?['appInstanceId'] == binding.tokenId &&
          body?['bindingState'] == 'active' &&
          body?['stale'] == false &&
          body?['stateFreshness'] == 'fresh') {
        controller.status = body;
        controller.changed();
        return true;
      }
      if (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
    return false;
  }

  Future<void> _showNasMqttReadyPrompt() async {
    final switchToMqtt = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('NAS MQTT 已连接'),
            content: const Text('设备已连接 NAS，实时状态也已读取。现在切换到 NAS MQTT 控制并返回首页吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认并切换'),
              ),
            ],
          ),
        ) ??
        false;
    if (switchToMqtt && mounted) {
      // 扫码配置完成后直接进入首页的统一切换流程，避免依赖多层路由
      // 逐级转发 bool 结果；若检查失败，首页会说明原因并保留当前页面。
      final switchToNasMqtt = widget.onSwitchToNasMqtt;
      if (switchToNasMqtt != null) {
        await switchToNasMqtt();
      } else if (mounted) {
        Navigator.of(context).pop(true);
      }
    }
  }

  Future<void> configureMqtt() async {
    Map<String, dynamic>? current;
    await controller.run(() async {
      current = await controller.request('wifi.mqtt.status');
    }, clearData: false);
    if (!mounted || controller.error != null) return;
    mqttStatus = current;
    final gateway = await controller.gatewayTransport.loadConfig();
    if (!mounted) return;
    final gatewayHost = Uri.tryParse(gateway['url'] ?? '')?.host ?? '';
    final brokerHost = TextEditingController(
        text: current?['host']?.toString() ?? gatewayHost);
    final brokerPort =
        TextEditingController(text: current?['port']?.toString() ?? '1883');
    final username = TextEditingController();
    final password = TextEditingController();
    final configure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('配置 NAS MQTT'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('此处通过蓝牙把 NAS Broker 地址和 MQTT 账号写入设备。账号不是 NAS 管理员账号。'
                '在 NAS 上执行 sudo cat /vol1/1000/docker/mimivent/.env 可取得 MQTT_USERNAME / MQTT_PASSWORD。'),
            TextField(
              controller: brokerHost,
              decoration: const InputDecoration(
                  labelText: 'NAS 局域网地址',
                  hintText: '例如 192.168.1.20',
                  helperText: '通常与上面的 NAS 网关使用同一台 NAS。'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
            ),
            TextField(
              controller: brokerPort,
              decoration: const InputDecoration(labelText: 'MQTT 端口'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: username,
              decoration: const InputDecoration(
                  labelText: 'MQTT 用户名', hintText: '部署配置中的 MQTT_USERNAME'),
              autocorrect: false,
            ),
            TextField(
              controller: password,
              decoration: const InputDecoration(
                  labelText: 'MQTT 密码',
                  helperText: '与 NAS .env 和 Mosquitto 完全一致；建议使用至少 24 位随机密码'),
              obscureText: true,
              autocorrect: false,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: showNasSetupGuide,
                icon: const Icon(Icons.help_outline),
                label: const Text('在哪里查看 MQTT 账号？'),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并连接')),
        ],
      ),
    );
    if (configure == true && mounted) {
      _nasMqttStateReady = false;
      final port = int.tryParse(brokerPort.text.trim());
      await controller.run(() async {
        if (port == null ||
            port < 1 ||
            port > 65535 ||
            brokerHost.text.trim().isEmpty ||
            username.text.trim().isEmpty ||
            password.text.isEmpty) {
          throw StateError('请检查 NAS 地址、1–65535 端口、MQTT 用户名和密码');
        }
        final binding = await _ensureCurrentPhoneBinding();
        await controller.request('wifi.mqtt.configure', extra: {
          'payload': {
            'host': brokerHost.text.trim(),
            'port': port,
            'username': username.text.trim(),
            'password': password.text,
          }
        });
        mqttStatus = await _waitForMqttConnection();
        if (mqttStatus?['configured'] == true &&
            mqttStatus?['connected'] == true) {
          _nasMqttStateReady = await _waitForFreshNasState(binding);
        }
      }, clearData: false);
    }
    _disposeLater([brokerHost, brokerPort, username, password]);
    if (!mounted) return;
    setState(() {});
    if (configure == true && controller.error != null) {
      TopToast.show(context, 'NAS MQTT 配置未完成：${controller.error}');
    } else if (configure == true && _nasMqttStateReady) {
      await _showNasMqttReadyPrompt();
    } else if (configure == true) {
      TopToast.show(context, '配置已写入，但尚未确认 NAS MQTT 实时状态；可稍后刷新，无需重新填写。');
    }
  }

  Future<void> showNasSetupGuide() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('NAS 首次配置需要准备什么'),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('1. NAS 局域网地址',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text(
                    '先在 NAS 部署 MimiVent Gateway 和 MQTT Broker，并确认手机、NAS、设备在可互访的网络中。到飞牛网络设置查看 NAS 的局域网 IPv4。网关地址格式为 https://NAS-IP:8444；设备 MQTT 地址通常使用同一个 IP，端口 1883。不要使用 FN Connect 远程网址。'),
                SizedBox(height: 16),
                Text('2. HTTPS 证书指纹',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text('在 NAS 的 MimiVent 部署目录执行（路径按实际安装位置调整）：'),
                SizedBox(height: 6),
                SelectableText(
                    'openssl x509 -in tls/cert.pem -outform DER | sha256sum'),
                SizedBox(height: 4),
                Text('复制输出的 64 位十六进制 SHA-256 值。'),
                SizedBox(height: 16),
                Text('3. MQTT 用户名和密码',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text(
                    '从 NAS 部署配置的 .env 中取得 MQTT_USERNAME / MQTT_PASSWORD，并确认 Mosquitto 使用相同账号。它不是 NAS 管理员账号，也不要把密码发到公开 issue。App 通过蓝牙把凭据写入设备；App 本身不直接连接 Broker。'),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final b = c.selected;
    final s = c.status;
    final gateway = gatewayConfig;
    final gatewayConfigured =
        (gateway?['certificatePin']?.isNotEmpty ?? false) &&
            (gateway?['url']?.isNotEmpty ?? false);
    final gatewayEnabled = gateway?['enabled'] == 'true' && gatewayConfigured;
    final mqttConfigured = mqttStatus?['configured'] == true;
    final mqttConnected = mqttStatus?['connected'] == true;
    final stateAgeMs = s?['stateAgeMs'] ?? s?['sampleAgeMs'];
    final accessMatches = _gatewayAccessMatchesSelection;
    final gatewayAuthorized = accessMatches && _gatewayAccessValid;
    final canVerifyGateway = b != null &&
        b.state == 'active' &&
        !_gatewayAccessChecking &&
        !(accessMatches && _gatewayAccessRejected) &&
        !c.busy;
    // 让页面先按本机有效记录提供操作入口；网关仍会验证 Bearer。
    // 首次 listApps 请求还在路上时不能要求用户额外点一次“验证 NAS”。
    final canGenerateJoinCode = b != null &&
        b.state == 'active' &&
        gatewayConfigured &&
        !_gatewayAccessRejected &&
        !c.busy;
    return Scaffold(
        appBar: AppBar(title: const Text('设备网络与 NAS 控制')),
        body: SingleChildScrollView(
            key: const PageStorageKey("wifi-binding-nas-list"),
            padding: const EdgeInsets.all(16),
            // 用 Column 而不是 ListView：本页 children 数量随 records/status 变化，
            // Sliver 的按索引复用会让 element 树错位（sliver_multi_box_adaptor 断言）。
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('首次设置按顺序完成三步。设备 WiFi 负责联网；NAS MQTT 负责控制和同步状态。',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: c.busy ? null : importNasSetupQr,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('扫码或选择图片，快速配置 NAS'),
                  ),
                  const SizedBox(height: 8),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed:
                        canGenerateJoinCode ? () => showJoinCode(b) : null,
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('生成加入二维码（给另一部手机）'),
                  ),
                  if (!canGenerateJoinCode)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      child: Text(
                        b == null || b.state != 'active'
                            ? '完成设备服务授权后，已授权手机才能生成邀请。'
                            : _gatewayAccessChecking
                                ? '正在验证网关权限…'
                                : !gatewayAuthorized
                                    ? (_gatewayAccessMessage ??
                                        '请先验证此手机的 NAS 授权。')
                                    : '网关暂未确认此手机的访问权限，请先验证 NAS 授权。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: c.busy ? null : joinWithCode,
                    icon: const Icon(Icons.group_add),
                    label: const Text('用加入码加入已有服务'),
                  ),
                  const SizedBox(height: 8),
                  // P2：服务授权由 App 经网关 API 建立，不再依赖首配二维码。
                  OutlinedButton.icon(
                    onPressed: c.busy || !widget.ble.isConnected
                        ? null
                        : () async {
                            await controller.bind();
                            if (!mounted || !context.mounted) return;
                            await _refreshGatewayAccess(
                                binding: controller.selected);
                            if (!mounted || !context.mounted) return;
                            final ok = controller.error == null &&
                                controller.selected?.state == 'active';
                            TopToast.show(
                                context,
                                ok
                                    ? '服务授权已建立，NAS 控制通道已就绪'
                                    : (controller.error ?? '配置未完成'));
                            setState(() {});
                          },
                    icon: const Icon(Icons.link),
                    label: const Text('直接配置（使用已保存的网关）'),
                  ),
                  if (!widget.ble.isConnected)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('未连接蓝牙时可先识别并保存网关；配置设备 MQTT 前，请连接蓝牙后再次扫码。',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (_pendingNasSetupConfig != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('二维码配置已暂存于当前页面'),
                            const SizedBox(height: 4),
                            const Text(
                                '蓝牙若在扫码后断开，重新连接设备即可重试；无需再次扫描。退出此页面后，为保护密码不会保留这份临时配置。'),
                            const SizedBox(height: 8),
                            FilledButton.tonalIcon(
                              onPressed: c.busy || !widget.ble.isConnected
                                  ? null
                                  : applyPendingNasMqttConfig,
                              icon: Icon(widget.ble.isConnected
                                  ? Icons.bluetooth_connected
                                  : Icons.bluetooth_disabled),
                              label: Text(widget.ble.isConnected
                                  ? '通过蓝牙重试 MQTT 配置'
                                  : '请先连接蓝牙，再重试 MQTT 配置'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: showNasSetupGuide,
                      icon: const Icon(Icons.help_outline),
                      label: const Text('NAS 地址、证书和 MQTT 账号从哪里找'),
                    ),
                  ),
                  if (c.records.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      // 用字符串键而不是对象值：避免同值多 item 与对象引用比较的断言。
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('device-selector-${c.records.length}'),
                        value: b == null || !c.records.any((r) => r == b)
                            ? null
                            : '${b.deviceId}:${b.tokenId}',
                        decoration: const InputDecoration(labelText: '选择设备'),
                        items: [
                          for (final record in c.records)
                            DropdownMenuItem(
                              value: '${record.deviceId}:${record.tokenId}',
                              child: Text(
                                  '设备 ${record.deviceId.substring(0, 8)} · '
                                  '${record.state == 'active' ? '已绑定' : '需处理'}'),
                            ),
                        ],
                        onChanged: c.busy
                            ? null
                            : (key) {
                                if (key == null) return;
                                for (final record in c.records) {
                                  if ('${record.deviceId}:${record.tokenId}' ==
                                      key) {
                                    c.select(record);
                                    unawaited(
                                        _refreshGatewayAccess(binding: record));
                                    return;
                                  }
                                }
                              },
                      ),
                    ),
                  _setupStepCard(
                    number: '1',
                    icon: Icons.wifi,
                    title: '设备联网与手机绑定',
                    subtitle: b == null
                        ? '先让设备接入 2.4 GHz 家庭 WiFi，再用蓝牙连接并绑定此手机。'
                        : '当前设备：${b.deviceId.substring(0, 8)} · '
                            '${b.state == 'active' ? '本机已绑定' : '本机授权需恢复'}',
                    action: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      children: [
                        if (b == null && widget.ble.isConnected)
                          FilledButton.tonalIcon(
                            onPressed: c.busy
                                ? null
                                : () async {
                                    if (await confirm('绑定此设备',
                                            '确认手机当前通过蓝牙连接的是要添加的 MimiVent 设备？') &&
                                        mounted) {
                                      await c.bind();
                                    }
                                  },
                            icon: const Icon(Icons.bluetooth),
                            label: const Text('检查 WiFi 并绑定'),
                          ),
                        if (b != null &&
                            b.state != 'active' &&
                            widget.ble.isConnected)
                          FilledButton.tonalIcon(
                            onPressed: c.busy
                                ? null
                                : () async {
                                    if (await confirm('恢复此设备绑定',
                                            '确认手机当前通过蓝牙连接的是要恢复的 MimiVent 设备？') &&
                                        mounted) {
                                      await c.bind();
                                    }
                                  },
                            icon: const Icon(Icons.bluetooth),
                            label: const Text('恢复手机绑定'),
                          ),
                        if (widget.onOpenWifiProvisioning != null)
                          TextButton.icon(
                            onPressed:
                                c.busy ? null : widget.onOpenWifiProvisioning,
                            icon: const Icon(Icons.wifi),
                            label: const Text('配置设备 WiFi'),
                          ),
                      ],
                    ),
                  ),
                  if (b == null && !widget.ble.isConnected)
                    Padding(
                      padding: const EdgeInsets.only(left: 56, bottom: 8),
                      child: Text('请返回主页连接设备蓝牙，再继续绑定或配置 MQTT。',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  _setupStepCard(
                    number: '2',
                    icon: Icons.hub_outlined,
                    title: '设备连接 NAS MQTT',
                    subtitle: mqttStatus == null
                        ? '首次设置或更换 NAS 时配置。需要蓝牙连接设备。'
                        : mqttConfigured
                            ? 'Broker ${mqttStatus!['host']}:${mqttStatus!['port']} · '
                                '${mqttConnected ? '设备已连接' : '等待设备连接'}'
                            : '设备还没有 MQTT Broker 配置。',
                    action: FilledButton.tonalIcon(
                      onPressed: c.busy || !widget.ble.isConnected
                          ? null
                          : configureMqtt,
                      icon: const Icon(Icons.bluetooth),
                      label:
                          Text(mqttStatus == null ? '配置设备 MQTT' : '修改 MQTT 配置'),
                    ),
                  ),
                  if (!widget.ble.isConnected)
                    Padding(
                      padding: const EdgeInsets.only(left: 56, bottom: 8),
                      child: Text('配置设备 MQTT 需要先在主页连接蓝牙。',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  _setupStepCard(
                    number: '3',
                    icon: Icons.router_outlined,
                    title: 'App 连接 NAS 网关',
                    subtitle: gateway == null || !gatewayConfigured
                        ? '需要 NAS 局域网地址和 HTTPS 证书指纹；点页面顶部“配置说明”查看获取方法。'
                        : gatewayEnabled
                            ? '配置已保存：${gateway['url']}。读取状态可验证是否连通。'
                            : '配置已保存但未启用：${gateway['url']}',
                    action: FilledButton.tonalIcon(
                      onPressed: c.busy ? null : configureNasGateway,
                      icon: const Icon(Icons.tune),
                      label: Text(gatewayEnabled ? '修改网关设置' : '设置 NAS 网关'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed:
                        canVerifyGateway ? () => _verifyNasState(b) : null,
                    icon: _gatewayAccessChecking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: const Text('验证 NAS 授权并读取设备状态'),
                  ),
                  if (_gatewayAccessMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _gatewayAccessMessage!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _gatewayAccessRejected
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                      ),
                    ),
                  if (s != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.check_circle_outline),
                              const SizedBox(width: 8),
                              Text('设备状态已从 NAS 读取',
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                            ]),
                            const SizedBox(height: 8),
                            Text('风机：${s['fan'] == true ? '运行' : '待机'}  ·  '
                                '模式：${s['mode']}  ·  阶段：${s['phase']}'),
                            Text(
                                '固件 ${s['firmware']}  ·  NAS 收到状态 ${_stateAgeLabel(stateAgeMs)}'),
                          ],
                        ),
                      ),
                    ),
                  if (c.hasPendingControl)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('上一条 MQTT 控制结果待核对',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                                '${_pendingAgeLabel(c.pendingRequestAgeMs, c.pendingRequestAgeEstimated)}。上次操作可能已执行，请先检查设备状态。'),
                            TextButton(
                              onPressed: c.busy
                                  ? null
                                  : () async {
                                      if (await confirm('结束上次控制结果确认',
                                              '请先核对设备实际状态。结束确认后，下一次操作会发送新命令。',
                                              confirmLabel: '我已核对并结束') &&
                                          mounted) {
                                        await c.finishPendingConfirmation();
                                      }
                                    },
                              child: const Text('核对设备后结束确认'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (c.controlNotice != null || c.error != null)
                    Card(
                      color: c.error == null
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(c.error ?? c.controlNotice!),
                      ),
                    ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    leading: const Icon(Icons.build_outlined),
                    title: const Text('绑定管理与恢复（高级）'),
                    subtitle: const Text('撤销手机授权、清理本机记录等少用操作'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      if (b != null)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('绑定状态'),
                          subtitle: Text(b.state == 'active'
                              ? '此手机已授权'
                              : '授权状态：${b.state}'),
                          trailing: TextButton(
                            onPressed: c.busy || !widget.ble.isConnected
                                ? null
                                : () async {
                                    if (await confirm(
                                            '绑定或恢复此设备', '请确认当前蓝牙连接的是要管理的设备。') &&
                                        mounted) {
                                      await c.bind();
                                    }
                                  },
                            child: const Text('绑定 / 恢复'),
                          ),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('管理已授权手机'),
                        subtitle: const Text('每部已加入的手机都可以邀请或撤销成员'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: c.busy ||
                                _managingApps ||
                                !gatewayAuthorized
                            ? null
                            : manageClients,
                      ),
                      if (b != null)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('移除此手机的设备记录'),
                          subtitle: const Text('只清理本机记录，不会撤销设备端授权'),
                          onTap: c.busy
                              ? null
                              : () async {
                                  if (await confirm(
                                          '移除本机记录', '设备仍保留对此手机的授权。') &&
                                      mounted) {
                                    await c.run(c.removeSelected);
                                  }
                                },
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('重置设备服务授权'),
                        subtitle: const Text('所有已授权手机均可重置；重置操作需连接蓝牙'),
                        textColor: Theme.of(context).colorScheme.error,
                        onTap: c.busy || !widget.ble.isConnected
                            ? null
                            : () async {
                                if (await confirm('重置设备服务授权',
                                        '会清除设备 token、NAS 服务凭据和所有手机授权。重置后需重新配置设备，并重新邀请每部手机。确定重置？') &&
                                    mounted) {
                                  await c.resetDeviceServiceAuthorization();
                                }
                              },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('重置本机 WiFi 凭据'),
                        subtitle: const Text('仅用于安全存储损坏后的恢复；需重新绑定'),
                        onTap: c.busy
                            ? null
                            : () async {
                                if (await confirm('重置本机 WiFi 凭据',
                                        '删除本机保存的 WiFi 凭据和加密密钥。设备端授权不会删除。') &&
                                    mounted) {
                                  await c.resetLocalRecords();
                                }
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('主页负责日常控制；本页用于联网、绑定和 NAS 连接设置。固件升级仍通过蓝牙完成。',
                      style: Theme.of(context).textTheme.bodySmall),
                ])));
  }

  Widget _setupStepCard({
    required String number,
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 18,
                    child: Text(number,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 12),
                  Icon(icon, size: 21),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(subtitle,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
              if (action != null) ...[
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            ],
          ),
        ),
      );
}
