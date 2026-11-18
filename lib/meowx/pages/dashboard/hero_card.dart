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

/// 连接主卡（M3 Expressive，画布稿 Main）：状态（提示 / 大字 / 已运行）+ 饼干形电源键；「当前节点」行；「规则 | 全局 | 直连」连接式按钮组。
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
    final gap = dense ? 14.0 : 18.0;
    // 卡内的节点行与没选中的模式按钮：比卡片深一档
    final track = cs.cardInner;

    return AnimatedContainer(
      duration: MeowSprings.effectsDuration,
      padding: dense ? const EdgeInsets.fromLTRB(16, 18, 16, 16) : const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: cs.card,
        borderRadius: BorderRadius.circular(dense ? MeowShape.xlInc : 36),
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
                    SizedBox(height: dense ? 4 : 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        status,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: dense ? 34 : 46,
                          height: dense ? 40 / 34 : 52 / 46,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                          // 连上之后大字换成主题色（卡片底色不再随状态变，状态靠它与电源键表达）
                          color: on ? cs.primary : fg,
                        ),
                      ),
                    ),
                    SizedBox(height: dense ? 4 : 6),
                    _SubLine(dense: dense, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              M3PowerButton(
                size: _powerSize(context, dense),
                on: on,
                busy: phase == ConnPhase.connecting,
                spinWhileOn: true,
                enabled: ref.watch(powerEnabledProvider),
                onTap: () => unawaited(ref.read(powerProvider.notifier).toggle()),
              ),
            ],
          ),
          SizedBox(height: gap),
          _NodeRow(dense: dense, color: track),
          SizedBox(height: gap),
          // 震动在 M3ButtonGroup 换段时；别处改的模式（直连档自动切、托盘）走不到这里
          M3ButtonGroup<Mode>(
            items: const [(Mode.rule, S.modeRule), (Mode.global, S.modeGlobal), (Mode.direct, S.modeDirect)],
            selected: mode,
            height: dense ? 44 : 48,
            unselectedColor: track,
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
        fontSize: dense ? 13 : 14,
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
  final status = scaler.scale(dense ? 34 : 46) * (dense ? 40 / 34 : 52 / 46);
  final total = line(dense ? 12 : 13) + status + line(dense ? 13 : 14) + (dense ? 8 : 12);
  return total.clamp(64.0, 116.0);
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
    final tile = dense ? 40.0 : 44.0;

    // 宽屏（侧栏 / 平板 / 桌面）点了就地弹节点浮层（同 iOS iPad / Duo）；手机照旧去节点页
    final popover = ref.watch(isWideLayoutProvider) && mode != Mode.direct && node != null;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(MeowShape.lInc + 4),
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
        child: Padding(
          padding: const EdgeInsets.all(12),
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
                      style: TextStyle(fontSize: dense ? 15 : 16, fontWeight: FontWeight.w700, color: cs.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: dense ? 12 : 13, color: cs.onSurfaceVariant),
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
    );
  }
}
