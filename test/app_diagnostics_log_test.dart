import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimivent_app/core/diagnostics/app_diagnostics_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('状态原始抓取可手动停止，并记录抓取开关事件', () async {
    final log = AppDiagnosticsLog();
    await log.initialize();

    log.startStatusPollCapture();
    expect(log.isCapturingStatusPolls, isTrue);

    log.stopStatusPollCapture();
    expect(log.isCapturingStatusPolls, isFalse);
    expect(log.entries.map((entry) => entry.message),
        contains('已开启状态轮询原始抓取，五分钟后自动结束'));
    expect(
        log.entries.map((entry) => entry.message), contains('已手动结束状态轮询原始抓取'));

    await log.clear();
    log.dispose();
  });
}
