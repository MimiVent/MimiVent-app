import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ble/mimivent_ble_manager.dart';
import 'wifi_binding.dart';
import 'wifi_binding_store.dart';
import 'wifi_read_transport.dart';

class WifiBindingController extends ChangeNotifier {
  WifiBindingController(this.ble,
      {WifiBindingStore? store, WifiReadTransport? transport})
      : store = store ?? WifiBindingStore(),
        transport = transport ?? WifiReadTransport();
  final MimiVentBleManager ble;
  final WifiBindingStore store;
  final WifiReadTransport transport;
  List<WifiBinding> records = [];
  WifiBinding? selected;
  Map<String, dynamic>? status;
  Map<String, dynamic>? settings;
  Map<String, dynamic>? stats;
  List<Map<String, dynamic>> events = [];
  bool eventsHasMore = false;
  int eventsNextOffset = 0;
  int eventsStart = 0;
  int eventsEnd = 0;
  String? eventsDataEpoch;
  bool busy = false, _disposed = false;
  String? error;
  bool secureStoreReady = false;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> run(Future<void> Function() work,
      {bool clearData = true}) async {
    if (busy) return;
    busy = true;
    error = null;
    if (clearData) {
      status = null;
      settings = null;
      stats = null;
      events = [];
    }
    changed();
    try {
      await work();
    } catch (e) {
      status = null;
      error = e is WifiReadException
          ? e.message
          : e is PlatformException
              ? (e.message ?? '安全存储暂不可用')
              : e is StateError
                  ? e.message.toString()
                  : e is FormatException
                      ? '绑定或状态数据无效，原凭据已保留'
                      : '操作未完成，请检查蓝牙及局域网连接后重试';
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> load() => run(() async {
        records = await store.load();
        secureStoreReady = true;
        selected = records.isEmpty ? null : records.first;
        if (store.dropped > 0) error = '已忽略 ${store.dropped} 条损坏记录，其他设备记录已保留';
      });
  void select(WifiBinding value) {
    selected = value;
    status = null;
    changed();
  }

  Future<void> persist(List<WifiBinding> next) async {
    if (_disposed) throw StateError('页面已关闭，请稍后恢复绑定');
    await store.save(next);
    records = next;
  }

  Future<Map<String, dynamic>> request(String op,
      {Map<String, dynamic> extra = const {}}) async {
    if (_disposed) throw StateError('页面已关闭，请稍后恢复绑定');
    final result = await ble.requestWifi({'op': op, ...extra});
    final body = jsonDecode(result.body);
    if (body is! Map<String, dynamic>) throw StateError('设备返回的绑定数据无效');
    if (result.statusCode != 200 || body['error'] != null) {
      final code = body['error']?.toString() ?? 'DEVICE_ERROR';
      throw WifiReadException(
          code,
          const {
                'BINDINGS_FULL': '设备已绑定两台客户端，请通过蓝牙管理绑定，或清除设备端全部绑定后重试',
                'WIFI_STORAGE_LOW': '设备存储余量不足，暂不能建立新绑定，请先完成设备维护',
                'BIND_BUSY': '另一个绑定任务尚未结束，请稍后重试',
                'BIND_WINDOW_CLOSED': '绑定窗口已关闭，请重新点击绑定',
                'WIFI_UNAVAILABLE': 'WiFi 控制服务暂未就绪，请确认设备已联网后重试',
                'VERIFICATION_REQUIRED': '设备尚未确认网络核验，请重试恢复绑定',
                'BINDINGS_STORE_FAILED': '设备未能确认保存，请保留记录并在重连后查询结果',
                'PERMISSION_DENIED': '当前蓝牙配对没有操作此任务的权限',
              }[code] ??
              '设备未完成绑定操作（$code）');
    }
    return body;
  }

  Future<void> updateRecord(WifiBinding binding) async {
    await persist([
      for (final old in records)
        if (old.tokenId == binding.tokenId && old.deviceId == binding.deviceId)
          binding
        else
          old
    ]);
    selected = binding;
  }

  Future<void> loadSettings() => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        settings = await transport.readPath(
            binding, '/api/settings?profile=production');
        status = await checkedRead(binding);
      });

