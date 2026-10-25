import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/ble/ble_disconnect_gate.dart';

void main() {
  test('忽略连接前回放的断开状态，连接建立后才处理真实断开', () {
    final gate = BleDisconnectGate();

    expect(gate.shouldHandle(connected: false, isCurrentDevice: true), isFalse);
    expect(gate.shouldHandle(connected: true, isCurrentDevice: true), isFalse);
    expect(gate.shouldHandle(connected: false, isCurrentDevice: true), isTrue);
    expect(gate.shouldHandle(connected: false, isCurrentDevice: true), isFalse);
  });

  test('忽略已经过期设备的连接状态事件', () {
    final gate = BleDisconnectGate();

    expect(gate.shouldHandle(connected: true, isCurrentDevice: false), isFalse);
    expect(gate.shouldHandle(connected: false, isCurrentDevice: false), isFalse);
    expect(gate.shouldHandle(connected: false, isCurrentDevice: true), isFalse);
  });
}
