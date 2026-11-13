import 'dart:async';

/// 外部任务串行执行；只有当前任务自身的异步调用链可以重入。
class NasGatewaySerialExecutor {
  final Object _zoneKey = Object();
  final List<_Task> _tasks = [];
  _Owner? _activeOwner;

  Future<T> run<T>(Future<T> Function() action, {bool priority = false}) {
    final owner = Zone.current[_zoneKey];
    if (owner != null && identical(owner, _activeOwner)) {
      return Future<T>.sync(action);
    }
    final result = Completer<T>();
    _tasks.add(_Task(() async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }, priority));
    _pump();
    return result.future;
  }

  void _pump() {
    if (_activeOwner != null || _tasks.isEmpty) return;
    final index = _tasks.indexWhere((task) => task.priority);
    final task = _tasks.removeAt(index < 0 ? 0 : index);
    final owner = _Owner();
    _activeOwner = owner;
    unawaited(
        runZoned(task.run, zoneValues: {_zoneKey: owner}).whenComplete(() {
      _activeOwner = null;
      _pump();
    }));
  }
}

class _Owner {}

class _Task {
  _Task(this.run, this.priority);
  final Future<void> Function() run;
  final bool priority;
}
