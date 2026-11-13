import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';

void main() {
  test('shows the accepted device clock source explicitly', () {
    expect(timeSyncSourceLabel('phone'), '手机蓝牙');
    expect(timeSyncSourceLabel('nas'), 'NAS MQTT');
    expect(timeSyncSourceLabel('none'), '未同步');
    expect(timeSyncSourceLabel(null), '未知');
  });
}
