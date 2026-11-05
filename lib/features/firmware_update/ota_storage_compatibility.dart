/// 目标必须能读取设备当前的存储格式，升级和降级使用同一规则。
bool canReadStorageSchema({
  required int? deviceSchema,
  required int? targetSchema,
  int? minimumReadableSchema,
}) {
  if (deviceSchema == null || targetSchema == null || targetSchema < 1) {
    return false;
  }
  final minimum = minimumReadableSchema ?? targetSchema;
  return minimum > 0 && minimum <= deviceSchema && deviceSchema <= targetSchema;
}
