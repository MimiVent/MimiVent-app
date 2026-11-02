import 'dart:async';

/// 协调 App 前后台切换与 BLE 会话，避免短暂切后台就释放连接。
/// 控制场景下黑屏/切后台 10 分钟内保持连接，减少亮屏重连的 Android GATT 133。
///
/// 后台停留超过宽限期才关闭 BLE；若关闭过程中 App 回到前台，等待关闭
/// 完成后再调用恢复回调，确保恢复逻辑能看到真实的断开状态并启动扫描。
class BackgroundBleLifecycle {
  BackgroundBleLifecycle({
    required Future<void> Function() closeSession,
    required Future<void> Function() resumeSession,
    this.gracePeriod = const Duration(minutes: 10),
  })  : _closeSession = closeSession,
        _resumeSession = resumeSession;

  final Future<void> Function() _closeSession;
  final Future<void> Function() _resumeSession;
  final Duration gracePeriod;

  Timer? _timer;
  Future<void>? _closeFuture;
  bool _inBackground = false;
  bool _closeStarted = false;
  bool _terminated = false;
  int _backgroundEpoch = 0;

  /// 开始后台宽限倒计时。同一次后台切换收到 hidden/paused 时不重复计时。
  void onBackground() {
    if (_terminated || _inBackground) return;
    _inBackground = true;
    _closeStarted = false;
    // 新一轮后台切换要使用自己的关闭任务，不能误复用上一轮已完成的 Future。
    _closeFuture = null;
    final epoch = ++_backgroundEpoch;
    _timer?.cancel();
    _timer = Timer(gracePeriod, () {
      if (_terminated || !_inBackground || epoch != _backgroundEpoch) return;
      _closeStarted = true;
      _closeFuture = _closeSafely();
    });
  }

  /// 回到前台时取消倒计时；若后台关闭已经开始，则等待它完成后再恢复。
  Future<void> onForeground() async {
    if (_terminated || !_inBackground) return;
    _inBackground = false;
    _timer?.cancel();
    _timer = null;
    final epoch = _backgroundEpoch;
    if (!_closeStarted) return;

    await _closeFuture;
    // 等待期间若再次退到后台，旧的恢复请求就不能启动扫描。
    if (!_terminated && !_inBackground && epoch == _backgroundEpoch) {
      await _resumeSession();
    }
  }

  /// App 收到 detached 时不再保留会话，立即释放 BLE。
  Future<void> closeImmediately() {
    if (_terminated) return _closeFuture ?? Future<void>.value();
    _terminated = true;
    _inBackground = true;
    ++_backgroundEpoch;
    _timer?.cancel();
    _timer = null;
    if (_closeStarted && _closeFuture != null) return _closeFuture!;
    _closeStarted = true;
    return _closeFuture = _closeSafely();
  }

  Future<void> _closeSafely() async {
    try {
      await _closeSession();
    } catch (_) {
      // 后台切换期间的 BLE 清理失败不能变成未处理的异步异常；恢复扫描会重试。
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _terminated = true;
    ++_backgroundEpoch;
  }
}
