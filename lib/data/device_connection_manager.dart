import 'package:flutter/foundation.dart';

enum DeviceChannel { none, nasMqtt, ble }

/// 统一连接状态：决定当前实际使用的控制通道，并驱动顶部状态展示。
class DeviceConnectionManager extends ChangeNotifier {
  bool _nasMqtt = false;
  bool _ble = false;
  bool _connecting = false;
  bool _preferBle = false;

  bool get nasMqttAvailable => _nasMqtt;
  bool get bleAvailable => _ble;
  bool get connecting => _connecting;

  DeviceChannel get channel {
    if (_preferBle && _ble) return DeviceChannel.ble;
    if (_nasMqtt) return DeviceChannel.nasMqtt;
    if (_ble) return DeviceChannel.ble;
    return DeviceChannel.none;
  }

  String get label {
    if (_connecting && channel == DeviceChannel.none) return '正在连接设备…';
    switch (channel) {
      case DeviceChannel.nasMqtt:
        return 'NAS MQTT 控制';
      case DeviceChannel.ble:
        return '蓝牙控制';
      case DeviceChannel.none:
        return '设备未连接';
    }
  }

  String get detail {
    if (_ble && _nasMqtt) return 'NAS MQTT 控制，蓝牙可用';
    if (_nasMqtt) return 'NAS MQTT 控制 · 已连接';
    if (_ble) return '蓝牙控制 · 已连接';
    return '没有可用的控制通道';
  }

  void update({bool? nasMqtt, bool? ble, bool? connecting, bool? preferBle}) {
    final nextNasMqtt = nasMqtt ?? _nasMqtt;
    final nextBle = ble ?? _ble;
    final nextConnecting = connecting ?? _connecting;
    final nextPreferBle = preferBle ?? _preferBle;
    if (nextNasMqtt == _nasMqtt &&
        nextBle == _ble &&
        nextConnecting == _connecting &&
        nextPreferBle == _preferBle) {
      return;
    }
    _nasMqtt = nextNasMqtt;
    _ble = nextBle;
    _connecting = nextConnecting;
    _preferBle = nextPreferBle;
    notifyListeners();
  }
}
