import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/wifi_control/wifi_serial_executor.dart';

void main() {
  test('外部请求不能因已有任务运行而绕过队列，内部读取可重入', () async {
    final queue = WifiSerialExecutor();
    final release = Completer<void>();
    final started = Completer<void>();
    final order = <String>[];
    final first = queue.run(() async {
      order.add('first');
      await queue.run(() async => order.add('nested'));
      started.complete();
      await release.future;
      order.add('first-end');
    });
    await started.future;
    final second = queue.run(() async => order.add('second'));
    await Future<void>.delayed(Duration.zero);
    expect(order, ['first', 'nested']);
    release.complete();
    await Future.wait([first, second]);
    expect(order, ['first', 'nested', 'first-end', 'second']);
  });

  test('失败后继续执行，优先任务插在等待队列前面', () async {
    final queue = WifiSerialExecutor();
    final release = Completer<void>();
    final order = <String>[];
    final failed = queue.run<void>(() async {
      await release.future;
      throw StateError('read failed');
    });
    final failure = expectLater(failed, throwsStateError);
    final normal = queue.run(() async => order.add('normal'));
    final urgent = queue.run(() async => order.add('urgent'), priority: true);
    release.complete();
    await failure;
    await Future.wait([normal, urgent]);
    expect(order, ['urgent', 'normal']);
  });
}
