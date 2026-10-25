import '../../data/models.dart';

/// 页面发起的控制意图，避免用字符串在 UI 与设备逻辑之间传递操作类型。
enum ControlOperation { automatic, exhaust, pause, forceExhaust, persistentOff }

extension ControlOperationRules on ControlOperation {
  bool get allowedDuringStartupCooldown =>
      this == ControlOperation.persistentOff ||
      this == ControlOperation.forceExhaust;

  bool matches(DeviceStatus? status) => switch (this) {
        ControlOperation.exhaust => status?.mode == 'timed_on',
        ControlOperation.pause => status?.mode == 'timed_off',
        ControlOperation.forceExhaust => status?.mode == 'force_test',
        _ => false,
      };
}

/// 描述可被新操作覆盖的设备流程，集中维护打断确认策略。
bool hasInterruptibleOperation(DeviceStatus? status) {
  if (status == null) return false;
  return const {'timed_on', 'timed_off', 'force_test'}.contains(status.mode) ||
      (status.mode == 'auto' &&
          const {'clear_confirm', 'exhausting'}.contains(status.phase));
}

/// 可展示的操作结果，页面据此给出一致反馈，不把业务失败伪装为成功。
sealed class OperationResult {
  const OperationResult();
}

class OperationSucceeded extends OperationResult {
  const OperationSucceeded(this.operation);
  final ControlOperation operation;
}

class OperationRejected extends OperationResult {
  const OperationRejected(this.operation, this.reason);
  final ControlOperation operation;
  final String reason;
}
