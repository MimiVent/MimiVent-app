class NasGatewayException implements Exception {
  const NasGatewayException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class NasGatewayHttpResult {
  const NasGatewayHttpResult(this.statusCode, this.body,
      {this.commandOutcomeKnown = false});

  final int statusCode;
  final Map<String, dynamic> body;

  /// true 表示已确定命令没有发布，或设备已经返回最终 ACK。
  /// false 表示命令可能已执行但结果未知，必须保留 pending。
  final bool commandOutcomeKnown;
}

String timeSyncSourceLabel(Object? source) => switch (source) {
      'phone' => '手机蓝牙',
      'nas' => 'NAS MQTT',
      'none' => '未同步',
      _ => '未知',
    };

/// 校验网关响应的路由设备身份。body.deviceId 可是统计数据集 ID，语义不同。
void validateGatewayReadDeviceId(
    Map<String, dynamic> envelope, String expectedDeviceId) {
  if (envelope['deviceId'] != expectedDeviceId) {
    throw const NasGatewayException('DEVICE_MISMATCH', 'NAS 查询返回了其他设备的数据');
  }
}