  Future<void> loadStats(String range) => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        if (!const ['today', 'yesterday', 'threeDays', 'sevenDays']
            .contains(range)) {
          throw StateError('统计范围无效');
        }
        final data =
            await transport.readPath(binding, '/api/stats?mode=$range');
        stats = data;
        final rawEvents = data['events'];
        events = rawEvents is List
            ? rawEvents
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : [];
        eventsHasMore = data['eventsHasMore'] == true;
        eventsNextOffset = (data['eventsNextOffset'] as num?)?.toInt() ?? 0;
        eventsStart = (data['eventsStart'] as num?)?.toInt() ?? 0;
        eventsEnd = (data['eventsEnd'] as num?)?.toInt() ?? 0;
        eventsDataEpoch = data['dataEpoch']?.toString();
        status = await checkedRead(binding);
      });

  Future<void> loadMoreEvents() => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        if (!eventsHasMore || eventsStart <= 0 || eventsEnd <= eventsStart) {
          return;
        }
        final query = 'start=$eventsStart&end=$eventsEnd'
            '&offset=$eventsNextOffset&limit=32'
            '${eventsDataEpoch == null ? '' : '&dataEpoch=${Uri.encodeQueryComponent(eventsDataEpoch!)}'}'
            '&kind=all';
        final data = await transport.readPath(binding, '/api/events?$query');
        final rawEvents = data['events'];
        if (rawEvents is List) {
          final existing = events.map((e) => e['id']).toSet();
          for (final item in rawEvents.whereType<Map>()) {
            final next = Map<String, dynamic>.from(item);
            if (!existing.contains(next['id'])) events.add(next);
          }
        }
        eventsHasMore = data['eventsHasMore'] == true;
        eventsNextOffset =
            (data['eventsNextOffset'] as num?)?.toInt() ?? eventsNextOffset;
      }, clearData: false);

  Future<void> saveSettings(Map<String, int> values) => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        final requestId = randomId(uuid: true);
        final body = 'profile=production'
            '&startupCooldownMs=${values['startupCooldownMs']}'
            '&leaveConfirmMs=${values['leaveConfirmMs']}'
            '&autoExhaustMs=${values['autoExhaustMs']}'
            '&manualExhaustMs=${values['manualExhaustMs']}'
            '&pauseMs=${values['pauseMs']}';
        WifiHttpResult result;
        try {
          result = await transport.write(binding,
              path: '/api/settings', body: body, requestId: requestId);
        } on TimeoutException {
          if (await _reconcile(binding, requestId)) return;
          rethrow;
        } on SocketException {
          if (await _reconcile(binding, requestId)) return;
          rethrow;
        }
        if (result.statusCode != 200) {
          final code =
              result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
          throw WifiReadException(code,
              code == 'INVALID_SETTINGS' ? '设置值不在允许范围内' : '设备未保存设置（$code）');
        }
        settings = await transport.readPath(
            binding, '/api/settings?profile=production');
        status = await checkedRead(binding);
      });

  Future<void> control(String path, String body) => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        if (binding.state != 'active') {
          throw StateError('当前绑定尚未生效，请连接蓝牙完成绑定');
        }
        final requestId = randomId(uuid: true);
        WifiHttpResult result;
        try {
          result = await transport.write(
            binding,
            path: path,
            body: body,
            requestId: requestId,
          );
        } on TimeoutException {
          if (await _reconcile(binding, requestId)) return;
          rethrow;
        } on SocketException {
          if (await _reconcile(binding, requestId)) return;
          rethrow;
        }
        if (result.statusCode != 200) {
          final code =
              result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
          throw WifiReadException(
            code,
            const {
                  'PROFILE_MISMATCH': '设备当前档位与请求不一致，请先刷新状态',
                  'PIR_HIGH': '检测到有人，暂时不能启动排风',
                  'STARTUP_COOLDOWN': '设备正在启动保护期，请稍后再试',
                  'OTA_BUSY': '设备正在升级，暂时不能控制',
                  'REQUEST_ID_CONFLICT': '请求标识冲突，请重试',
                  'DEDUP_UNAVAILABLE': '设备存储不足，无法安全去重，暂时不能控制',
                  'RATE_LIMITED': '操作过于频繁，请稍后重试',
                }[code] ??
                '设备未完成 WiFi 控制（$code）',
          );
        }
        status = await checkedRead(binding);
      });

  Future<bool> _reconcile(WifiBinding binding, String requestId) async {
    try {
      final result = await transport.queryRequest(binding, requestId);
      if (result.statusCode != 200) return false;
      final statusText = result.body['status']?.toString();
      if (statusText == 'applied') {
        status = await checkedRead(binding);
        return true;
      }
      if (statusText == 'pending') {
        throw const WifiReadException(
          'REQUEST_PENDING',
          '设备仍在处理上一次请求，请稍后刷新状态，不要重复操作',
        );
      }
      if (statusText == 'unknown') {
        throw const WifiReadException(
          'REQUEST_UNKNOWN',
          '设备重启前请求结果未知，请刷新状态后重新操作，不要直接重试',
        );
      }
      if (statusText == 'rejected') {
        throw WifiReadException(
          'REQUEST_REJECTED',
          '设备未执行该控制（HTTP ${result.body['httpStatus'] ?? '?'}）',
        );
      }
    } on WifiReadException catch (e) {
      if (e.code == 'REQUEST_PENDING' || e.code == 'REQUEST_UNKNOWN') rethrow;
      return false;
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<Map<String, dynamic>> checkedRead(WifiBinding binding) async {
    try {
      try {
        return await transport.read(binding);
      } on WifiReadException catch (e) {
        if (e.code != 'RATE_LIMITED') rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 550));
        return await transport.read(binding);
      }
    } on WifiReadException catch (e) {
      if (['PIN_MISMATCH', 'DEVICE_MISMATCH'].contains(e.code)) {
        await updateRecord(binding.copy(state: 'blocked'));
      } else if (e.code == 'BINDING_INVALID')
        await updateRecord(binding.copy(state: 'invalid'));
      rethrow;
    }
  }

  Future<void> read(String host) => run(() async {
        final old = selected;
        if (old == null) throw StateError('请先通过蓝牙绑定设备');
        final candidate = old.copy(host: host.trim());
        status = await checkedRead(candidate);
        if (status!['bindingState'] != 'active') {
          throw StateError('当前绑定尚未完成，请连接蓝牙后点击恢复绑定');
        }
        await updateRecord(candidate.copy(state: 'active'));
      });
  String randomId({bool uuid = false}) {
    final r = Random.secure();
    final bytes = List.generate(16, (_) => r.nextInt(256));
    if (uuid) {
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
    }
    final h = bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return uuid
        ? '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}'
        : h;
  }

  Future<void> bind() => run(() async {
        if (!secureStoreReady) {
          records = await store.load();
          secureStoreReady = true;
        }
        final network = await request('wifi.status');
        if (network['wifiReadAvailable'] != true) {
          throw StateError('设备的 WiFi 安全控制尚未就绪，请确认固件支持且已接入路由器');
        }
        final device = network['deviceId'];
        if (device is! String) throw StateError('设备未返回稳定身份');
        final preferences = await SharedPreferences.getInstance();
        const key = 'mimivent.wifi.client_id.v1';
        final client = preferences.getString(key) ?? 'c-${randomId()}';
        await preferences.setString(key, client);
        WifiBinding? candidate;
        for (final old in records) {
          if (old.deviceId == device && old.state == 'pending') candidate = old;
        }
        await request('wifi.bind.open');
        if (candidate != null) {
          final remote = await request('wifi.bind.status',
              extra: {'tokenId': candidate.tokenId});
          if (!['pending', 'active'].contains(remote['bindingState'])) {
            final expired = candidate;
            await persist(records
                .where((r) =>
                    r.tokenId != expired.tokenId ||
                    r.deviceId != expired.deviceId)
                .toList());
            candidate = null;
          }
        }
        if (candidate == null) {
          if (records.length >= 16) throw StateError('本机记录过多，请先移除不用的设备');
          for (final old in records
              .where((r) => r.deviceId == device && r.state != 'active')) {
            await request('wifi.bind.cancel', extra: {'tokenId': old.tokenId});
          }
          final beginKey = 'mimivent.wifi.begin.$device';
          final beginId =
              preferences.getString(beginKey) ?? randomId(uuid: true);
          await preferences.setString(beginKey, beginId);
          final begin = await request('wifi.bind.begin', extra: {
            'clientId': client,
            'requestId': beginId,
            'replace': true
          });
          candidate = WifiBinding.fromJson(
              {...begin, 'version': 1, 'clientId': client});
          if (candidate.deviceId != device) throw StateError('蓝牙返回的设备身份发生变化');
          // commit 前持久化 pending；替换期间保留旧 active token，直到新授权成功。
          await persist([...records, candidate]);
          await preferences.remove(beginKey);
          selected = candidate;
          changed();
        } else {
          selected = candidate;
        }
        final value = candidate.copy(
            host:
                network['ip'] is String && (network['ip'] as String).isNotEmpty
                    ? network['ip'] as String
                    : candidate.host);
        final verified = await checkedRead(value);
        await updateRecord(value);
        if (verified['bindingState'] == 'pending') {
          try {
            await request('wifi.bind.commit',
                extra: {'tokenId': value.tokenId});
          } catch (_) {
            final remote = await request('wifi.bind.status',
                extra: {'tokenId': value.tokenId});
            if (remote['bindingState'] != 'active') rethrow;
          }
        }
        final active = value.copy(state: 'active');
        try {
          status = await checkedRead(active);
        } on WifiReadException catch (error) {
          if (error.code != 'WIFI_IN_USE') rethrow;
          // 另一台手机仍持有 WiFi 主控租约时，HTTPS 验证会被拒绝；
          // 用 BLE 确认 commit 已生效，绑定本身仍然成功，WiFi 控制等租约释放后再用。
          final remote = await request('wifi.bind.status',
              extra: {'tokenId': value.tokenId});
          if (remote['bindingState'] != 'active') rethrow;
          status = <String, dynamic>{'bindingState': 'active'};
        }
        if (status!['bindingState'] != 'active') {
          throw StateError('设备尚未完成绑定，请重新连接蓝牙后恢复');
        }
        try {
          await request('wifi.bind.cancel', extra: {'tokenId': value.tokenId});
        } catch (_) {
          // 已经由 HTTPS 确认 active；关闭窗口响应丢失不应抹去有效绑定。
        }
        await persist([...records.where((r) => r.deviceId != device), active]);
        selected = active;
      });
  Future<void> revoke() => run(() async {
        final binding = selected;
        if (binding == null) return;
        final network = await request('wifi.status');
        if (network['deviceId'] != binding.deviceId) {
          throw StateError('请通过蓝牙连接此记录对应的设备');
        }
        await request(
            binding.state == 'pending' ? 'wifi.bind.cancel' : 'wifi.revoke',
            extra: {'tokenId': binding.tokenId});
        await removeSelected();
      });
  Future<void> removeSelected() async {
    final binding = selected;
    if (binding == null) return;
    await persist(records
        .where((r) =>
            r.deviceId != binding.deviceId || r.tokenId != binding.tokenId)
        .toList());
    selected = records.isEmpty ? null : records.first;
    status = null;
    changed();
  }

  Future<void> resetLocalRecords() => run(() async {
        await store.clearConfirmed();
        records = [];
        selected = null;
        status = null;
        secureStoreReady = true;
      });

  /// 清除设备端全部 WiFi 授权；用于旧手机丢失/卸载后，2 个槽位被占满的恢复。
  Future<void> resetDeviceBindings() => run(() async {
        final network = await request('wifi.status');
        final device = network['deviceId'];
        if (device is! String) throw StateError('设备未返回稳定身份');
        await request('wifi.bind.reset', extra: {
          'confirm': 'RESET_ALL_BINDINGS',
        });
        final remaining = records
            .where((binding) => binding.deviceId != device)
            .toList(growable: false);
        await persist(remaining);
        selected = remaining.isEmpty ? null : remaining.first;
        status = null;
        error = null;
      });

  Future<Map<String, dynamic>> listDeviceClients() async {
    final device = await request('wifi.status');
    final clients = await request('wifi.clients');
    final list = clients['clients'];
    if (device['deviceId'] is! String ||
        list is! List ||
        list.any((item) =>
            item is! Map ||
            item['tokenId'] is! String ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(item['tokenId'] as String) ||
            item['clientId'] is! String)) {
      throw StateError('设备返回的绑定列表格式无效');
    }
    return {'deviceId': device['deviceId'], 'clients': clients['clients']};
  }

  Future<void> revokeDeviceClient(String deviceId, String tokenId) =>
      run(() async {
        final current = await request('wifi.status');
        if (current['deviceId'] != deviceId) {
          throw StateError('蓝牙连接的设备已变化，请重新打开管理列表');
        }
        await request('wifi.revoke', extra: {'tokenId': tokenId});
        await persist(records
            .where((r) => r.deviceId != deviceId || r.tokenId != tokenId)
            .toList());
        if (selected?.deviceId == deviceId && selected?.tokenId == tokenId) {
          selected = records.isEmpty ? null : records.first;
        }
      });
}
