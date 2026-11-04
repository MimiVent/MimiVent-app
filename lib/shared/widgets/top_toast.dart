import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/mimivent_theme.dart';

/// 顶部轻提示：不遮挡底部操作栏，也不拦截点击。
class TopToast {
  TopToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          bottom: false,
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) => Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, -8 * (1 - value)),
                        child: child,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16231F),
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                              color: MimiVentColors.mint.withOpacity(.20)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(.28),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                size: 16, color: MimiVentColors.mint),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                message,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  height: 1.35,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(duration, _dismiss);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    if (entry.mounted) entry.remove();
  }
}
