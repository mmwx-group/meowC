import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/meow_settings.dart';
import '../../state/overrides.dart';
import '../../state/status.dart';
import '../../theme/page_title.dart';
import '../me/me_kit.dart';

/// 改了覆写后：连着就重载（覆写只在 patchRawConfig 里生效）。
void _reloadIfRunning(WidgetRef ref) {
  if (ref.read(isRunningProvider)) globalState.appController.applyProfileDebounce(silence: true);
}

/// DNS 劫持：域名 → IPv4（不能落在 fake-ip 段）。
class DnsHijackPage extends ConsumerWidget {
  const DnsHijackPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final map = ref.watch(meowSettingProvider.select((s) => s.dnsHijack));
    final entries = map.entries.toList();
    return MeSubPage.list(
      title: 'DNS 劫持',
      actions: [
        RoundGlassButton(
          icon: Icons.add_rounded,
          filled: true,
          tooltip: '添加',
          onTap: map.length >= overridesLimit ? null : () => _addHijack(context, ref),
        ),
      ],
      children: [
        // 域名 / IP 上下两行：长域名不和 IP 抢宽度
        MeItemsCard(
          items: [for (final e in entries) e.key],
          subtitles: [for (final e in entries) e.value],
          empty: '把某个域名的解析结果固定为指定 IPv4，点右上角「+」添加',
          onDelete: (i) {
            ref
                .read(meowSettingProvider.notifier)
                .updateState((s) => s.copyWith(dnsHijack: {...s.dnsHijack}..remove(entries[i].key)));
            _reloadIfRunning(ref);
          },
        ),
        MeCaption('${map.length} / $overridesLimit'),
      ],
    );
  }

  Future<void> _addHijack(BuildContext context, WidgetRef ref) async {
    final domain = TextEditingController();
    final ip = TextEditingController();
    String? domainErr, ipErr;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
          scrollable: true,
          title: const Text('添加 DNS 劫持'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: domain, autofocus: true, decoration: InputDecoration(labelText: '域名', hintText: 'example.com', errorText: domainErr, errorMaxLines: 3)),
              const SizedBox(height: 8),
              TextField(controller: ip, decoration: InputDecoration(labelText: 'IPv4', hintText: '1.2.3.4', errorText: ipErr, errorMaxLines: 3), keyboardType: TextInputType.number),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final d = normalizeDomain(domain.text);
                final de = d == null ? domainInvalidMessage : null;
                final ie = validateHijackIp(ip.text);
                if (de != null || ie != null) {
                  setState(() {
                    domainErr = de;
                    ipErr = ie;
                  });
                  return;
                }
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(dnsHijack: {...s.dnsHijack, d!: ip.text.trim()}));
                _reloadIfRunning(ref);
                Navigator.of(ctx).pop();
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 绕过代理：域名 + CIDR 两段。
class BypassPage extends ConsumerWidget {
  const BypassPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final domains = ref.watch(meowSettingProvider.select((s) => s.bypassDomains));
    final cidrs = ref.watch(meowSettingProvider.select((s) => s.bypassCidrs));
    final total = domains.length + cidrs.length;
    final notifier = ref.read(meowSettingProvider.notifier);
    return MeSubPage.list(
      title: '绕过代理',
      actions: [
        RoundGlassButton(
          icon: Icons.add_rounded,
          filled: true,
          tooltip: '添加',
          onTap: total >= overridesLimit ? null : () => _add(context, ref),
        ),
      ],
      children: [
        MeItemsCard(
          title: '域名',
          items: domains,
          onDelete: (i) {
            notifier.updateState((s) => s.copyWith(bypassDomains: [...s.bypassDomains]..removeAt(i)));
            _reloadIfRunning(ref);
          },
        ),
        MeItemsCard(
          title: 'IP / CIDR',
          items: cidrs,
          onDelete: (i) {
            notifier.updateState((s) => s.copyWith(bypassCidrs: [...s.bypassCidrs]..removeAt(i)));
            _reloadIfRunning(ref);
          },
        ),
        MeCaption('$total / $overridesLimit · 命中的域名 / IP 直连，不经代理'),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final input = TextEditingController();
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          title: const Text('添加绕过'),
          content: TextField(
            controller: input,
            autofocus: true,
            // hint 默认只显示一行，三个示例会被截断
            decoration: InputDecoration(labelText: '域名或 IP / CIDR', hintText: 'example.com、+.example.com、10.0.0.0/8', hintMaxLines: 2, errorText: err, errorMaxLines: 3),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final raw = input.text.trim();
                final cidr = normalizeCidr(raw);
                final domain = cidr == null ? normalizeDomain(raw) : null;
                if (cidr == null && domain == null) {
                  setState(() => err = raw.contains(':') || RegExp(r'^[\d./]+$').hasMatch(raw) ? cidrInvalidMessage : domainInvalidMessage);
                  return;
                }
                ref.read(meowSettingProvider.notifier).updateState((s) => cidr != null
                    ? s.copyWith(bypassCidrs: {...s.bypassCidrs, cidr}.toList())
                    : s.copyWith(bypassDomains: {...s.bypassDomains, domain!}.toList()));
                _reloadIfRunning(ref);
                Navigator.of(ctx).pop();
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}
