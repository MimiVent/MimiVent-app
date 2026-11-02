import 'package:flutter/foundation.dart';

enum DeviceChannel { none, wifi, ble }

/// 统一连接状态：决定当前实际使用的控制通道，并驱动顶部状态展示。
class DeviceConnectionManager extends ChangeNotifier {
  bool _wifi = false;
  bool _ble = false;
  bool _connecting = false;
  bool _preferBle = false;

  bool get wifiAvailable => _wifi;
  bool get bleAvailable => _ble;
  bool get connecting => _connecting;

  DeviceChannel get channel {
    if (_preferBle && _ble) return DeviceChannel.ble;
    if (_wifi) return DeviceChannel.wifi;
    if (_ble) return DeviceChannel.ble;
    return DeviceChannel.none;
  }

  String get label {
    if (_connecting && channel == DeviceChannel.none) return '正在连接设备…';
    switch (channel) {
      case DeviceChannel.wifi:
        return 'WiFi 控制';
      case DeviceChannel.ble:
        return '蓝牙控制';
      case DeviceChannel.none:
        return '设备未连接';
    }
  }

  String get detail {
    if (_ble && _wifi) return '蓝牙控制，WiFi 备用';
    if (_wifi) return 'WiFi 控制 · 已核验';
    if (_ble) return '蓝牙控制 · 已连接';
    return '没有可用的控制通道';
  }

  void update({bool? wifi, bool? ble, bool? connecting, bool? preferBle}) {
    final nextWifi = wifi ?? _wifi;
    final nextBle = ble ?? _ble;
    final nextConnecting = connecting ?? _connecting;
    final nextPreferBle = preferBle ?? _preferBle;
    if (nextWifi == _wifi &&
        nextBle == _ble &&
        nextConnecting == _connecting &&
        nextPreferBle == _preferBle) {
      return;
    }
    _wifi = nextWifi;
    _ble = nextBle;
    _connecting = nextConnecting;
    _preferBle = nextPreferBle;
    notifyListeners();
  }
}
