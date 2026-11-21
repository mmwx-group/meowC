import 'dart:async';

import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/tokens.dart';

/// 桌面端可选卡片：接管方式。电源键拉起核心后，由虚拟网卡（TUN）与系统代理决定流量接管方式，两者可同时开启。
/// 开关逻辑在 state/connection.dart，与左侧栏底部微控制台共用状态。
class HomeTakeoverCard extends ConsumerWidget {
  const HomeTakeoverCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final mm = context.mm;
    final tun = ref.watch(tunEnabledProvider);
    final sys = ref.watch(systemProxyEnabledProvider);
    final (tunHint, tunWarn) = ref.watch(tunHintProvider);
    final installing = ref.watch(takeoverProvider.select((s) => s.installing));
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));

    Widget row(String title, Widget hint, bool value, ValueChanged<bool>? onChanged) => Container(
      constraints: const BoxConstraints(minHeight: 50),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)))),
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
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface),
                ),
                const SizedBox(height: 1),
                hint,
              ],
            ),
          ),
          const SizedBox(width: 10),
          Transform.scale(
            scale: 0.88,
            child: Switch(
              value: value,
              onChanged: MeowHaptics.onSwitch(onChanged),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );

    return M3Card(
      padding: const EdgeInsets.fromLTRB(16, 10, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Text('接管方式', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '关闭两项时仅手动配置代理的程序走 MeowX',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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
              style: TextStyle(fontSize: 11, color: tunWarn ? mm.mid : (tun ? mm.good : cs.onSurfaceVariant)),
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
              style: MeowFont.mono(size: 11, color: cs.onSurfaceVariant),
            ),
            sys,
            (v) => ref.read(takeoverProvider.notifier).setSystemProxy(v),
          ),
        ],
      ),
    );
  }
}
