/// 设备通过 OTA CAPS 声明的协议能力。
class OtaCapabilities {
  const OtaCapabilities({required this.protocolVersion, required this.values});

  final int? protocolVersion;
  final Map<String, String> values;

  factory OtaCapabilities.parse(String wireValue) {
    final fields = wireValue.split('|');
    final version = fields.isNotEmpty && fields.first == 'CAPS'
        ? int.tryParse(fields.length > 1 ? fields[1] : '')
        : null;
    final values = <String, String>{};
    for (final field in fields.skip(2)) {
      final separator = field.indexOf('=');
      if (separator > 0) {
        values[field.substring(0, separator)] = field.substring(separator + 1);
      }
    }
    return OtaCapabilities(protocolVersion: version, values: values);
  }

  String? operator [](String key) => values[key];
  int? intValue(String key) => int.tryParse(values[key] ?? '');

  bool get supportsRequiredV2 =>
      protocolVersion == 2 &&
      this['resume'] == '1' &&
      this['pause'] == '1' &&
      this['install'] == '1' &&
      this['sha256'] == '1' &&
      this['signature'] == '1' &&
      this['signatureFormat'] == '1' &&
      this['packageFormat'] == '2' &&
      this['partitionProfile']?.isNotEmpty == true &&
      this['deviceId']?.isNotEmpty == true &&
      (intValue('maxChunk') ?? 0) >= 9 &&
      (intValue('window') ?? 0) > 0 &&
      (intValue('checkpoint') ?? 0) > 0;

  bool get supportsDeltaV2 =>
      supportsRequiredV2 && this['delta'] == '1' && this['deltaFormat'] == '2';
}
