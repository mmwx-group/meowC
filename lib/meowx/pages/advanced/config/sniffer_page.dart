import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../me/me_kit.dart';
import 'config_kit.dart';

/// 内核配置 › 域名嗅探（对应 Bettbox lib/views/config/sniffer.dart）。
class CoreSnifferPage extends ConsumerWidget {
  const CoreSnifferPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MeSubPage.list(
    title: '域名嗅探',
    actions: [CcResetButton(onReset: () => _patch(ref).updateState((s) => s.copyWith(sniffer: defaultSniffer)))],
    children: const [
      MeSection(children: [_OverrideSnifferRow()]),
      MeSection(
        title: '选项',
        children: [
          _SnifferSwitch(label: '状态', subtitle: '开启嗅探服务设置', field: _SnifferBool.enable),
          _SnifferSwitch(label: '强制 DNS 映射', field: _SnifferBool.forceDnsMapping),
          _SnifferSwitch(label: '解析纯 IP 连接', field: _SnifferBool.parsePureIp),
          _SnifferSwitch(label: '覆盖目标地址', field: _SnifferBool.overrideDest),
        ],
      ),
      MeSection(
        title: '端口嗅探',
        children: [
          // 端口留空时显示的是内核缺省端口；HTTP 缺省覆盖目标地址，TLS / QUIC 缺省不覆盖（同 Bettbox）
          _SnifferPortRow(proto: 'HTTP', label: 'HTTP 端口嗅探', fallbackPorts: '80, 8080-8880', defaultOverride: true),
          _SnifferPortRow(proto: 'TLS', label: 'TLS 端口嗅探', fallbackPorts: '443, 8443', defaultOverride: false),
          _SnifferPortRow(proto: 'QUIC', label: 'QUIC 端口嗅探', fallbackPorts: '443, 8443', defaultOverride: false),
        ],
      ),
      MeSection(
        title: '域名与地址',
        children: [
          _SnifferListRow(field: _SnifferList.forceDomain),
          _SnifferListRow(field: _SnifferList.skipDomain),
          _SnifferListRow(field: _SnifferList.skipSrcAddress),
          _SnifferListRow(field: _SnifferList.skipDstAddress),
        ],
      ),
    ],
  );
}

PatchClashConfig _patch(WidgetRef ref) => ref.read(patchClashConfigProvider.notifier);

class _OverrideSnifferRow extends ConsumerWidget {
  const _OverrideSnifferRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(overrideSnifferProvider);
    return MeSwitchRow(
      label: '覆写 Sniffer',
      subtitle: '开启后将覆盖配置中的 Sniffer 选项',
      value: override,
      onChanged: (v) => ref.read(overrideSnifferProvider.notifier).value = v,
    );
  }
}

enum _SnifferBool {
  enable,
  forceDnsMapping,
  parsePureIp,
  overrideDest;

  bool read(Sniffer s) => switch (this) {
    enable => s.enable,
    forceDnsMapping => s.forceDnsMapping,
    parsePureIp => s.parsePureIp,
    overrideDest => s.overrideDest,
  };

  ClashConfig write(ClashConfig s, bool v) => switch (this) {
    enable => s.copyWith.sniffer(enable: v),
    forceDnsMapping => s.copyWith.sniffer(forceDnsMapping: v),
    parsePureIp => s.copyWith.sniffer(parsePureIp: v),
    overrideDest => s.copyWith.sniffer(overrideDest: v),
  };
}

class _SnifferSwitch extends ConsumerWidget {
  const _SnifferSwitch({required this.label, this.subtitle, required this.field});

  final String label;
  final String? subtitle;
  final _SnifferBool field;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(patchClashConfigProvider.select((s) => field.read(s.sniffer)));
    return MeSwitchRow(
      label: label,
      subtitle: subtitle,
      value: value,
      onChanged: (v) => _patch(ref).updateState((s) => field.write(s, v)),
    );
  }
}

