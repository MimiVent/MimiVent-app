import 'package:flutter/material.dart';

import '../../app/theme/mimivent_theme.dart';

/// 提示 App 与设备固件的最低兼容版本和完整功能推荐版本。
class VersionCompatibilityNotice extends StatelessWidget {
  const VersionCompatibilityNotice({
    required this.appVersion,
    required this.firmwareVersion,
    this.minimumAppVersion,
    super.key,
  });

  static const recommendedFirmwareVersion = '0.3.1';

  final String appVersion;
  final String firmwareVersion;
  final String? minimumAppVersion;

  @override
  Widget build(BuildContext context) {
    final minimumApp = minimumAppVersion;
    final appComparison =
        minimumApp == null ? null : _compareVersions(appVersion, minimumApp);
    if (minimumApp != null && appComparison != null && appComparison < 0) {
      return _notice(
        icon: Icons.system_update_alt_rounded,
        title: '请更新 MimiVent App',
        detail: '当前 App v$appVersion，设备要求 v$minimumApp 或更新版本。',
        color: MimiVentColors.red,
      );
    }

    final firmware = _compareVersions(firmwareVersion, '0.2.0');
    if (firmware == null) {
      return _notice(
        icon: Icons.help_outline_rounded,
        title: '无法确认固件兼容性',
        detail: '当前固件版本为 $firmwareVersion，请更新到 v$recommendedFirmwareVersion。',
        color: MimiVentColors.amber,
      );
    }
    if (firmware < 0) {
      return _notice(
        icon: Icons.warning_amber_rounded,
        title: '固件版本过旧',
        detail: '当前 v$firmwareVersion 低于 App 控制接口最低要求 v0.2.0，请先更新固件。',
        color: MimiVentColors.red,
      );
    }

    final recommended = _compareVersions(
      firmwareVersion,
      recommendedFirmwareVersion,
    );
    if (recommended != null && recommended < 0) {
      return _notice(
        icon: Icons.system_update_alt_rounded,
        title: '建议更新设备固件',
        detail: '当前控制仍可使用；完整统计功能建议固件 v$recommendedFirmwareVersion。',
        color: MimiVentColors.amber,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _notice({
    required IconData icon,
    required String title,
    required String detail,
    required Color color,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: color.withOpacity(.09),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withOpacity(.22)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 17),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(detail,
                      style: const TextStyle(
                          color: MimiVentColors.muted,
                          fontSize: 10,
                          height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// 比较 x.y.z 版本；无法解析时返回 null，避免把未知格式误判成旧版本。
int? _compareVersions(String current, String required) {
  final currentParts = _parseVersion(current);
  final requiredParts = _parseVersion(required);
  if (currentParts == null || requiredParts == null) return null;
  for (var index = 0; index < 3; index++) {
    final comparison = currentParts[index].compareTo(requiredParts[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

List<int>? _parseVersion(String value) {
  final match =
      RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$').firstMatch(value.trim());
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}
