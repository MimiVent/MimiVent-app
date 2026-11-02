import 'dart:convert';

import '../app/app_identity.dart';
import '../transport/device_transport.dart';

/// MimiVent 业务请求的 BLE 传输适配常量。
///
/// HTTP、家庭 Wi-Fi 和后续 OTA 使用各自传输层；业务 API 的路径、模型和
/// 错误语义保持一致。这里仅定义 BLE 请求关联与通知分片，不承载业务规则。
class BleProtocol {
  static const deviceName = AppIdentity.productName;
  static const serviceUuid = '6f9b0001-7d5a-4c3b-9a21-2f6d4d494d49';
  static const commandUuid = '6f9b0002-7d5a-4c3b-9a21-2f6d4d494d49';
  static const responseUuid = '6f9b0003-7d5a-4c3b-9a21-2f6d4d494d49';
  static const otaControlUuid = '6f9b0004-7d5a-4c3b-9a21-2f6d4d494d49';
  static const otaDataUuid = '6f9b0005-7d5a-4c3b-9a21-2f6d4d494d49';
  static const otaStatusUuid = '6f9b0006-7d5a-4c3b-9a21-2f6d4d494d49';
  static const wifiServiceUuid = '6f9b0010-7d5a-4c3b-9a21-2f6d4d494d49';
  static const wifiCommandUuid = '6f9b0011-7d5a-4c3b-9a21-2f6d4d494d49';
  static const wifiResponseUuid = '6f9b0012-7d5a-4c3b-9a21-2f6d4d494d49';
  static const frameVersion = 2;
  static const maximumResponseBytes = 4096;
  static const maximumFragments = 1024;

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

  /// 请求帧前缀：requestId:uint16 little-endian，之后是 UTF-8 业务请求。
  static List<int> frameRequest(int requestId, String packet) {
    if (requestId < 1 || requestId > 0xFFFF) {
      throw RangeError.range(requestId, 1, 0xFFFF, 'requestId');
    }
    final bytes = utf8.encode(packet);
    return [requestId & 0xFF, requestId >> 8, ...bytes];
  }
}

/// CRC-32/IEEE；与固件采用同一反射多项式和初值/终值。
int bleCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 构造 OTA 数据帧：偏移与 CRC 均为 little-endian，空载荷和越界偏移不可发送。
List<int> encodeOtaDataFrame(int offset, List<int> payload) {
  if (offset < 0 || offset > 0xFFFFFFFF) {
    throw RangeError.range(offset, 0, 0xFFFFFFFF, 'offset');
  }
  if (payload.isEmpty) throw ArgumentError.value(payload, 'payload', '不能为空');
  final checksum = bleCrc32(payload);
  return [
    offset & 0xFF,
    (offset >> 8) & 0xFF,
    (offset >> 16) & 0xFF,
    (offset >> 24) & 0xFF,
    checksum & 0xFF,
    (checksum >> 8) & 0xFF,
    (checksum >> 16) & 0xFF,
    (checksum >> 24) & 0xFF,
    ...payload,
  ];
}

/// 校验 OTA 累计 ACK。旧固件的三字段响应仍兼容，V2 可附带可用队列槽数。
int? parseOtaAcknowledgement(String status,
    {required int minimumOffset, required int totalBytes}) {
  final fields = status.split('|');
  if (!status.startsWith('ACK|') ||
      (fields.length != 3 && fields.length != 4) ||
      int.tryParse(fields[1]) == null ||
      int.parse(fields[1]) < minimumOffset ||
      int.tryParse(fields[2]) != totalBytes) {
    throw FormatException('累计 OTA ACK 无效：$status');
  }
  if (fields.length == 3) return null;
  final credits = int.tryParse(fields[3]);
  if (credits == null || credits < 0) {
    throw FormatException('OTA ACK 缓冲量无效：$status');
  }
  return credits;
}

/// 校验 requestId、片序、消息长度和 CRC 后，再解码 UTF-8 响应。
/// 不完整数据不会泄漏给 JSON 层；不同连接会话必须调用 [reset]。
class BleResponseDecoder {
  final Map<int, List<int>> _fragments = {};
  int? _requestId;
  int? _expectedLength;
  int? _expectedCrc;

  void reset() {
    _fragments.clear();
    _requestId = null;
    _expectedLength = null;
    _expectedCrc = null;
  }

