import 'package:flutter/material.dart';

import '../../app/theme/mimivent_theme.dart';
import 'modal_coordinator.dart';

/// 统一 App 内需要用户确认的操作弹窗，避免各页面样式与按钮行为漂移。
class MimiVentDialogs {
  const MimiVentDialogs._();

  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String detail = '',
    String confirmLabel = '确认',
    bool danger = false,
    ModalCoordinator? coordinator,
  }) async {
    Future<bool> show() async =>
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF182A26),
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: MimiVentColors.muted,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      danger ? MimiVentColors.red : MimiVentColors.mint,
                  foregroundColor: MimiVentColors.darkText,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
    return coordinator == null
        ? show()
        : coordinator.confirm(context, show: show);
  }
}
