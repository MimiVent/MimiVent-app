/// 串行化单次 GATT 操作；异步轮询和业务等待不应放在该调度器内。
class BleGattScheduler {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then<T>((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