  DeviceResponse? add(List<int> notification,
      {required int expectedRequestId}) {
    if (notification.length < 4) {
      throw const FormatException('BLE V2 分片头不完整');
    }
    final requestId = notification[0] | (notification[1] << 8);
    // 旧连接或超时请求的迟到帧不进入当前解码状态。
    if (requestId != expectedRequestId) return null;
    final fragmentIndex = notification[2] | (notification[3] << 8);
    if (fragmentIndex >= BleProtocol.maximumFragments) {
      throw const FormatException('BLE V2 分片数量超过上限');
    }
    if (_requestId != null && _requestId != requestId) {
      throw const FormatException('BLE V2 响应 requestId 不一致');
    }
    _requestId = requestId;

    final headerLength = fragmentIndex == 0 ? 12 : 4;
    if (notification.length <= headerLength) {
      throw const FormatException('BLE V2 分片没有有效负载');
    }
    if (fragmentIndex == 0) {
      if (notification[4] != BleProtocol.frameVersion) {
        throw FormatException('不支持的 BLE 帧版本 ${notification[4]}');
      }
      if (notification[5] != 0) {
        throw const FormatException('BLE V2 响应包含未知帧标志');
      }
      final bodyLength = notification[6] | (notification[7] << 8);
      final bodyCrc = notification[8] |
          (notification[9] << 8) |
          (notification[10] << 16) |
          (notification[11] << 24);
      if (_expectedLength != null &&
          (_expectedLength != bodyLength || _expectedCrc != bodyCrc)) {
        throw const FormatException('BLE V2 重复首片元数据不一致');
      }
      _expectedLength = bodyLength;
      _expectedCrc = bodyCrc;
      if (bodyLength == 0 || bodyLength > BleProtocol.maximumResponseBytes) {
        throw const FormatException('BLE V2 响应长度超过上限');
      }
    }
    if (_expectedLength == null || _expectedCrc == null) {
      if (fragmentIndex != 0) {
        throw const FormatException('BLE V2 首片缺失');
      }
    }

    final payload = List<int>.unmodifiable(notification.sublist(headerLength));
    final previous = _fragments[fragmentIndex];
    if (previous != null) {
      if (!_sameBytes(previous, payload)) {
        throw const FormatException('BLE V2 重复分片内容不一致');
      }
      return null;
    }
    _fragments[fragmentIndex] = payload;

    final totalBytes =
        _fragments.values.fold<int>(0, (sum, item) => sum + item.length);
    if (totalBytes > (_expectedLength ?? BleProtocol.maximumResponseBytes)) {
      throw const FormatException('BLE V2 响应超过声明长度');
    }
    if (totalBytes < (_expectedLength ?? BleProtocol.maximumResponseBytes)) {
      return null;
    }

    final ordered = <int>[];
    for (var index = 0; index < _fragments.length; index++) {
      final part = _fragments[index];
      if (part == null) return null;
      ordered.addAll(part);
    }
    if (ordered.length != _expectedLength ||
        bleCrc32(ordered) != _expectedCrc) {
      throw const FormatException('BLE V2 响应长度或 CRC 校验失败');
    }
    reset();
    return _decodeStatusResponse(ordered);
  }

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  DeviceResponse _decodeStatusResponse(List<int> bytes) {
    final statusEnd = bytes.indexOf(10);
    final bodyEnd = statusEnd < 0 ? -1 : bytes.indexOf(10, statusEnd + 1);
    if (statusEnd < 1 || bodyEnd < 0 || bodyEnd != bytes.length - 1) {
      throw const FormatException('BLE V2 响应边界无效');
    }
    final statusCode = int.tryParse(ascii.decode(bytes.sublist(0, statusEnd)));
    if (statusCode == null) {
      throw const FormatException('${AppIdentity.productName} BLE 响应状态码无效');
    }
    return DeviceResponse(
      statusCode: statusCode,
      body: utf8.decode(bytes.sublist(statusEnd + 1, bodyEnd)),
    );
  }
}

/// v1 固件直接发送 `statusCode\nbody\n`，没有 requestId/CRC 帧头。
/// 仅在连接握手明确识别为 v1 时使用。
class LegacyBleResponseDecoder {
  final List<int> _buffer = [];

  void reset() => _buffer.clear();

  DeviceResponse? add(List<int> notification) {
    _buffer.addAll(notification);
    if (_buffer.length > BleProtocol.maximumResponseBytes) {
      reset();
      throw const FormatException('BLE v1 响应超过长度上限');
    }
    final statusEnd = _buffer.indexOf(10);
    final bodyEnd = statusEnd < 0 ? -1 : _buffer.indexOf(10, statusEnd + 1);
    if (statusEnd < 1 || bodyEnd < 0) return null;
    final statusCode =
        int.tryParse(ascii.decode(_buffer.sublist(0, statusEnd)));
    if (statusCode == null) {
      reset();
      throw const FormatException('BLE v1 响应状态码无效');
    }
    final body = utf8.decode(_buffer.sublist(statusEnd + 1, bodyEnd));
    reset();
    return DeviceResponse(statusCode: statusCode, body: body);
  }
}
