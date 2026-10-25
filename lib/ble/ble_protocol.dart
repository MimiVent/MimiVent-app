import 'dart:convert';

import '../app/app_identity.dart';

/// MimiVent 固件 BLE GATT 协议常量与分包响应解析。
/// 请求文本由换行分隔字段，响应格式为“状态码\n响应体\n”。
class BleProtocol {
  static const deviceName = AppIdentity.productName;
  static const serviceUuid = '6f9b0001-7d5a-4c3b-9a21-2f6d4d494d49';
  static const commandUuid = '6f9b0002-7d5a-4c3b-9a21-2f6d4d494d49';
  static const responseUuid = '6f9b0003-7d5a-4c3b-9a21-2f6d4d494d49';

  static String encodeRequest({
    required String method,
    required String path,
    String profile = 'production',
    String mode = '',
    String stage = '',
    bool replace = false,
    bool switchProfile = false,
    String body = '',
  }) {
    return [
      method.toUpperCase(),
      path,
      profile,
      mode,
      stage,
      replace ? '1' : '0',
      switchProfile ? '1' : '0',
      body,
    ].join('\n');
  }
}

/// 将固件按通知拆开发送的数据拼成完整响应。
class BleResponseDecoder {
  final List<int> _buffer = [];

  void reset() => _buffer.clear();

  BleResponse? add(List<int> bytes) {
    _buffer.addAll(bytes);
    final statusEnd = _buffer.indexOf(10);
    if (statusEnd < 0) return null;
    final bodyEnd = _buffer.indexOf(10, statusEnd + 1);
    if (bodyEnd < 0) return null;

    final statusCode =
        int.tryParse(ascii.decode(_buffer.sublist(0, statusEnd)));
    if (statusCode == null) {
      _buffer.clear();
      throw const FormatException('${AppIdentity.productName} BLE 响应状态码无效');
    }
    // 通知分包可能切在一个中文 UTF-8 字符中间，等收到完整响应后再解码。
    final body = utf8.decode(_buffer.sublist(statusEnd + 1, bodyEnd));
    _buffer.clear();
    return BleResponse(statusCode: statusCode, body: body);
  }
}

class BleResponse {
  const BleResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}
