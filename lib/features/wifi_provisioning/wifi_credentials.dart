import 'dart:convert';

bool isValidWifiSsid(String ssid) {
  final length = utf8.encode(ssid).length;
  return length >= 1 && length <= 32;
}

bool isValidWifiPassword(String password) {
  if (password.length == 64) {
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(password);
  }
  return password.length >= 8 &&
      password.length <= 63 &&
      RegExp(r'^[\x20-\x7E]+$').hasMatch(password);
}
