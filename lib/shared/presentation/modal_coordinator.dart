import 'package:flutter/widgets.dart';

/// 限制页面同时只展示一个受协调的弹窗；重复触发时按取消处理，避免确认串台。
class ModalCoordinator {
  bool _confirmationOpen = false;

  Future<T?> present<T>(
    BuildContext context, {
    required Future<T?> Function() show,
  }) async {
    if (_confirmationOpen || !context.mounted) return null;
    _confirmationOpen = true;
    try {
      return await show();
    } finally {
      _confirmationOpen = false;
    }
  }

  Future<bool> confirm(
    BuildContext context, {
    required Future<bool> Function() show,
  }) async =>
      await present<bool>(context, show: show) ?? false;
}
