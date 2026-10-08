import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../state/connection.dart';
import '../../state/format.dart';
import '../../state/latency.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';

/// 连接主卡：状态（提示 / 大字 / 已运行）+ 电源键；「当前节点」行；「规则 | 全局 | 直连」分段。
/// 已连接 = 樱粉底，其余 = 次级底。[dense] = 宽屏（侧栏右边的窄列）用的小一号尺寸。
class HomeHeroCard extends ConsumerWidget {
  const HomeHeroCard({super.key, this.dense = false});
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final phase = ref.watch(connPhaseProvider);
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final hasProfile = ref.watch(hasProfileProvider);
    // Android 上启动 = 建立 VPN（关了「VPN」只起核心和本地端口）；Windows 上电源键只拉起核心，流量怎么进来看接管方式
    final vpn = system.isAndroid && !isDesktopUi && ref.watch(vpnSettingProvider.select((s) => s.enable));
    final (hint, tone, status) = switch (phase) {
      ConnPhase.on => ('${modeLabel(mode)}模式 · ${vpn ? 'VPN 已建立' : '核心运行中'}', mm.good, S.connected),
      ConnPhase.connecting => ('${modeLabel(mode)}模式 · 正在启动', mm.mid, S.connecting),
      ConnPhase.off => (hasProfile ? S.ready : S.notConfigured, mm.t2, S.disconnected),
    };
    final gap = dense ? 10.0 : 12.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.all(dense ? 16 : 18),
      decoration: BoxDecoration(
        color: phase == ConnPhase.on ? mm.hero : mm.card2,
        borderRadius: BorderRadius.circular(dense ? 24 : 28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusDot(color: tone),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: dense ? 12 : 13, fontWeight: FontWeight.w600, color: tone),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: dense ? 2 : 4),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense ? 28 : 32,
                        fontWeight: FontWeight.w700,
                        height: dense ? 34 / 28 : 38 / 32,
                        color: mm.t1,
                        fontFamilyFallback: meowRounded,
                      ),
                    ),
                    SizedBox(height: dense ? 2 : 4),
                    _SubLine(dense: dense),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              MeowPowerButton(
                size: dense ? 68 : 80,
                on: phase == ConnPhase.on,
                busy: phase == ConnPhase.connecting,
                enabled: ref.watch(powerEnabledProvider),
                onTap: () => unawaited(ref.read(powerProvider.notifier).toggle()),
              ),
            ],
          ),
          SizedBox(height: gap),
          _NodeRow(dense: dense),
          SizedBox(height: gap),
          MeowSegment<Mode>(
            items: const [(Mode.rule, S.modeRule), (Mode.global, S.modeGlobal), (Mode.direct, S.modeDirect)],
            value: mode,
            height: dense ? 40 : 44,
            fontSize: dense ? 13 : 14,
            onChanged: (m) {
              if (m != mode) setOutboundMode(ref, m);
            },
          ),
        ],
      ),
    );
  }
}

/// 状态下面那行等宽小字：已运行时间每秒跳，单独成一个 widget，不带着整张主卡重建。
class _SubLine extends ConsumerWidget {
  const _SubLine({required this.dense});
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runTime = ref.watch(runTimeProvider);
    final String text;
    if (runTime != null) {
      text = '${S.running} ${fmtUptime(Duration(milliseconds: runTime))}';
    } else if (ref.watch(connPhaseProvider) == ConnPhase.connecting) {
      text = '请稍候…';
    } else {
      text = ref.watch(hasProfileProvider) ? '点按右侧按钮开始' : '先到「我的」导入订阅';
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: MeowFont.mono(size: dense ? 12 : 13, color: context.mm.t2),
    );
  }
}

/// 「当前节点」行：地区码 + 节点名 + 所在组的路径 + 延迟，点了去节点页。
class _NodeRow extends ConsumerWidget {
  const _NodeRow({required this.dense});
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final node = ref.watch(currentNodeProvider);
    final String name, sub;
    String? code;
    (String, Color)? delay;
    if (mode == Mode.direct) {
      name = '直连';
      sub = '全部流量不经过代理';
    } else if (node == null) {
      name = '没有代理组';
      sub = ref.watch(hasProfileProvider) ? '当前配置里没有可选的节点' : '导入订阅后在这里选节点';
    } else if (node.leaf.isEmpty) {
      name = node.group;
      sub = '还没有选中节点';
    } else {
      name = stripFlag(node.leaf);
      sub = node.pathText;
      code = regionCode(node.leaf);
      delay = msStyle(mm, ref.watch(currentNodeDelayProvider), ref.watch(meowSettingProvider.select((s) => s.latencyMode)));
    }

    return Material(
      color: mm.elev,
      borderRadius: BorderRadius.circular(dense ? 16 : 18),
      child: InkWell(
        borderRadius: BorderRadius.circular(dense ? 16 : 18),
        onTap: () => goTab(ref, MeowTab.proxies),
        child: Container(
          constraints: BoxConstraints(minHeight: dense ? 48 : 56),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 6 : 8),
          child: Row(
            children: [
              if (code != null) ...[RegionTag(code, large: true), const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: dense ? 14 : 15, fontWeight: FontWeight.w600, color: mm.t1),
                    ),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: dense ? 11 : 12, color: mm.t2),
                    ),
                  ],
                ),
              ),
              if (delay != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(10)),
                  child: Text(delay.$1, style: MeowFont.mono(size: 12, weight: FontWeight.w700, color: delay.$2)),
                ),
              ],
              const SizedBox(width: 8),
              MeowIcon(MeowGlyph.chevron, size: dense ? 15 : 16, color: mm.t2),
            ],
          ),
        ),
      ),
    );
  }
}
