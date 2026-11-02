import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/ble/ble_gatt_scheduler.dart';

void main() {
  test('GATT 操作按提交顺序串行执行', () async {
    final scheduler = BleGattScheduler();
    final firstGate = Completer<void>();
    final order = <String>[];

    final first = scheduler.run(() async {
      order.add('first-start');
      await firstGate.future;
      order.add('first-end');
    });
    final second = scheduler.run(() async {
      order.add('second');
    });

    await Future<void>.delayed(Duration.zero);
    expect(order, ['first-start']);
    firstGate.complete();
    await Future.wait([first, second]);
    expect(order, ['first-start', 'first-end', 'second']);
  });

  test('操作失败后队列仍可继续', () async {
    final scheduler = BleGattScheduler();
    await expectLater(
      scheduler.run<void>(() => Future<void>.error(StateError('failed'))),
      throwsStateError,
    );
    expect(await scheduler.run(() async => 7), 7);
  });
}
