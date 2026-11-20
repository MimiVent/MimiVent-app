class WifiBinding {
  WifiBinding(
      {required this.deviceId,
      required this.tokenId,
      required this.token,
      required this.pin,
      required this.host,
      required this.clientId,
      required this.state});
  final String deviceId, tokenId, token, pin, host, clientId;
  final String state;
  WifiBinding copy({String? state, String? host}) => WifiBinding(
      deviceId: deviceId,
      tokenId: tokenId,
      token: token,
      pin: pin,
      host: host ?? this.host,
      clientId: clientId,
      state: state ?? this.state);
  factory WifiBinding.fromJson(Map<String, dynamic> j) {
    String read(String key, String pattern) {
      final value = j[key];
      if (value is! String || !RegExp(pattern).hasMatch(value)) {
        throw const FormatException('绑定记录格式无效');
      }
      return value;
    }

    // 设备 HTTPS 已下线，控制改走 NAS MQTT。旧记录里的 port/scheme/host/pin
    // 只用于兼容读取与展示，不再作为连接前提，也不应阻挡新格式记录。
    if (j['version'] != 1) {
      throw const FormatException('绑定版本无效');
    }
    String optional(String key, String pattern) {
      final value = j[key];
      if (value is! String) return '';
      return RegExp(pattern).hasMatch(value) ? value : '';
    }

    return WifiBinding(
        deviceId: read('deviceId', r'^[0-9a-f]{32}$'),
        tokenId: read('tokenId', r'^[0-9a-f]{32}$'),
        token: read('token', r'^[A-Za-z0-9_-]{43}$'),
        pin: optional('certPinSha256', r'^[0-9a-f]{64}$'),
        host: optional('host', r'^[a-zA-Z0-9][a-zA-Z0-9.\-]{0,252}$'),
        clientId: read('clientId', r'^[A-Za-z0-9_-]{1,36}$'),
        state: read('bindingState', r'^(pending|active|invalid|blocked)$'));
  }
  // 同一份凭据在内存里可能有多个副本（页面选中项来自 dashboard 或 records）。
  // DropdownButton 等控件按值比较，必须按身份字段判等而不是对象引用。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WifiBinding &&
          other.deviceId == deviceId &&
          other.tokenId == tokenId;

  @override
  int get hashCode => Object.hash(deviceId, tokenId);

  Map<String, dynamic> toJson() => {
        'version': 1,
        'scheme': 'https',
        'port': 8443,
        'deviceId': deviceId,
        'tokenId': tokenId,
        'token': token,
        'certPinSha256': pin,
        'host': host,
        'clientId': clientId,
        'bindingState': state
      };
}
