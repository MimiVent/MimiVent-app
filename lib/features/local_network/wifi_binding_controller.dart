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
import 'nas_gateway_models.dart';
import 'nas_gateway_transport.dart';
import 'nas_pending_request_store.dart';

class WifiBindingController extends ChangeNotifier {
  WifiBindingController(this.ble,
      {WifiBindingStore? store, NasGatewayTransport? gatewayTransport})
      : store = store ?? WifiBindingStore(),
        gatewayTransport = gatewayTransport ?? NasGatewayTransport() {
    _pendingAgeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final createdAt = _pendingRequestCreatedAtMs;
      if (_disposed || !hasPendingControl || createdAt == null) return;
      pendingRequestAgeMs = (DateTime.now().millisecondsSinceEpoch - createdAt)
          .clamp(0, 0x7fffffffffffffff)
          .toInt();
      changed();
    });
  }
  final MimiVentBleManager ble;
  final WifiBindingStore store;
  final NasGatewayTransport gatewayTransport;
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
  String? controlNotice;
  bool hasPendingControl = false;
  int? pendingRequestAgeMs;
  bool pendingRequestAgeEstimated = false;
  int? _pendingRequestCreatedAtMs;
  Timer? _pendingAgeTimer;
  // 跨页面保留清理失败的请求，不能只信任 SharedPreferences 已提前修改的内存缓存。
  static final Map<String, String> _pendingGuards = {};
  static final Map<String, String> _confirmedApplied = {};
  String _pendingKey(WifiBinding binding) =>
      NasPendingRequestStore.key(binding);

  Future<bool> _clearPending(WifiBinding binding, String requestId) async {
    final key = _pendingKey(binding);
    _pendingGuards[key] = requestId;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (await NasPendingRequestStore.clear(preferences, binding,
          expectedRequestId: requestId)) {
        _pendingGuards.remove(key);
        _confirmedApplied.remove(key);
        hasPendingControl = false;
        pendingRequestAgeMs = null;
        pendingRequestAgeEstimated = false;
        _pendingRequestCreatedAtMs = null;
        return true;
      }
    } catch (_) {
      // 清理失败不能改变设备已经返回的执行结果。
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      final current = preferences.getString(key);
      final legacy =
          preferences.getString(NasPendingRequestStore.legacyKey(binding));
      if ((current == null || current == requestId) &&
          (legacy == null || legacy == requestId)) {
        await preferences.setString(key, requestId);
      }
    } catch (_) {
      // 存储不可用时仍由进程内保护阻止新请求覆盖待确认操作。
    }
    return false;
  }

  Future<void> _acceptApplied(WifiBinding binding, String requestId) async {
    _confirmedApplied[_pendingKey(binding)] = requestId;
    final cleared = await _clearPending(binding, requestId);
    await refreshAfterApplied(binding);
    if (!cleared) {
      controlNotice = '${controlNotice ?? '设备已确认执行'} 本机确认记录暂未清理，下次点击只处理原请求。';
    }
  }

  bool secureStoreReady = false;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingAgeTimer?.cancel();
    gatewayTransport.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work,
      {bool clearData = true}) async {
    if (busy) return;
    busy = true;
    error = null;
    controlNotice = null;
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
      error = e is NasGatewayException
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
        if (selected != null) await _refreshPendingInfo(selected!);
        if (store.dropped > 0) error = '已忽略 ${store.dropped} 条损坏记录，其他设备记录已保留';
      });
  void select(WifiBinding value) {
    selected = value;
    status = null;
    controlNotice = null;
    unawaited(_refreshPendingInfo(value));
    changed();
  }

  Future<void> _refreshPendingInfo(WifiBinding binding) async {
    final preferences = await SharedPreferences.getInstance();
    final requestId = await NasPendingRequestStore.read(preferences, binding);
    hasPendingControl = requestId != null;
    pendingRequestAgeMs = requestId == null
        ? null
        : NasPendingRequestStore.ageMs(preferences, binding);
    pendingRequestAgeEstimated = requestId != null &&
        NasPendingRequestStore.isAgeEstimated(preferences, binding);
    _pendingRequestCreatedAtMs =
        preferences.getInt(NasPendingRequestStore.createdAtKey(binding));
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
      throw NasGatewayException(
          code,
          const {
                'BINDINGS_FULL': '设备已绑定三台客户端，请通过蓝牙管理绑定，或清除设备端全部绑定后重试',
                'WIFI_STORAGE_LOW': '设备存储余量不足，暂不能建立新绑定，请先完成设备维护',
                'BIND_BUSY': '另一个绑定任务尚未结束，请稍后重试',
                'BIND_WINDOW_CLOSED': '绑定窗口已关闭，请重新点击绑定',
                'WIFI_UNAVAILABLE': '设备 WiFi 网络暂未就绪，请确认设备已联网后重试',
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

  Map<String, int> _settingsFromState(Map<String, dynamic> source) {
    const keys = [
      'startupCooldownMs',
      'leaveConfirmMs',
      'autoExhaustMs',
      'manualExhaustMs',
      'pauseMs',
    ];
    final values = <String, int>{};
    for (final key in keys) {
      final value = source[key];
      if (value is! num || !value.isFinite || value.toInt() != value) {
        throw const NasGatewayException(
            'SETTINGS_UNAVAILABLE', 'NAS 状态快照缺少完整的设备设置');
      }
      values[key] = value.toInt();
    }
    return values;
  }

  Future<void> loadSettings() => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        status = await checkedRead(binding);
        settings = _settingsFromState(status!);
      });

  Future<void> loadStats(String range) => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        if (!const ['today', 'yesterday', 'threeDays', 'sevenDays']
            .contains(range)) {
          throw StateError('统计范围无效');
        }
        final data = await gatewayTransport.readPath(
            binding, '/api/stats?mode=$range&limit=4');
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
            '&offset=$eventsNextOffset&limit=4'
            '${eventsDataEpoch == null ? '' : '&dataEpoch=${Uri.encodeQueryComponent(eventsDataEpoch!)}'}'
            '&kind=all';
        final data =
            await gatewayTransport.readPath(binding, '/api/events?$query');
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
        final preferences = await SharedPreferences.getInstance();
        final pendingKey = _pendingKey(binding);
        final oldRequestId = _pendingGuards[pendingKey] ??
            await NasPendingRequestStore.read(preferences, binding);
        if (oldRequestId != null) {
          if (await _reconcile(binding, oldRequestId)) {
            settings = Map<String, int>.from(values);
            return;
          }
          throw const NasGatewayException(
              'REQUEST_UNKNOWN', '上次设置保存结果仍待确认，本次仅查询原请求，没有再次发送。');
        }
        final requestId = randomId(uuid: true);
        final body = 'profile=production'
            '&startupCooldownMs=${values['startupCooldownMs']}'
            '&leaveConfirmMs=${values['leaveConfirmMs']}'
            '&autoExhaustMs=${values['autoExhaustMs']}'
            '&manualExhaustMs=${values['manualExhaustMs']}'
            '&pauseMs=${values['pauseMs']}';
        if (!await NasPendingRequestStore.save(
            preferences, binding, requestId)) {
          throw StateError('无法保存设置请求，暂未发送，请稍后重试');
        }
        hasPendingControl = true;
        pendingRequestAgeMs = 0;
        pendingRequestAgeEstimated = false;
        _pendingRequestCreatedAtMs =
            preferences.getInt(NasPendingRequestStore.createdAtKey(binding));
        final result = await gatewayTransport.tryWrite(binding,
            path: '/api/settings', body: body, requestId: requestId);
        if (result == null) {
          await _clearPending(binding, requestId);
          throw const NasGatewayException(
              'GATEWAY_UNAVAILABLE', 'NAS 网关未启用或不可达，请连接蓝牙修改设置');
        }
        if (result.body['resultUnknown'] == true ||
            result.body['error'] == 'GATEWAY_RESULT_UNKNOWN') {
          if (await _reconcile(binding, requestId)) {
            settings = Map<String, int>.from(values);
            return;
          }
          throw const NasGatewayException(
              'REQUEST_UNKNOWN', '设置可能已保存，结果暂未确认。请刷新状态，不要重复提交。');
        }
        if (result.statusCode != 200) {
          if (result.body['commandPublished'] == false ||
              result.body['resultUnknown'] != true) {
            await _clearPending(binding, requestId);
          }
          final code =
              result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
          throw NasGatewayException(
              code,
              code == 'INVALID_SETTINGS'
                  ? '设置值不在允许范围内'
                  : code == 'DEDUP_WINDOW_FULL'
                      ? '近期操作较多，请稍后再保存设置'
                      : '设备未保存设置（$code）');
        }
        await _acceptApplied(binding, requestId);
        settings = Map<String, int>.from(values);
      });

  Future<void> control(String path, String body) => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先通过蓝牙绑定设备');
        if (binding.state != 'active') {
          throw StateError('当前绑定尚未生效，请连接蓝牙完成绑定');
        }
        final preferences = await SharedPreferences.getInstance();
        final pendingKey = _pendingKey(binding);
        final pendingId = _pendingGuards[pendingKey] ??
            await NasPendingRequestStore.read(preferences, binding);
        if (pendingId != null) {
          hasPendingControl = true;
          pendingRequestAgeMs =
              NasPendingRequestStore.ageMs(preferences, binding);
          pendingRequestAgeEstimated =
              NasPendingRequestStore.isAgeEstimated(preferences, binding);
          _pendingRequestCreatedAtMs =
              preferences.getInt(NasPendingRequestStore.createdAtKey(binding));
          if (await _reconcile(binding, pendingId)) {
            controlNotice = '上次控制已确认，本次未发送新控制。请再次选择需要的操作。';
            if (_pendingGuards.containsKey(pendingKey)) {
              controlNotice = '上次控制已确认，本次未发送新控制。本机确认记录暂未清理，请稍后重试。';
            }
            return;
          }
          throw const NasGatewayException(
              'REQUEST_UNKNOWN', '上次控制结果仍待确认，本次仅查询结果，未发送新控制。请检查设备状态。');
        }
        final requestId = randomId(uuid: true);
        if (!await NasPendingRequestStore.save(
            preferences, binding, requestId)) {
          throw StateError('无法保存控制请求，暂未发送，请稍后重试');
        }
        hasPendingControl = true;
        pendingRequestAgeMs = 0;
        pendingRequestAgeEstimated = false;
        _pendingRequestCreatedAtMs =
            preferences.getInt(NasPendingRequestStore.createdAtKey(binding));
        NasGatewayHttpResult result;
        try {
          final gatewayResult = await gatewayTransport.tryWrite(
            binding,
            path: path,
            body: body,
            requestId: requestId,
          );
          if (gatewayResult == null) {
            await _clearPending(binding, requestId);
            throw const NasGatewayException(
                'GATEWAY_UNAVAILABLE', 'NAS MQTT 网关未启用或不可达，请连接蓝牙控制设备');
          }
          if (gatewayResult.body['gatewayHttpStatus'] is int) {
            if (gatewayResult.body['resultUnknown'] == true) {
              if (await _reconcile(binding, requestId)) return;
              throw const NasGatewayException(
                  'REQUEST_UNKNOWN', '控制可能已执行，结果暂未确认。请查询设备状态，无需重复操作。');
            }
            await _clearPending(binding, requestId);
            if (gatewayResult.body['commandPublished'] == false ||
                gatewayResult.body['error'] == 'GATEWAY_UNAVAILABLE') {
              throw const NasGatewayException(
                  'GATEWAY_UNAVAILABLE', 'NAS MQTT 网关不可达，控制未发送。请连接蓝牙控制设备');
            }
            throw NasGatewayException(
              'NAS_GATEWAY_REJECTED',
              'NAS 网关拒绝了控制请求（HTTP ${gatewayResult.body['gatewayHttpStatus']}）',
            );
          }
          result = gatewayResult;
        } on TimeoutException {
          if (await _reconcile(binding, requestId)) return;
          throw const NasGatewayException(
              'REQUEST_UNKNOWN', '控制结果暂未确认，请查询状态，不要重复操作');
        } on SocketException {
          if (await _reconcile(binding, requestId)) return;
          throw const NasGatewayException(
              'REQUEST_UNKNOWN', '控制结果暂未确认，请查询状态，不要重复操作');
        }
        if (result.statusCode != 200) {
          final code =
              result.body['error']?.toString() ?? 'HTTP_${result.statusCode}';
          if (code == 'REQUEST_BODY_UNKNOWN') {
            if (await _reconcile(binding, requestId)) return;
            throw const NasGatewayException(
                'REQUEST_UNKNOWN', '旧请求内容无法核验，执行结果待确认，请查询设备状态，不要直接重试。');
          }
          if (!['REQUEST_UNKNOWN', 'REQUEST_IN_PROGRESS'].contains(code)) {
            await _clearPending(binding, requestId);
          }
          throw NasGatewayException(
            code,
            const {
                  'PROFILE_MISMATCH': '设备当前档位与请求不一致，请先刷新状态',
                  'PIR_HIGH': '检测到有人，暂时不能启动排风',
                  'STARTUP_COOLDOWN': '设备正在启动保护期，请稍后再试',
                  'OTA_BUSY': '设备正在升级，暂时不能控制',
                  'REQUEST_ID_CONFLICT': '请求标识冲突，请重试',
                  'DEDUP_UNAVAILABLE': '设备存储不足，无法安全去重，暂时不能控制',
                  'DEDUP_WINDOW_FULL': '近期操作较多，设备正在保留执行记录，请稍后再操作',
                  'RATE_LIMITED': '操作过于频繁，请稍后重试',
                  'NAS_GATEWAY_REJECTED': 'NAS 网关拒绝了控制请求，请检查网关授权或配置',
                }[code] ??
                '设备未完成 NAS MQTT 控制（$code）',
          );
        }
        await _acceptApplied(binding, requestId);
      });

  Future<void> refreshAfterApplied(WifiBinding binding,
      {bool refreshSettings = false}) async {
    controlNotice = '设备已确认执行';
    try {
      if (refreshSettings) {
        final snapshot = await checkedRead(binding);
        settings = _settingsFromState(snapshot);
        status = snapshot;
        return;
      }
      status = await checkedRead(binding);
    } catch (_) {
      status = null;
      controlNotice = '设备已确认执行，最新状态暂未获取。请刷新状态，无需重复操作。';
    }
  }

  Future<void> finishPendingConfirmation() => run(() async {
        final binding = selected;
        if (binding == null) throw StateError('请先选择设备');
        final preferences = await SharedPreferences.getInstance();
        final key = _pendingKey(binding);
        final requestId = _pendingGuards[key] ??
            preferences.getString(key) ??
            preferences.getString(NasPendingRequestStore.legacyKey(binding));
        if (requestId != null &&
            !await NasPendingRequestStore.clear(preferences, binding)) {
          throw StateError('未能结束结果确认，请稍后重试');
        }
        _pendingGuards.remove(key);
        _confirmedApplied.remove(key);
        hasPendingControl = false;
        pendingRequestAgeMs = null;
        pendingRequestAgeEstimated = false;
        _pendingRequestCreatedAtMs = null;
        if (requestId == null) {
          controlNotice = '当前没有待确认的 NAS MQTT 控制请求。';
          return;
        }
        controlNotice = '已结束上次结果确认；下次点击将发送新的控制。';
      }, clearData: false);

  Future<bool> _reconcile(WifiBinding binding, String requestId) async {
    try {
      if (_confirmedApplied[_pendingKey(binding)] == requestId) {
        await _acceptApplied(binding, requestId);
        return true;
      }
      NasGatewayHttpResult? gatewayResult;
      try {
        gatewayResult = await gatewayTransport.queryRequest(binding, requestId);
      } catch (_) {
        // 网关不可用时保留 pending；不得切回已移除的设备 HTTPS 查询。
      }
      if (gatewayResult == null) {
        throw const NasGatewayException(
            'GATEWAY_QUERY_UNAVAILABLE', 'NAS 网关查询未成功；原请求仍保留，本次没有发送新控制。');
      }
      final result = gatewayResult;
      if (result.statusCode == 404 || result.body['error'] == 'UNKNOWN') {
        throw const NasGatewayException(
            'REQUEST_UNKNOWN', '设备无法确认上次请求结果；原请求仍保留，请核对设备后结束确认。');
      }
      if (result.statusCode != 200) {
        throw NasGatewayException('GATEWAY_QUERY_FAILED',
            'NAS 网关查询失败（HTTP ${result.statusCode}）；原请求仍保留。');
      }
      final statusText = result.body['status']?.toString();
      if (statusText == 'applied') {
        await _acceptApplied(binding, requestId);
        return true;
      }
      if (statusText == 'pending') {
        throw const NasGatewayException(
          'REQUEST_PENDING',
          '设备仍在处理上一次请求，请稍后刷新状态，不要重复操作',
        );
      }
      if (statusText == 'unknown') {
        throw const NasGatewayException(
          'REQUEST_UNKNOWN',
          '设备重启前请求结果未知，请刷新状态后重新操作，不要直接重试',
        );
      }
      if (statusText == 'rejected') {
        await _clearPending(binding, requestId);
        throw NasGatewayException(
          'REQUEST_REJECTED',
          '设备未执行该控制（HTTP ${result.body['httpStatus'] ?? '?'}）',
        );
      }
    } on NasGatewayException catch (e) {
      if (['REQUEST_PENDING', 'REQUEST_UNKNOWN', 'REQUEST_REJECTED']
          .contains(e.code)) rethrow;
      rethrow;
    } catch (_) {
      throw const NasGatewayException(
          'GATEWAY_QUERY_UNAVAILABLE', 'NAS 网关查询未成功；原请求仍保留，本次没有发送新控制。');
    }
    throw const NasGatewayException(
        'GATEWAY_QUERY_FAILED', 'NAS 网关未返回有效的上次请求结果；原请求仍保留，本次没有发送新控制。');
  }

  Future<Map<String, dynamic>> checkedRead(WifiBinding binding) async {
    // NAS Gateway 是远程状态读取通路；不可达时提示改用蓝牙，避免绕过网关或依赖设备 HTTPS。
    final viaGateway = await gatewayTransport.tryReadState(binding);
    if (viaGateway != null) {
      if (viaGateway.statusCode == 200) return viaGateway.body;
      final code = viaGateway.body['error']?.toString() ??
          'NAS_GATEWAY_HTTP_${viaGateway.statusCode}';
      if (code == 'READ_GRANT_REVOKED') {
        await updateRecord(binding.copy(state: 'invalid'));
        throw const NasGatewayException(
            'BINDING_INVALID', '设备已撤销此绑定，请通过蓝牙重新绑定');
      }
      throw NasGatewayException(
        code,
        code == 'READ_GRANT_REQUIRED'
            ? 'NAS 尚未验证此设备的只读授权；请先连接蓝牙同步或重新绑定'
            : code == 'STATE_UNAVAILABLE'
                ? 'NAS 当前没有设备状态快照，请确认设备 MQTT 在线'
                : 'NAS 网关拒绝读取设备状态（$code）',
      );
    }
    throw const NasGatewayException(
        'GATEWAY_UNAVAILABLE', 'NAS 网关未启用或不可达，请连接蓝牙读取设备状态');
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

  Future<void> bind() => run(_bindInternal);

  /// 供已处于 [run] 事务中的扫码导入流程复用，避免嵌套 run 因 busy 直接跳过绑定。
  Future<void> bindWithinCurrentOperation() => _bindInternal();

  Future<void> _bindInternal() async {
    if (!secureStoreReady) {
      records = await store.load();
      secureStoreReady = true;
    }
    final network = await request('wifi.status');
    // 绑定生命周期由 BLE 授权完成，不依赖设备 HTTPS 或 Gateway 在线。
    if (network['connected'] != true) {
      throw StateError('设备尚未连接 WiFi，请先完成配网');
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
                r.tokenId != expired.tokenId || r.deviceId != expired.deviceId)
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
      final beginId = preferences.getString(beginKey) ?? randomId(uuid: true);
      await preferences.setString(beginKey, beginId);
      final begin = await request('wifi.bind.begin',
          extra: {'clientId': client, 'requestId': beginId, 'replace': true});
      candidate =
          WifiBinding.fromJson({...begin, 'version': 1, 'clientId': client});
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
        host: network['ip'] is String && (network['ip'] as String).isNotEmpty
            ? network['ip'] as String
            : candidate.host);
    await updateRecord(value);
    final beforeCommit =
        await request('wifi.bind.status', extra: {'tokenId': value.tokenId});
    if (beforeCommit['bindingState'] == 'pending') {
      // token 由本次已授权 BLE 会话生成并返回；经 BLE 回送核验后再提交，
      // 避免把设备 HTTPS 或尚未拿到 read grant 的 NAS 状态当作绑定前置条件。
      final verification = await request('wifi.bind.verify', extra: {
        'tokenId': value.tokenId,
        'token': value.token,
      });
      if (verification['verified'] != true) {
        throw StateError('设备未确认本次绑定凭据');
      }
      try {
        await request('wifi.bind.commit', extra: {'tokenId': value.tokenId});
      } catch (_) {
        final remote = await request('wifi.bind.status',
            extra: {'tokenId': value.tokenId});
        if (remote['bindingState'] != 'active') rethrow;
      }
    }
    final active = value.copy(state: 'active');
    final confirmed =
        await request('wifi.bind.status', extra: {'tokenId': value.tokenId});
    if (confirmed['bindingState'] != 'active') {
      throw StateError('设备尚未完成绑定，请重新连接蓝牙后恢复');
    }
    // 绑定结果以设备 BLE 回执为准。Gateway 的状态快照可能要等下一次 MQTT
    // 发布才包含新 token，不能因此回滚刚刚成功的绑定。
    status = {
      'deviceId': device,
      'tokenId': active.tokenId,
      'bindingState': 'active',
      'transport': 'ble-mqtt',
    };
    try {
      final cached = await gatewayTransport.tryReadState(active);
      if (cached?.statusCode == 200) status = cached!.body;
    } catch (_) {
      // MQTT 状态快照尚未到达时，绑定仍然有效；后续读取会提示 Gateway 状态。
    }
    await persist([...records.where((r) => r.deviceId != device), active]);
    selected = active;
  }

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

  /// 清除设备端全部 WiFi 授权；用于旧手机丢失/卸载后，3 个槽位被占满的恢复。
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
