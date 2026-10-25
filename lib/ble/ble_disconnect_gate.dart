/// 忽略订阅时回放的初始断开状态，只将建立连接后的断开视为会话结束。
class BleDisconnectGate {
  bool _connectionEstablished = false;

  /// 返回 true 表示这是当前已建立连接的真实断开事件。
  bool shouldHandle({required bool connected, required bool isCurrentDevice}) {
    if (!isCurrentDevice) return false;
    if (connected) {
      _connectionEstablished = true;
      return false;
    }
    if (!_connectionEstablished) return false;
    _connectionEstablished = false;
    return true;
  }
}
