import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/wifi_provisioning/wifi_credentials.dart';

void main() {
  test('SSID 长度按 UTF-8 字节数校验', () {
    expect(isValidWifiSsid('MimiVent'), isTrue);
    expect(isValidWifiSsid(''), isFalse);
    expect(isValidWifiSsid(List.filled(10, '中').join()), isTrue);
    expect(isValidWifiSsid(List.filled(11, '中').join()), isFalse);
  });

  test('密码仅接受 ASCII 8–63 位或 64 位十六进制', () {
    expect(isValidWifiPassword('password'), isTrue);
    expect(isValidWifiPassword(List.filled(63, 'a').join()), isTrue);
    expect(isValidWifiPassword(List.filled(64, 'a').join()), isTrue);
    expect(isValidWifiPassword(List.filled(64, 'g').join()), isFalse);
    expect(isValidWifiPassword('短密码123'), isFalse);
    expect(isValidWifiPassword('short'), isFalse);
  });
}
