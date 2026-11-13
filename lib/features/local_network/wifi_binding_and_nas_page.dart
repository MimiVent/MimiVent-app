import 'package:flutter/material.dart';

import '../../shared/widgets/top_toast.dart';
import '../../ble/mimivent_ble_manager.dart';
import 'nas_setup_config.dart';
import 'nas_setup_qr_scanner_page.dart';
import 'wifi_binding_controller.dart';
import 'wifi_binding.dart';

class WifiBindingAndNasPage extends StatefulWidget {
  const WifiBindingAndNasPage(
      {required this.ble, this.onOpenWifiProvisioning, super.key});
  final MimiVentBleManager ble;
  final VoidCallback? onOpenWifiProvisioning;
  @override
  State<WifiBindingAndNasPage> createState() => _WifiBindingAndNasPageState();
}

class _WifiBindingAndNasPageState extends State<WifiBindingAndNasPage> {
  late final WifiBindingController controller;
  Map<String, dynamic>? mqttStatus;
  Map<String, String>? gatewayConfig;
  NasSetupConfig? _pendingNasSetupConfig;
  bool _nasMqttStateReady = false;
  @override
  void initState() {
    super.initState();
    controller = WifiBindingController(widget.ble);
    controller.addListener(changed);
    widget.ble.addListener(changed);
    controller.load();
    controller.gatewayTransport.loadConfig().then((value) {
      if (!mounted) return;
      setState(() => gatewayConfig = value);
    });
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
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
    Map<String, dynamic>? data;
    await controller.run(() async {
      data = await controller.listDeviceClients();
    });
    if (!mounted || data == null || controller.error != null) return;
    final clients = (data!['clients'] as List).cast<Map>();
    final id = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('管理设备绑定'),
                content: clients.isEmpty
                    ? const Text('设备尚未绑定客户端')
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final client in clients)
                          TextButton(
                              onPressed: () => Navigator.pop(
                                  context, client['tokenId'] as String),
                              child: Text('撤销客户端 ${client['clientId']}')),
                      ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'))
                ]));
    if (!mounted || id == null) return;
    if (await confirm('撤销此客户端', '该客户端将无法继续通过 WiFi 访问设备。其他客户端不受影响。') &&
        mounted) {
      await controller.revokeDeviceClient(data!['deviceId'] as String, id);
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
    url.dispose();
    pin.dispose();
    bulk.dispose();
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
      if (latest['configured'] == true && latest['connected'] == true) {
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
          body?['tokenId'] == binding.tokenId &&
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
      // 将切换意图交给打开此页的路由，由首页完成通道切换。
      Navigator.of(context).pop(true);
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
    brokerHost.dispose();
    brokerPort.dispose();
    username.dispose();
    password.dispose();
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
    return Scaffold(
        appBar: AppBar(title: const Text('设备网络与 NAS 控制')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('首次设置按顺序完成三步。设备 WiFi 负责联网；NAS MQTT 负责控制和同步状态。',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: c.busy ? null : importNasSetupQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('扫码或选择图片，快速配置 NAS'),
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
              child: DropdownButtonFormField<WifiBinding>(
                value: b,
                decoration: const InputDecoration(labelText: '选择设备'),
                items: [
                  for (final record in c.records)
                    DropdownMenuItem(
                      value: record,
                      child: Text('设备 ${record.deviceId.substring(0, 8)} · '
                          '${record.state == 'active' ? '已绑定' : '需处理'}'),
                    ),
                ],
                onChanged: c.busy
                    ? null
                    : (value) {
                        if (value != null) c.select(value);
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
                if (b != null && b.state != 'active' && widget.ble.isConnected)
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
                    onPressed: c.busy ? null : widget.onOpenWifiProvisioning,
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
              onPressed:
                  c.busy || !widget.ble.isConnected ? null : configureMqtt,
              icon: const Icon(Icons.bluetooth),
              label: Text(mqttStatus == null ? '配置设备 MQTT' : '修改 MQTT 配置'),
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
          if (b != null && b.state == 'active') ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: c.busy ? null : () => c.read(b.host),
              icon: const Icon(Icons.sync),
              label: const Text('验证 NAS 连接并读取设备状态'),
            ),
          ],
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
                          style: Theme.of(context).textTheme.titleSmall),
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
                  subtitle:
                      Text(b.state == 'active' ? '此手机已授权' : '授权状态：${b.state}'),
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
                subtitle: const Text('撤销某一台手机的设备访问权限'),
                trailing: const Icon(Icons.chevron_right),
                onTap: c.busy || !widget.ble.isConnected ? null : manageClients,
              ),
              if (b != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('移除此手机的设备记录'),
                  subtitle: const Text('只清理本机记录，不会撤销设备端授权'),
                  onTap: c.busy
                      ? null
                      : () async {
                          if (await confirm('移除本机记录', '设备仍保留对此手机的授权。') &&
                              mounted) {
                            await c.run(c.removeSelected);
                          }
                        },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('清除设备上的全部手机授权'),
                subtitle: const Text('所有手机都要重新绑定'),
                textColor: Theme.of(context).colorScheme.error,
                onTap: c.busy || !widget.ble.isConnected
                    ? null
                    : () async {
                        if (await confirm('清除设备端全部 WiFi 绑定',
                                '所有手机都需要重新绑定，当前手机也会失去授权。确定清除？') &&
                            mounted) {
                          await c.resetDeviceBindings();
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
        ]));
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
