import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/transport/ota_capabilities.dart';

void main() {
  group('OtaCapabilities', () {
    test('parses V2 capabilities and validates required upload features', () {
      final capabilities = OtaCapabilities.parse(
        'CAPS|2|resume=1|pause=1|install=1|maxChunk=512|window=4|'
        'checkpoint=16384|sha256=1|signature=1|signatureFormat=1|'
        'packageFormat=2|deltaFormat=2|downgrade=1|'
        'partitionProfile=statistics-v2-ota-v1|deviceId=ABC123',
      );

      expect(capabilities.protocolVersion, 2);
      expect(capabilities.intValue('maxChunk'), 512);
      expect(capabilities.supportsRequiredV2, isTrue);
    });

    test('rejects incomplete and malformed V2 capability declarations', () {
      expect(
        OtaCapabilities.parse('CAPS|2|resume=1|pause=1|deviceId=ABC')
            .supportsRequiredV2,
        isFalse,
      );
      expect(
        OtaCapabilities.parse('CAPS|2|resume=1|pause=1|install=1|sha256=1|'
                'maxChunk=bogus|window=4|deviceId=ABC')
            .supportsRequiredV2,
        isFalse,
      );
    });

    test('keeps legacy command errors separate from OTA V2', () {
      expect(OtaCapabilities.parse('ERROR|COMMAND').protocolVersion, isNull);
      expect(
          OtaCapabilities.parse('CAPS|1|resume=0').supportsRequiredV2, isFalse);
    });

    test('allows signed full OTA without requiring delta capability', () {
      final capabilities = OtaCapabilities.parse(
        'CAPS|2|resume=1|pause=1|install=1|maxChunk=512|window=4|'
        'checkpoint=16384|sha256=1|signature=1|signatureFormat=1|'
        'packageFormat=2|partitionProfile=statistics-v2-ota-v1|deviceId=ABC123',
      );

      expect(capabilities.supportsRequiredV2, isTrue);
      expect(capabilities.supportsDeltaV2, isFalse);
    });
  });
}
