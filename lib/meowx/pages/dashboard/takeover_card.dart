import 'dart:async';

import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection.dart';
import '../../theme/glass_card.dart';
import '../../theme/tokens.dart';

/// Windows 专属：接管方式。电源键只拉起核心，流量怎么进来由这两个开关决定——
/// 虚拟网卡（TUN，接管全部流量，需 MeowX 服务）与系统代理，可以同时打开。开关逻辑在 state/connection.dart，侧栏那两个钮共用。
class HomeTakeoverCard extends ConsumerWidget {
  const HomeTakeoverCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final tun = ref.watch(tunEnabledProvider);
    final sys = ref.watch(systemProxyEnabledProvider);
    final (tunHint, tunWarn) = ref.watch(tunHintProvider);
    final installing = ref.watch(takeoverProvider.select((s) => s.installing));
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));

    Widget row(String title, Widget hint, bool value, ValueChanged<bool>? onChanged) => Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: mm.line))),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.t1),
                ),
                const SizedBox(height: 1),
                hint,
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ],
      ),
    );

    return GlassCard(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 6, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Row(
              children: [
                Text('接管方式', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.t2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '两个都关 = 只有手动设代理的程序走 MeowX',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 11, color: mm.t2),
                  ),
                ),
              ],
            ),
          ),
          row(
            '虚拟网卡（TUN）',
            Text(
              tunHint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: tunWarn ? mm.mid : (tun ? mm.good : mm.t2)),
            ),
            tun,
            installing ? null : (v) => unawaited(ref.read(takeoverProvider.notifier).setTun(context, v)),
          ),
          row(
            '系统代理',
            Text(
              '127.0.0.1:$port',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MeowFont.mono(size: 11, color: mm.t2),
            ),
            sys,
            (v) => ref.read(takeoverProvider.notifier).setSystemProxy(v),
          ),
        ],
      ),
    );
  }
}
