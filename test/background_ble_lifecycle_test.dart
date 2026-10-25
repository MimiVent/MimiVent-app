import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/background_ble_lifecycle.dart';

void main() {
  test('短暂切到后台再回来时保留 BLE 连接', () async {
    var closeCount = 0;
    var resumeCount = 0;
    final lifecycle = BackgroundBleLifecycle(
      closeSession: () async => closeCount++,
      resumeSession: () async => resumeCount++,
      gracePeriod: const Duration(milliseconds: 40),
    );

    lifecycle.onBackground();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await lifecycle.onForeground();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(closeCount, 0);
    expect(resumeCount, 0);
    lifecycle.dispose();
  });

  test('后台超过宽限期后断开，回前台恢复扫描', () async {
    var closeCount = 0;
    var resumeCount = 0;
    final lifecycle = BackgroundBleLifecycle(
      closeSession: () async => closeCount++,
      resumeSession: () async => resumeCount++,
      gracePeriod: const Duration(milliseconds: 10),
    );

    lifecycle.onBackground();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await lifecycle.onForeground();

    expect(closeCount, 1);
    expect(resumeCount, 1);
    lifecycle.dispose();
  });

  test('恢复时等待尚未完成的断开，再开始扫描', () async {
    final closeCompleter = Completer<void>();
    final events = <String>[];
    final lifecycle = BackgroundBleLifecycle(
      closeSession: () {
        events.add('close-start');
        return closeCompleter.future
            .whenComplete(() => events.add('close-end'));
      },
      resumeSession: () async => events.add('resume'),
      gracePeriod: const Duration(milliseconds: 1),
    );

    lifecycle.onBackground();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final resume = lifecycle.onForeground();
    await Future<void>.delayed(Duration.zero);

    expect(events, ['close-start']);
    closeCompleter.complete();
    await resume;

    expect(events, ['close-start', 'close-end', 'resume']);
    lifecycle.dispose();
  });

  test('新一轮后台期间收到 detached 时仍立即关闭当前会话', () async {
    var closeCount = 0;
    var resumeCount = 0;
    final lifecycle = BackgroundBleLifecycle(
      closeSession: () async => closeCount++,
      resumeSession: () async => resumeCount++,
      gracePeriod: const Duration(milliseconds: 5),
    );

    lifecycle.onBackground();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    await lifecycle.onForeground();
    lifecycle.onBackground();
    await lifecycle.closeImmediately();

    expect(closeCount, 2);
    expect(resumeCount, 1);
    lifecycle.dispose();
  });
}
