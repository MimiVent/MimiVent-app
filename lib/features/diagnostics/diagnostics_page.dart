import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/mimivent_theme.dart';
import '../../core/diagnostics/app_diagnostics_log.dart';
import '../../data/mimivent_controller.dart';
import '../wifi_control/wifi_control_page.dart';

/// 显示可在断开蓝牙时读取的本地 BLE 与设备接口事务记录。
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({required this.log, this.controller, super.key});

  final AppDiagnosticsLog log;
  final MimiVentController? controller;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('设备日志'),
          actions: [
            AnimatedBuilder(
              animation: log,
              builder: (context, _) => IconButton(
                tooltip:
                    log.isCapturingStatusPolls ? '结束状态原始抓取' : '抓取5分钟状态原始报文',
                onPressed: log.isCapturingStatusPolls
                    ? log.stopStatusPollCapture
                    : log.startStatusPollCapture,
                icon: Icon(
                  log.isCapturingStatusPolls
                      ? Icons.stop_circle_outlined
                      : Icons.radio_button_checked,
                  color: log.isCapturingStatusPolls ? MimiVentColors.red : null,
                ),
              ),
            ),
            if (controller != null)
              IconButton(
                tooltip: 'WiFi 绑定与状态',
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                      builder: (_) => WifiControlPage(ble: controller!.ble)),
                ),
                icon: const Icon(Icons.wifi_rounded),
              ),
            IconButton(
              tooltip: '复制全部日志',
              onPressed: () => _copyLogs(context),
              icon: const Icon(Icons.copy_all_rounded),
            ),
            IconButton(
              tooltip: '清空日志',
              onPressed: () => _confirmClear(context),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
        body: DecoratedBox(
          decoration:
              const BoxDecoration(gradient: MimiVentColors.pageGradient),
          child: SafeArea(
            top: false,
            child: Column(children: [
              AnimatedBuilder(
                animation: log,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(children: [
                    Text(
                        '${log.entries.length}/${AppDiagnosticsLog.maxEntries} 条',
                        style: const TextStyle(
                            color: MimiVentColors.muted,
                            fontSize: 11,
                            fontFamily: 'monospace')),
                    const SizedBox(width: 10),
                    Text(
                        log.isCapturingStatusPolls
                            ? '原始抓取中 · 最新在前 · 触摸可选择文本'
                            : '本机保存 · 最新在前 · 触摸可选择文本',
                        style: TextStyle(
                            color: log.isCapturingStatusPolls
                                ? MimiVentColors.amber
                                : MimiVentColors.muted,
                            fontSize: 11)),
                  ]),
                ),
              ),
              const Divider(height: 1, color: Color(0x22FFFFFF)),
              Expanded(
                child: AnimatedBuilder(
                  animation: log,
                  builder: (context, _) {
                    final entries = log.entries;
                    if (entries.isEmpty) {
                      return const Center(
                        child: Text('暂无日志',
                            style: TextStyle(
                                color: MimiVentColors.muted, fontSize: 13)),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                      itemCount: entries.length,
                      itemBuilder: (context, index) =>
                          _DiagnosticLogLine(entry: entries[index]),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      );

  Future<void> _copyLogs(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: log.exportText()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('日志已复制')));
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空设备日志？'),
        content: const Text('清空后无法恢复。新的设备交互会继续记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) await log.clear();
  }
}

class _DiagnosticLogLine extends StatelessWidget {
  const _DiagnosticLogLine({required this.entry});

  final DiagnosticLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      MimiVentDiagnosticLevel.info => MimiVentColors.mint,
      MimiVentDiagnosticLevel.warning => MimiVentColors.amber,
      MimiVentDiagnosticLevel.error => MimiVentColors.red,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 3, children: [
          Text(_formatTimestamp(entry.timestamp),
              style: const TextStyle(
                  color: MimiVentColors.muted,
                  fontSize: 10,
                  fontFamily: 'monospace')),
          Text(entry.level.name.toUpperCase(),
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace')),
          Text(entry.category,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        SelectableText(
          entry.message,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              height: 1.38,
              fontFamily: 'monospace'),
        ),
      ]),
    );
  }

  String _formatTimestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.'
        '${three(value.millisecond)}';
  }
}
