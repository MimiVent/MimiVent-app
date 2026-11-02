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

    if (j['version'] != 1 || j['port'] != 8443 || j['scheme'] != 'https') {
      throw const FormatException('绑定版本或地址无效');
    }
    return WifiBinding(
        deviceId: read('deviceId', r'^[0-9a-f]{32}$'),
        tokenId: read('tokenId', r'^[0-9a-f]{32}$'),
        token: read('token', r'^[A-Za-z0-9_-]{43}$'),
        pin: read('certPinSha256', r'^[0-9a-f]{64}$'),
        host: read('host', r'^[a-zA-Z0-9][a-zA-Z0-9.\-]{0,252}$'),
        clientId: read('clientId', r'^[A-Za-z0-9_-]{1,36}$'),
        state: read('bindingState', r'^(pending|active|invalid|blocked)$'));
  }
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
