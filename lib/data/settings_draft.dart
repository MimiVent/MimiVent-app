import 'models.dart';

/// 配置编辑草稿，保证轮询读取设备状态不会覆盖未保存的用户输入。
class SettingsDraft {
  SettingsDraft({required this.saved, required this.value});

  final TimingSettings saved;
  final TimingSettings value;

  bool get isDirty => saved.toJson().toString() != value.toJson().toString();

  SettingsDraft update(String key, int value) => SettingsDraft(
        saved: saved,
        value: switch (key) {
          'startupCooldownMs' => this.value.copyWith(startupCooldownMs: value),
          'leaveConfirmMs' => this.value.copyWith(leaveConfirmMs: value),
          'autoExhaustMs' => this.value.copyWith(autoExhaustMs: value),
          'manualExhaustMs' => this.value.copyWith(manualExhaustMs: value),
          'pauseMs' => this.value.copyWith(pauseMs: value),
          _ => this.value,
        },
      );

  SettingsDraft markSaved(TimingSettings settings) =>
      SettingsDraft(saved: settings, value: settings);
}
