import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'wifi_credentials.dart';

class WifiScanSnapshot {
  WifiScanSnapshot({required this.networks, required this.cached})
      : capturedAt = DateTime.now();
  final DateTime capturedAt;
  final List<Map<String, dynamic>> networks;
  final bool cached;
}

/// 网络选择与密码输入分开，选择成功后将 SSID 返回配网页面。
class WifiNetworkPicker extends StatefulWidget {
  const WifiNetworkPicker({
    required this.scan,
    required this.selectedSsid,
    this.initialSnapshot,
    super.key,
  });

  final Future<WifiScanSnapshot> Function() scan;
  final String selectedSsid;
  final WifiScanSnapshot? initialSnapshot;

  @override
  State<WifiNetworkPicker> createState() => _WifiNetworkPickerState();
}

class _WifiNetworkPickerState extends State<WifiNetworkPicker> {
  final _query = TextEditingController();
  final _manualSsid = TextEditingController();
  WifiScanSnapshot? _snapshot;
  bool _scanning = false;
  bool _manual = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialSnapshot;
    _manualSsid.text = widget.selectedSsid;
    if (_snapshot == null) unawaited(_scan());
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final result = await widget.scan();
      if (mounted) setState(() => _snapshot = result);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is PlatformException
            ? error.message ?? '搜索未完成，请重试或手动输入网络'
            : error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _submitManual() {
    final ssid = _manualSsid.text;
    if (!isValidWifiSsid(ssid)) {
      setState(() => _error = '网络名称需为 1–32 个 UTF-8 字节');
      return;
    }
    Navigator.pop(context, ssid);
  }

  @override
  void dispose() {
    _query.dispose();
    _manualSsid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.toLowerCase();
    final networks = (_snapshot?.networks ?? [])
        .where((item) =>
            (item['ssid']?.toString() ?? '').toLowerCase().contains(query))
        .toList();
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(children: [
                Expanded(
                    child: Text(_manual ? '手动输入网络' : '选择 2.4 GHz WiFi',
                        style: Theme.of(context).textTheme.titleLarge)),
                if (!_manual)
                  IconButton(
                      onPressed: _scanning ? null : _scan,
                      tooltip: '重新搜索',
                      icon: const Icon(Icons.refresh)),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close)),
              ]),
            ),
            if (_manual) ...[
              Padding(
                padding: const EdgeInsets.all(20),
                child: TextField(
                    controller: _manualSsid,
                    autofocus: true,
                    enabled: true,
                    decoration: const InputDecoration(
                        labelText: 'WiFi 名称（SSID）',
                        helperText: '名称区分大小写，适用于隐藏网络'),
                    onSubmitted: (_) => _submitManual()),
              ),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FilledButton(
                      onPressed: _submitManual, child: const Text('使用此网络'))),
              const Spacer(),
            ] else ...[
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: TextField(
                    controller: _query,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        hintText: '搜索网络名称', prefixIcon: Icon(Icons.search))),
              ),
              if (_scanning) const LinearProgressIndicator(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_scanning
                        ? '正在用手机搜索附近网络…'
                        : _snapshot?.cached == true
                            ? '系统缓存结果，可刷新或手动输入网络。'
                            : '手机与设备所在位置的信号可能不同。')),
              ),
              Expanded(
                  child: networks.isEmpty
                      ? Center(
                          child: Text(_scanning
                              ? '请稍候…'
                              : query.isNotEmpty
                                  ? '没有匹配的网络'
                                  : '未发现网络，请重试或手动输入'))
                      : ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: networks.length,
                          itemBuilder: (context, index) {
                            final network = networks[index];
                            final ssid = network['ssid']?.toString() ?? '';
                            final supported = network['supported'] != false;
                            final selected = ssid == widget.selectedSsid;
                            return ListTile(
                              selected: selected,
                              leading: Icon(
                                  (network['rssi'] as num? ?? -100) >= -65
                                      ? Icons.wifi
                                      : Icons.wifi_1_bar),
                              title: Text(ssid),
                              subtitle: Text(supported
                                  ? '需要密码 · ${network['rssi']} dBm · ${((network['ageSeconds'] as num?)?.toInt() ?? 0) + DateTime.now().difference(_snapshot!.capturedAt).inSeconds} 秒前'
                                  : '暂不支持此认证方式'),
                              trailing: selected
                                  ? const Icon(Icons.check_circle)
                                  : const Icon(Icons.lock_outline, size: 18),
                              enabled: supported,
                              onTap: supported
                                  ? () => Navigator.pop(context, ssid)
                                  : null,
                            );
                          })),
            ],
            if (_error != null)
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _manual = !_manual;
                  _error = null;
                }),
                icon: Icon(_manual ? Icons.wifi_find : Icons.edit_outlined),
                label: Text(_manual ? '返回网络列表' : '找不到网络？手动输入'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
