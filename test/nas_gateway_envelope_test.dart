import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/features/local_network/nas_gateway_models.dart';

void main() {
  test('validates gateway route identity, not the statistics dataset identity', () {
    final envelope = <String, dynamic>{'schemaVersion': 1, 'deviceId': 'a' * 32, 'statusCode': 200, 'body': <String, dynamic>{'deviceId': '0123456789abcdef'}};
    expect(() => validateGatewayReadDeviceId(envelope, 'a' * 32), returnsNormally);
  });
  test('rejects a gateway envelope routed for another bound device', () {
    final envelope = <String, dynamic>{'schemaVersion': 1, 'deviceId': 'b' * 32, 'statusCode': 200, 'body': <String, dynamic>{'deviceId': '0123456789abcdef'}};
    expect(() => validateGatewayReadDeviceId(envelope, 'a' * 32), throwsA(isA<NasGatewayException>().having((error) => error.code, 'code', 'DEVICE_MISMATCH')));
  });
}
