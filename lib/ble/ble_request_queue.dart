/// 按顺序执行 BLE 请求，并在轮到旧请求时拒绝已失效的连接会话。
class BleRequestQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> get idle => _tail;

  Future<BleRequestResult<T>> enqueue<T>({
    required bool Function() isSessionCurrent,
    required Future<T> Function() send,
  }) {
    final request = _tail.then<BleRequestResult<T>>((_) async {
      if (!isSessionCurrent()) {
        return BleRequestRejected<T>(
            StateError('蓝牙会话已变化，请重新发起请求'), StackTrace.current);
      }
      try {
        return BleRequestSucceeded<T>(await send());
      } catch (error, stackTrace) {
        return BleRequestRejected<T>(error, stackTrace);
      }
    });
    _tail = request.then<void>((_) {});
    return request;
  }
}

sealed class BleRequestResult<T> {
  const BleRequestResult();
}

class BleRequestSucceeded<T> extends BleRequestResult<T> {
  const BleRequestSucceeded(this.value);
  final T value;
}

class BleRequestRejected<T> extends BleRequestResult<T> {
  const BleRequestRejected(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}
