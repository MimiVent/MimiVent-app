/// NAS 首次配置信息。MQTT 密码仅在扫码到蓝牙下发期间保留在内存中。
class NasSetupConfig {
  const NasSetupConfig({
    required this.host,
    required this.gatewayPort,
    required this.certificatePin,
    required this.mqttPort,
    required this.mqttUsername,
    required this.mqttPassword,
  });

  final String host;
  final int gatewayPort;
  final String certificatePin;
  final int mqttPort;
  final String mqttUsername;
  final String mqttPassword;

  String get gatewayUrl => 'https://$host:$gatewayPort';

  static NasSetupConfig parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'mimivent' ||
        uri.host != 'nas' ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('二维码不是有效的 MimiVent NAS 配置');
    }
    final query = uri.queryParametersAll;
    const requiredKeys = {
      'host',
      'gwPort',
      'pin',
      'mqttPort',
      'mqttUser',
      'mqttPass',
    };
    if (!requiredKeys.every((key) => query[key]?.length == 1)) {
      throw const FormatException('二维码配置字段缺失或重复，请从 NAS 设置页重新生成');
    }
    final host = query['host']!.single.trim();
    final gatewayPort = int.tryParse(query['gwPort']!.single);
    final mqttPort = int.tryParse(query['mqttPort']!.single);
    final pin = query['pin']!.single.toLowerCase();
    final username = query['mqttUser']!.single;
    final password = query['mqttPass']!.single;
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.\-]{0,252}$').hasMatch(host)) {
      throw const FormatException('NAS 地址无效');
    }
    if (gatewayPort == null ||
        gatewayPort < 1 ||
        gatewayPort > 65535 ||
        mqttPort == null ||
        mqttPort < 1 ||
        mqttPort > 65535) {
      throw const FormatException('网关或 MQTT 端口无效');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)) {
      throw const FormatException('证书指纹必须为 64 位 SHA-256');
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw const FormatException('MQTT 用户名或密码为空');
    }
    return NasSetupConfig(
      host: host,
      gatewayPort: gatewayPort,
      certificatePin: pin,
      mqttPort: mqttPort,
      mqttUsername: username,
      mqttPassword: password,
    );
  }
}
