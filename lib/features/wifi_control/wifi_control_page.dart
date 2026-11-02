import 'package:flutter/material.dart';
import '../../ble/mimivent_ble_manager.dart';
import 'wifi_binding_controller.dart';
import 'wifi_binding.dart';

class WifiControlPage extends StatefulWidget {
  const WifiControlPage({required this.ble, super.key});
  final MimiVentBleManager ble;
  @override
  State<WifiControlPage> createState() => _WifiControlPageState();
}

class _WifiControlPageState extends State<WifiControlPage> {
  late final WifiBindingController controller;
  final host = TextEditingController();
  String? selectedKey;
  @override
  void initState() {
    super.initState();
    controller = WifiBindingController(widget.ble);
    controller.addListener(changed);
    controller.load();
  }

  void changed() {
    if (!mounted) return;
    final value = controller.selected;
    final key = value == null ? null : '${value.deviceId}:${value.tokenId}';
    if (selectedKey != key) {
      selectedKey = key;
      host.text = value?.host ?? '';
    }
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    controller.dispose();
    host.dispose();
    super.dispose();
  }

  Future<bool> confirm(String title, String text) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(text), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认'))
              ])) ??
      false;
  Future<void> manageClients() async {
    Map<String, dynamic>? data;
    await controller.run(() async {
      data = await controller.listDeviceClients();
    });
    if (!mounted || data == null || controller.error != null) return;
    final clients = (data!['clients'] as List).cast<Map>();
    final id = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('管理设备绑定'),
                content: clients.isEmpty
                    ? const Text('设备尚未绑定客户端')
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final client in clients)
                          TextButton(
                              onPressed: () => Navigator.pop(
                                  context, client['tokenId'] as String),
                              child: Text('撤销客户端 ${client['clientId']}')),
                      ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'))
                ]));
    if (!mounted || id == null) return;
    if (await confirm('撤销此客户端', '该客户端将无法继续通过 WiFi 访问设备。其他客户端不受影响。') &&
        mounted) {
      await controller.revokeDeviceClient(data!['deviceId'] as String, id);
    }
  }

  Future<void> editSettings() async {
    final c = controller;
    final current = c.settings;
    if (current == null) return;
    const options = <int>[
      0,
      5000,
      10000,
      20000,
      30000,
      60000,
      120000,
      180000,
      300000,
      600000
    ];
    final values = <String, int>{
      'startupCooldownMs':
          (current['startupCooldownMs'] as num?)?.toInt() ?? 30000,
      'leaveConfirmMs': (current['leaveConfirmMs'] as num?)?.toInt() ?? 30000,
      'autoExhaustMs': (current['autoExhaustMs'] as num?)?.toInt() ?? 120000,
      'manualExhaustMs': (current['manualExhaustMs'] as num?)?.toInt() ?? 60000,
      'pauseMs': (current['pauseMs'] as num?)?.toInt() ?? 300000,
    };
    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('WiFi 修改设置'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final entry in const [
                ('startupCooldownMs', '启动保护', false),
                ('leaveConfirmMs', '离开确认', true),
                ('autoExhaustMs', '自动排风', false),
                ('manualExhaustMs', '手动排风', false),
                ('pauseMs', '暂停', false),
              ])
                DropdownButtonFormField<int>(
                  value: values[entry.$1],
                  decoration: InputDecoration(labelText: entry.$2),
                  items: [
                    for (final option in options)
                      if (entry.$3 || option != 0)
                        DropdownMenuItem(
                            value: option, child: Text('$option ms')),
                  ],
                  onChanged: (value) {
                    if (value != null)
                      setDialogState(() => values[entry.$1] = value);
                  },
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, values),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (result != null) await c.saveSettings(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller, b = c.selected, s = c.status;
    final statsRange = c.stats?['range']?.toString();
    final statsLabel = const {
          'today': '今日',
          'yesterday': '昨日',
          'threeDays': '近三日',
          'sevenDays': '近七日'
        }[statsRange] ??
        statsRange ??
        '';
    return Scaffold(
        appBar: AppBar(title: const Text('WiFi 绑定与状态')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('首次绑定需连接蓝牙，并与设备处于同一局域网。绑定完成后，可在本页断开蓝牙读取状态。'),
          const SizedBox(height: 16),
          if (c.records.isNotEmpty)
            DropdownButtonFormField<WifiBinding>(
                value: b,
                decoration: const InputDecoration(labelText: '本机绑定记录'),
                items: [
                  for (final r in c.records)
                    DropdownMenuItem(
                        value: r,
                        child: Text('${r.deviceId.substring(0, 8)} · ${const {
                          'active': '已绑定',
                          'pending': '待完成',
                          'invalid': '已失效',
                          'blocked': '身份异常'
                        }[r.state]}'))
                ],
                onChanged: c.busy
                    ? null
                    : (v) {
                        if (v != null) c.select(v);
                      }),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: c.busy
                  ? null
                  : () async {
                      if (await confirm('绑定当前蓝牙设备',
                              '请确认选择的是家中的设备。重新绑定会在新授权成功后替换本机旧授权，其他家庭成员不受影响。') &&
                          mounted) await c.bind();
                    },
              child: Text(c.busy ? '正在处理…' : '通过蓝牙绑定 / 恢复绑定')),
          TextButton(
              onPressed: c.busy ? null : manageClients,
              child: const Text('通过蓝牙管理设备绑定')),
          TextButton(
              onPressed: c.busy
                  ? null
                  : () async {
                      if (await confirm('清除设备端全部 WiFi 绑定',
                              '这会删除设备上保存的全部手机 WiFi 授权。所有旧手机都需要重新绑定，当前手机也需要重新绑定。确定清除？') &&
                          mounted) {
                        await c.resetDeviceBindings();
                      }
                    },
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('清除设备端全部 WiFi 绑定')),
          if (b != null) ...[
            const SizedBox(height: 20),
            TextField(
                controller: host,
                enabled: !c.busy,
                decoration: const InputDecoration(
                    labelText: '设备局域网地址',
                    helperText: 'IP 变化时可修改地址，证书与设备身份仍须一致。')),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: c.busy ? null : () => c.read(host.text),
                icon: const Icon(Icons.wifi),
                label: const Text('通过 WiFi 读取状态')),
            TextButton(
                onPressed: c.busy
                    ? null
                    : () async {
                        if (await confirm(
                                b.state == 'pending' ? '取消待绑定任务' : '撤销设备授权',
                                b.state == 'pending'
                                    ? '取消候选授权，保留原有已生效绑定。'
                                    : '需要通过蓝牙连接该设备。撤销后，这条凭据将无法继续访问设备。') &&
                            mounted) await c.revoke();
                      },
                child: Text(b.state == 'pending' ? '通过蓝牙取消待绑定' : '通过蓝牙撤销此绑定')),
            TextButton(
                onPressed: c.busy
                    ? null
                    : () async {
                        if (await confirm('移除本机记录', '只删除本机凭据，设备上的访问权限仍然存在。') &&
                            mounted) await c.run(c.removeSelected);
                      },
                child: const Text('仅移除本机记录')),
          ],
          if (s != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('WiFi 已连接 · 已核验',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(
                              '固件：${s['firmware']}\n风机：${s['fan'] == true ? '运行' : '关闭'}\n模式：${s['mode']}\n阶段：${s['phase']}\n状态采样：${s['sampleAgeMs']} ms 前'),
                        ]))),
          if (b != null && b.state == 'active') ...[
            const SizedBox(height: 12),
            const Text('WiFi 控制（实验）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                  onPressed: c.busy
                      ? null
                      : () => c.control('/api/auto',
                          'profile=production&switchProfile=1&replace=1'),
                  child: const Text('自动模式')),
              OutlinedButton(
                  onPressed: c.busy
                      ? null
                      : () => c.control(
                          '/api/timed', 'profile=production&mode=on&replace=1'),
                  child: const Text('临时排风')),
              OutlinedButton(
                  onPressed: c.busy
                      ? null
                      : () => c.control('/api/timed',
                          'profile=production&mode=off&replace=1'),
                  child: const Text('临时暂停')),
            ]),
            const SizedBox(height: 8),
            const Text('写控制仅用于 WiFi 验收；失败时请连接蓝牙重试。',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                  onPressed: c.busy ? null : c.loadSettings,
                  child: const Text('读取设置')),
              OutlinedButton(
                  onPressed: c.busy ? null : () => c.loadStats('today'),
                  child: const Text('今日')),
              OutlinedButton(
                  onPressed: c.busy ? null : () => c.loadStats('yesterday'),
                  child: const Text('昨日')),
              OutlinedButton(
                  onPressed: c.busy ? null : () => c.loadStats('threeDays'),
                  child: const Text('近三日')),
              OutlinedButton(
                  onPressed: c.busy ? null : () => c.loadStats('sevenDays'),
                  child: const Text('近七日')),
            ]),
            if (c.settings != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('设置：\n'
                                '启动保护：${c.settings!['startupCooldownMs']} ms\n'
                                '离开确认：${c.settings!['leaveConfirmMs']} ms\n'
                                '自动排风：${c.settings!['autoExhaustMs']} ms\n'
                                '手动排风：${c.settings!['manualExhaustMs']} ms\n'
                                '暂停：${c.settings!['pauseMs']} ms'),
                            TextButton(
                                onPressed: c.busy ? null : editSettings,
                                child: const Text('修改设置')),
                          ]))),
            if (c.stats != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('$statsLabel统计：\n'
                                '运行：${c.stats!['runtimeSeconds']} 秒\n'
                                '活动：${c.stats!['activityCount']} 次\n'
                                '自动：${c.stats!['automaticCount']} 次\n'
                                '时间同步：${c.stats!['timeSynced'] == true ? '是' : '否'}'),
                            if (c.events.isNotEmpty) const SizedBox(height: 8),
                            if (c.events.isNotEmpty)
                              const Text('明细',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                            for (final event in c.events.take(5))
                              Text('#${event['id']} ${event['kind']} '
                                  '${event['state']} '
                                  '${event['durationSeconds']}s'),
                            if (c.eventsHasMore)
                              TextButton(
                                  onPressed: c.busy ? null : c.loadMoreEvents,
                                  child: const Text('加载更多明细')),
                          ]))),
          ],
          if (c.error != null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(c.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 16),
          const Text('本阶段支持 WiFi 只读与实验写控制；主页控制和固件升级仍使用蓝牙。'),
          TextButton(
              onPressed: c.busy
                  ? null
                  : () async {
                      if (await confirm('清除本机全部 WiFi 记录',
                              '用于安全存储损坏后的恢复。将删除本机全部 WiFi 凭据及加密密钥，设备上的授权仍然存在；统计和日志不受影响。清除后需要重新绑定。') &&
                          mounted) await c.resetLocalRecords();
                    },
              child: const Text('重置本机 WiFi 凭据')),
        ]));
  }
}
