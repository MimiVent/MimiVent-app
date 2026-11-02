// 真机联调：凭据仅通过 stdin 传入，不写文件、不回显 token。
import 'dart:convert';
import 'dart:io';
import 'package:mimivent_app/features/wifi_control/wifi_binding.dart';
import 'package:mimivent_app/features/wifi_control/wifi_read_transport.dart';

Future<void> main() async {
  try {
    final input = jsonDecode(await stdin.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    final value = await WifiReadTransport().read(WifiBinding.fromJson(input));
    stdout.writeln(jsonEncode(value));
  } on WifiReadException catch (e) {
    stdout.writeln(jsonEncode({'error': e.code}));
    exitCode = 1;
  } catch (_) {
    stdout.writeln('{"error":"PROBE_FAILED"}');
    exitCode = 1;
  }
}
