import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/firmware_update/ota_storage_compatibility.dart';

void main() {
  test('升级也必须位于目标可读区间，未知格式保守阻止', () {
    for (final device in [4, 5, 8]) {
      expect(canReadStorageSchema(deviceSchema: device, targetSchema: 7,
          minimumReadableSchema: 6), isFalse);
    }
    for (final device in [6, 7]) {
      expect(canReadStorageSchema(deviceSchema: device, targetSchema: 7,
          minimumReadableSchema: 6), isTrue);
    }
    expect(canReadStorageSchema(deviceSchema: null, targetSchema: 7), isFalse);
    expect(canReadStorageSchema(deviceSchema: 7, targetSchema: null), isFalse);
    expect(canReadStorageSchema(deviceSchema: 6, targetSchema: 7), isFalse);
    expect(canReadStorageSchema(deviceSchema: 7, targetSchema: 7), isTrue);
  });
}
