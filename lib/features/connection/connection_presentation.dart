/// 连接面板只需要消费这个呈现状态，不应重复判断 BLE 原始状态组合。
enum ConnectionPresentation { disconnected, scanning, connecting, connected }

ConnectionPresentation connectionPresentation({
  required bool connected,
  required bool connecting,
  required bool scanning,
}) {
  if (connecting) return ConnectionPresentation.connecting;
  if (connected) return ConnectionPresentation.connected;
  if (scanning) return ConnectionPresentation.scanning;
  return ConnectionPresentation.disconnected;
}