/// 某个协议（sniff 表里的 HTTP / TLS / QUIC）的端口与「覆盖目标地址」：点开一个对话框一起改，保存时整条换掉。
class _SnifferPortRow extends ConsumerWidget {
  const _SnifferPortRow({
    required this.proto,
    required this.label,
    required this.fallbackPorts,
    required this.defaultOverride,
  });

  final String proto;
  final String label;
  final String fallbackPorts;
  final bool defaultOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(patchClashConfigProvider.select((s) => s.sniffer.sniff[proto]));
    final ports = config?.ports.join(', ') ?? '';
    return CcInputRow(
      label: label,
      value: ports.isEmpty ? fallbackPorts : ports,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _SnifferPortDialog(
          title: label,
          ports: ports,
          overrideDest: config?.overrideDest ?? defaultOverride,
          onSave: (newPorts, newOverrideDest) {
            final portList = newPorts.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            final newSniff = Map<String, SnifferConfig>.from(ref.read(patchClashConfigProvider).sniffer.sniff);
            newSniff[proto] = SnifferConfig(ports: portList, overrideDest: newOverrideDest);
            _patch(ref).updateState((s) => s.copyWith.sniffer(sniff: newSniff));
          },
        ),
      ),
    );
  }
}

class _SnifferPortDialog extends StatefulWidget {
  const _SnifferPortDialog({
    required this.title,
    required this.ports,
    required this.overrideDest,
    required this.onSave,
  });

  final String title;
  final String ports;
  final bool overrideDest;
  final void Function(String ports, bool overrideDest) onSave;

  @override
  State<_SnifferPortDialog> createState() => _SnifferPortDialogState();
}

class _SnifferPortDialogState extends State<_SnifferPortDialog> {
  late final _ports = TextEditingController(text: widget.ports);
  late bool _overrideDest = widget.overrideDest;

  @override
  void dispose() {
    _ports.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ports,
          autofocus: true,
          decoration: const InputDecoration(labelText: '端口', hintText: '443, 8443'),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('覆盖目标地址'),
          value: _overrideDest,
          onChanged: (v) => setState(() => _overrideDest = v),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      FilledButton(
        onPressed: () {
          widget.onSave(_ports.text, _overrideDest);
          Navigator.of(context).pop();
        },
        child: const Text('保存'),
      ),
    ],
  );
}

enum _SnifferList {
  forceDomain('强制嗅探域名'),
  skipDomain('跳过域名'),
  skipSrcAddress('跳过来源 IP'),
  skipDstAddress('跳过目标 IP');

  const _SnifferList(this.label);
  final String label;

  List<String> read(Sniffer s) => switch (this) {
    forceDomain => s.forceDomain,
    skipDomain => s.skipDomain,
    skipSrcAddress => s.skipSrcAddress,
    skipDstAddress => s.skipDstAddress,
  };

  ClashConfig write(ClashConfig s, List<String> items) {
    final v = List<String>.from(items);
    return switch (this) {
      forceDomain => s.copyWith.sniffer(forceDomain: v),
      skipDomain => s.copyWith.sniffer(skipDomain: v),
      skipSrcAddress => s.copyWith.sniffer(skipSrcAddress: v),
      skipDstAddress => s.copyWith.sniffer(skipDstAddress: v),
    };
  }
}

class _SnifferListRow extends ConsumerWidget {
  const _SnifferListRow({required this.field});

  final _SnifferList field;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(patchClashConfigProvider.select((s) => field.read(s.sniffer).length));
    return CcLinkRow(
      label: field.label,
      value: '$count 条',
      onTap: () => mePush(
        context,
        CcListPage(
          title: field.label,
          watch: (ref) => ref.watch(patchClashConfigProvider.select((s) => field.read(s.sniffer))),
          onChange: (ref, items) => _patch(ref).updateState((s) => field.write(s, items)),
        ),
      ),
    );
  }
}
