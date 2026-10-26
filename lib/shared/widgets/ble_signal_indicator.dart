import 'package:flutter/material.dart';

import '../../app/theme/mimivent_theme.dart';

/// 将 BLE RSSI 数值同时显示为直观的中文信号等级。
class BleSignalIndicator extends StatelessWidget {
  const BleSignalIndicator({
    required this.rssi,
    this.fontSize = 12,
    super.key,
  });

  final int rssi;
  final double fontSize;

  String get _label {
    if (rssi >= -60) return '强';
    if (rssi >= -75) return '中';
    if (rssi >= -90) return '弱';
    return '很弱';
  }

  Color get _color {
    if (rssi >= -60) return MimiVentColors.mint;
    if (rssi >= -75) return MimiVentColors.amber;
    if (rssi >= -90) return const Color(0xFFFF9B62);
    return MimiVentColors.red;
  }

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.signal_cellular_alt_rounded,
              color: _color, size: fontSize + 4),
          const SizedBox(width: 4),
          Text(
            '信号$_label · $rssi dBm',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _color,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}
