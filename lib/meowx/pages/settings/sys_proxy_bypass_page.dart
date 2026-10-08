import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/page_title.dart';
import '../me/me_kit.dart';

/// 系统代理排除域名（Windows）：这些域名 / 地址不经系统代理。存在 Bettbox 的 `NetworkProps.bypassDomain`，
/// 与「高级 → 网络」里的同名项是同一份。
class SysProxyBypassPage extends ConsumerWidget {
  const SysProxyBypassPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(networkSettingProvider.select((s) => s.bypassDomain));
    final notifier = ref.read(networkSettingProvider.notifier);
    return MeSubPage.list(
      title: '系统代理排除域名',
      actions: [
        RoundGlassButton(
          icon: Icons.replay_rounded,
          tooltip: '恢复默认',
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('恢复默认'),
                content: const Text('把排除列表恢复成默认值？'),
                actions: [
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('恢复')),
                ],
              ),
            );
            if (ok == true) notifier.updateState((s) => s.copyWith(bypassDomain: defaultBypassDomain));
          },
        ),
        RoundGlassButton(
          icon: Icons.add_rounded,
          filled: true,
          tooltip: '添加',
          onTap: () async {
            final input = (await mePrompt(context, '添加排除域名', '', helper: '例如 localhost、*.example.com、192.168.*'))?.trim();
            if (input == null || input.isEmpty) return;
            notifier.updateState((s) => s.copyWith(bypassDomain: {...s.bypassDomain, input}.toList()));
          },
        ),
      ],
      children: [
        MeItemsCard(
          items: items,
          onDelete: (i) => notifier.updateState((s) => s.copyWith(bypassDomain: [...s.bypassDomain]..removeAt(i))),
        ),
        const MeCaption('这些域名 / 地址不经系统代理，支持 * 通配。'),
      ],
    );
  }
}
