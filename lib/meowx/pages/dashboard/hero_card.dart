import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../state/connection.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../state/wifi_switch.dart';
import '../../theme/m3.dart';
import '../../theme/latency_badge.dart';
import '../../theme/m3_kit.dart';
import '../../theme/meow_dialog.dart';
import '../../state/status.dart';
import 'node_picker.dart';

/// 连接主卡（M3 Expressive，画布稿 Main）：状态（提示 / 大字 / 已运行）+ 圆角方块电源键（同 iOS）；「当前节点」行；「规则 | 全局 | 直连」连接式按钮组。
/// 底色与首页其它卡片相同（2026-11-18 用户要求，以前已连接时换成主色容器）：状态靠大字的颜色（连上是主题色）与电源键表达；圆角 36。[dense] = 宽屏（侧栏右边的窄列）用的小一号尺寸。
class HomeHeroCard extends ConsumerWidget {
  const HomeHeroCard({super.key, this.dense = false});
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs, x = context.m3;
    final phase = ref.watch(connPhaseProvider);
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final hasProfile = ref.watch(hasProfileProvider);
    final on = phase == ConnPhase.on;
    final fg = cs.onSurface;
    final (hint, dot, status) = switch (phase) {
      // 用语同 iOS（2026-11-18）：已连接「X模式 · 保护中」、未连接「已就绪 / 未配置」
      ConnPhase.on => ('${modeLabel(mode)}模式 · 保护中', x.ok, S.connected),
      ConnPhase.connecting => ('${modeLabel(mode)}模式 · 正在启动', x.warn, S.connecting),
      ConnPhase.off when ref.watch(wifiPausedProvider) => ('Wi-Fi 规则暂停中 · 点电源键恢复', x.warn, '已暂停'),
      ConnPhase.off => (hasProfile ? S.ready : S.notConfigured, cs.onSurfaceVariant, S.disconnected),
    };
    // 内边距 / 行距 / 字号照 iOS 首页主卡收紧（2026-11-18 用户：安卓首页卡片太高）：内边距 18、行距 12、大字 32
    final gap = 12.0;
    // 卡内的节点行与没选中的模式按钮：比卡片深一档
    final track = cs.cardInner;

    return AnimatedContainer(
      duration: MeowSprings.effectsDuration,
      padding: dense ? const EdgeInsets.fromLTRB(16, 14, 16, 14) : const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cs.card,
        borderRadius: BorderRadius.circular(dense ? MeowShape.xlInc : 32),
        border: Border.all(color: cs.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AnimatedContainer(
                          duration: MeowSprings.effectsDuration,
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: dense ? 12 : 13,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        status,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: dense ? 28 : 32,
                          height: dense ? 34 / 28 : 38 / 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          // 连上之后大字换成主题色（卡片底色不再随状态变，状态靠它与电源键表达）
                          color: on ? cs.primary : fg,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _SubLine(dense: dense, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              M3PowerButton(
                size: _powerSize(context, dense),
                on: on,
                busy: phase == ConnPhase.connecting,
                enabled: ref.watch(powerEnabledProvider),
                onTap: () => unawaited(ref.read(powerProvider.notifier).toggle()),
              ),
            ],
          ),
          SizedBox(height: gap),
          _NodeRow(dense: dense, color: track),
          SizedBox(height: gap),
          // 同 iOS 的滑块分段（轨道 + 反色滑块，换段时滑块弹过去）；震动在换段时，别处改的模式（直连档自动切、托盘）只滑不震
          MeowSlideSegment<Mode>(
            items: const [(Mode.rule, S.modeRule), (Mode.global, S.modeGlobal), (Mode.direct, S.modeDirect)],
            selected: mode,
            height: dense ? 40 : 44,
            track: track,
            onChanged: (m) => setOutboundMode(ref, m),
          ),
        ],
      ),
    );
  }
}

