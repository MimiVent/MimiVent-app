import 'package:flutter/material.dart';

import '../../data/device_connection_manager.dart';

class ConnectionStatusBadge extends StatelessWidget {
  const ConnectionStatusBadge({
    required this.connection,
    this.onTap,
    super.key,
  });

  final DeviceConnectionManager connection;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: connection,
        builder: (context, _) {
          final color = switch (connection.channel) {
            DeviceChannel.nasMqtt => const Color(0xFF6FE3C1),
            DeviceChannel.ble => const Color(0xFF8DB7FF),
            DeviceChannel.none => const Color(0xFFFF8A80),
          };
          final icon = switch (connection.channel) {
            DeviceChannel.nasMqtt => Icons.cloud_sync_outlined,
            DeviceChannel.ble => Icons.bluetooth,
            DeviceChannel.none => Icons.link_off,
          };
          return Material(
            color: color.withOpacity(.12),
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 13, color: color),
                  const SizedBox(width: 4),
                  Text(connection.label,
                      style: TextStyle(
                          color: color,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          );
        },
      );
}