/// 状态下面那行小字：已运行时间每秒跳，单独成一个 widget，不带着整张主卡重建。
class _SubLine extends ConsumerWidget {
  const _SubLine({required this.dense, required this.color});
  final bool dense;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 不在首页时不跟每秒的跳动；起停本身经 connPhaseProvider / 切回首页时的重建照样跟得上。
    // 只订阅到秒：运行时长有两路在写（每秒节拍 + 任务循环），按毫秒订阅的话每秒要重建两次
    final seconds = ref.watchOnTab(MeowTab.home, runTimeProvider.select((t) => t == null ? null : t ~/ 1000));
    final String text;
    if (seconds != null) {
      text = '${S.running} ${fmtUptime(Duration(seconds: seconds))}';
    } else if (ref.watch(connPhaseProvider) == ConnPhase.connecting) {
      text = '请稍候…';
    } else {
      text = ref.watch(hasProfileProvider) ? '点右边的按钮开始连接' : '先到「我的」导入订阅';
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 「当前节点」行：地区码图标块 + 节点名 + 所在组的路径 + 延迟胶囊，点了去节点页。
/// 电源键边长 = 左边三行字（状态提示、大字状态、副标题）的总高，两边上下对齐（2026-11-17 用户反馈以前 116 太大、把卡片撑高）。
/// 按系统字号算：字调大了电源键跟着变大，夹在 64–116 之间。行高与上面各行一致：小字继承 M3 bodyMedium 的 1.43 倍行高。
double _powerSize(BuildContext context, bool dense) {
  final scaler = MediaQuery.textScalerOf(context);
  double line(double fontSize) => scaler.scale(fontSize) * 1.43;
  final status = scaler.scale(dense ? 30 : 34) * (dense ? 36 / 30 : 40 / 34);
  final total = line(dense ? 12 : 13) + status + line(13) + 8;
  return total.clamp(64.0, 104.0);
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({required this.dense, required this.color});
  final bool dense;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final node = ref.watch(currentNodeProvider);
    final String name, sub;
    Widget? badge;
    IconData? icon;
    if (mode == Mode.direct) {
      name = '直连';
      sub = '全部流量不经过代理';
      icon = Icons.alt_route_rounded;
    } else if (node == null && !ref.watch(initProvider)) {
      // 刚启动、核心还没把代理组装载进来：别先报一句「没有代理组」
      name = '正在加载…';
      sub = '读取配置中';
      icon = Icons.hourglass_top_rounded;
    } else if (node == null) {
      name = '没有代理组';
      sub = ref.watch(hasProfileProvider) ? '当前配置里没有可选的节点' : '导入订阅后在这里选节点';
      icon = Icons.layers_clear_rounded;
    } else if (node.leaf.isEmpty) {
      name = node.group;
      sub = '还没有选中节点';
      icon = Icons.touch_app_rounded;
    } else {
      name = node.leaf;
      sub = node.pathText;
      badge = LatencyBadge(
        ms: ref.watch(currentNodeDelayProvider),
        mode: ref.watch(meowSettingProvider.select((s) => s.latencyMode)),
      );
    }
    // 同 iOS 的出口行：整行约 56 高
    final tile = 36.0;

    // 宽屏（侧栏 / 平板 / 桌面）点了就地弹节点浮层（同 iOS iPad / Duo）；手机照旧去节点页
    final popover = ref.watch(isWideLayoutProvider) && mode != Mode.direct && node != null;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => popover
            ? showMeowPopover<void>(
                context,
                title: '切换节点',
                width: 400,
                builder: (_) => NodePickerPanel(initialGroup: node.group),
              )
            : goTab(ref, MeowTab.proxies),
        child: ConstrainedBox(
          // 固定最小高度与统一行高：切换「规则 / 全局 / 直连」时有无延迟胶囊都不再引起卡片高度跳动
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                M3IconTile(
                  icon: icon,
                  text: icon == null ? nodeTileLabel(name) : null,
                  size: tile,
                  bg: cs.tertiaryContainer,
                  fg: cs.onTertiaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        // 图标块里已经画了国旗，名字里的那面不再重复
                        icon == null ? nodeTitleWithoutFlag(name) : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, height: 1.25, fontWeight: FontWeight.w700, color: cs.onSurface),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 1.25, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (badge != null) ...[const SizedBox(width: 8), badge],
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
