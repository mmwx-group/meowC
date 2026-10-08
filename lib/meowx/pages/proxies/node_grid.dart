import 'dart:async';
import 'dart:math' as math;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../panel/account.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/badges.dart';
import '../../theme/tokens.dart';
import '../../theme/unlock_badge.dart';
import '../../theme/widgets.dart';
import 'node_parts.dart';

const _gridSpacing = 8.0;

/// 节点格的尺寸：手机按 ANodes（内边距 10/12、行距 6、名 14、最矮 64、圆角 18），
/// 宽屏两栏按 WNodes（9/11、5、13、58、16）。
({double padH, double padV, double gap, double name, double minH, double radius}) _spec(bool dense) => dense
    ? (padH: 11, padV: 9, gap: 5, name: 13, minH: 58, radius: 16)
    : (padH: 12, padV: 10, gap: 6, name: 14, minH: 64, radius: 18);

TextStyle _nameStyle(double size, [Color? color]) => TextStyle(fontSize: size, fontWeight: FontWeight.w600, color: color);
TextStyle _subStyle([Color? color]) => MeowFont.mono(size: 11, color: color);

/// 节点格高度：两行（地区码 + 名 / 副标题 + 徽标 + 延迟胶囊）。网格是懒加载、定高的（mainAxisExtent），不能让格子自己撑开，
/// 所以按主题字样和文字缩放量出来——写死的话文字继承 M3 bodyMedium 的行高 1.43，字号调大一档第二行就越出格子底边。
double _nodeCellExtent(BuildContext context, bool dense) {
  final s = _spec(dense);
  final scaler = MediaQuery.textScalerOf(context);
  final base = DefaultTextStyle.of(context).style;
  double lineHeight(TextStyle style, String sample) {
    final tp = TextPainter(
      text: TextSpan(text: sample, style: base.merge(style)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final h = tp.height;
    tp.dispose();
    return h;
  }

  // 样例带中文和国旗：CJK 字体与彩色 emoji 的行高都比拉丁字母高
  final name = math.max(
    lineHeight(_nameStyle(s.name), 'Ag节点🇺🇸'),
    19.0,   // RegionTag：字 10 × 行高 1.2、缩放封顶 1.2、上下 padding 2+2
  );
  final sub = [
    lineHeight(_subStyle(), 'vless · reality 直连'),
    lineHeight(MeowFont.mono(size: 11, weight: FontWeight.w700), '88 ms超时') + 4,   // 延迟胶囊上下 padding 2+2
    19.0,   // 奖牌 15 + 点按边距 2+2
  ].max;
  return math.max(s.minH, s.padV * 2 + name + s.gap + sub).ceilToDouble();
}

/// url-test / fallback 组正在切换的目标：组名 → 节点名（乐观高亮 + 格子转圈，核心回报后清掉）。
final pendingPickProvider = StateProvider<Map<String, String>>((ref) => const {});

/// url-test / fallback 组被手动固定的成员；没固定（或记下的名字已经不在组里）→ 空串。
String watchFixedMember(WidgetRef ref, Group group) {
  if (!group.type.isComputedSelected) return '';
  final name = ref.watch(getProxyNameProvider(group.name)) ?? '';
  return group.all.any((p) => p.name == name) ? name : '';
}

/// 点选节点。
/// - select 组：本地高亮即时生效，核心切换沿用 Bettbox 的 600 ms 防抖（合并连点）。
/// - url-test / fallback 组：点节点 = 固定（SelectAble.Set），点已固定的 = 取消（ForceSet("")）。高亮只认核心回报的 now，
///   所以不走防抖、先乐观高亮；另外 mihomo 的 Fallback.Set 遇到失效节点会持核心全局锁同步测速最多 5 秒，
///   期间拉代理组 / 连接列表全被卡住——已知失效的节点先在锁外单独测一次，测不通就不切。
///   切完以核心结果为准：没切过去（节点不可用被 mihomo 清掉）就撤掉图钉并提示，不留一个假的固定状态。
Future<void> pickNode(WidgetRef ref, Group group, Proxy proxy) async {
  final c = globalState.appController;
  if (!group.type.isComputedSelected) {
    c.updateCurrentSelectedMap(group.name, proxy.name);
    c.changeProxyDebounce(group.name, proxy.name);
    return;
  }
  final pinned = ref.read(getProxyNameProvider(group.name)) ?? '';
  final next = proxy.name == pinned ? '' : proxy.name;
  final pending = ref.read(pendingPickProvider.notifier);
  pending.update((m) => {...m, group.name: next});
  c.updateCurrentSelectedMap(group.name, next);

  Future<void> reject() async {
    c.updateCurrentSelectedMap(group.name, '');
    await c.changeProxy(groupName: group.name, proxyName: '');
    await c.updateGroups();   // 立刻拿到自动选中的节点，高亮别先回到旧节点再跳
    globalState.showNotifier('$next 当前不可用，已恢复自动选择');
  }

  try {
    if (next.isNotEmpty) {
      final known = ref.read(getDelayProvider(proxyName: next, testUrl: group.testUrl));
      final tcping = ref.read(meowSettingProvider).latencyMode == LatencyMode.tcping;   // TCPing 不更新 mihomo 的存活状态，测了也没用
      if (known != null && known < 0 && !tcping) {
        await proxyDelayTest(proxy, group.testUrl);
        final after = ref.read(getDelayProvider(proxyName: next, testUrl: group.testUrl));
        if (after == null || after <= 0) {
          await reject();
          return;
        }
      }
    }
    await c.changeProxy(groupName: group.name, proxyName: next);
    await c.updateGroups();
    if (next.isNotEmpty) {
      final now = ref.read(groupsProvider).getGroup(group.name)?.now;
      if (now != null && now.isNotEmpty && now != next) await reject();
    }
  } catch (e) {
    commonPrint.log('pick node failed: $e');
  } finally {
    pending.update((m) => m[group.name] == next ? ({...m}..remove(group.name)) : m);
  }
}

/// 「自动选择」开关（url-test / fallback 组）：打开 = 取消固定，关掉 = 把当前自动选中的节点固定下来。
/// 两个方向都等于「点一下那个成员」，走 [pickNode] 同一套乐观高亮与失败回滚。
void toggleAutoSelect(WidgetRef ref, Group group) {
  final pinned = ref.read(getProxyNameProvider(group.name)) ?? '';
  final current = ref.read(getSelectedProxyNameProvider(group.name)) ?? '';
  final proxy =
      group.all.firstWhereOrNull((p) => p.name == pinned) ?? group.all.firstWhereOrNull((p) => p.name == current);
  if (proxy != null) unawaited(pickNode(ref, group, proxy));
}

/// 列数跟着网格宽度走：手机标准 2 列、大卡 1 列，更宽（平板、宽屏右栏）按最小格宽加列。
/// 在滚动视图外面量宽度再传进来——SliverLayoutBuilder 每滚一帧都会重建网格。
int nodeColumns(double width, NodeCardSize size) {
  final large = size == NodeCardSize.large;
  return math.max(large ? 1 : 2, ((width + _gridSpacing) / ((large ? 260 : 185) + _gridSpacing)).floor());
}

/// 懒加载节点网格：只构建可见格子；每格自带 RepaintBoundary。
class NodeSliverGrid extends ConsumerWidget {
  const NodeSliverGrid({super.key, required this.group, required this.columns, this.dense = false});
  final Group group;
  final int columns;

  /// 宽屏两栏里的小一号格子。
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedName = ref.watch(getSelectedProxyNameProvider(group.name)) ?? '';
    final metas = ref.watch(proxyMetaProvider);
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    // select 组点了就切；url-test / fallback 组点了是「固定」到该节点，再点一次取消（见 pickNode）
    final computed = group.type.isComputedSelected;
    final selectable = computed || group.type == GroupType.Selector;
    final pinned = watchFixedMember(ref, group);
    final pendingPick = computed ? ref.watch(pendingPickProvider.select((m) => m[group.name])) : null;
    final shownSelected = (pendingPick != null && pendingPick.isNotEmpty) ? pendingPick : selectedName;
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: _gridSpacing,
        crossAxisSpacing: _gridSpacing,
        mainAxisExtent: _nodeCellExtent(context, dense),
      ),
      delegate: SliverChildBuilderDelegate((context, i) {
        final p = group.all[i];
        return _NodeCell(
          key: ValueKey(p.name),
          proxy: p,
          group: group,
          meta: metas[p.name],
          selected: p.name == shownSelected,
          pinned: pinned.isNotEmpty && p.name == pinned,
          busy: pendingPick != null && pendingPick.isNotEmpty && pendingPick == p.name,
          mode: mode,
          dense: dense,
          onTap: selectable ? () => unawaited(pickNode(ref, group, p)) : null,
        );
      }, childCount: group.all.length),
    );
  }
}

/// 节点格：地区码 + 名（+ 图钉）；行 2 协议 / 安全性副标题 + 回程奖牌 + 解锁 + 延迟胶囊（点 = 测该成员）。
/// 白卡；选中 = 柔粉底 + 玫红 2px 描边。
class _NodeCell extends ConsumerWidget {
  const _NodeCell({
    super.key,
    required this.proxy,
    required this.group,
    required this.meta,
    required this.selected,
    this.pinned = false,
    this.busy = false,
    required this.mode,
    required this.dense,
    required this.onTap,
  });

  final Proxy proxy;
  final Group group;
  final ProxyMeta? meta;
  final bool selected;

  /// url-test / fallback 组里被手动固定的节点（名字旁画图钉）。
  final bool pinned;

  /// 正在切到这个节点（核心还没回报）：延迟胶囊的位置转圈。
  final bool busy;
  final LatencyMode mode;
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final s = _spec(dense);
    final nested = isGroupType(proxy.type);
    final builtin = builtinSubtitle(proxy.name);
    final style = protoStyle(proxy.type, mm);
    final subtitle =
        builtin ??
        (nested
            ? '${S.nestedGroup} · ${groupBadge(proxy.type, mm).label}'
            : (meta?.securitySubtitle.isNotEmpty == true
                  ? '${style.label} · ${meta!.securitySubtitle}'
                  : style.label));
    final (code, name) = splitRegion(proxy.name);
    final delay = ref.watch(
      getDelayProvider(proxyName: proxy.name, testUrl: group.testUrl),
    );
    final medal = ref.watch(medalsProvider.select((m) => m[proxy.name]));
    final unlocks = ref.watch(unlocksProvider.select((m) => m[proxy.name]));
    final testable = !const {
      'REJECT',
      'REJECT-DROP',
      'PASS',
    }.contains(proxy.name.toUpperCase());

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        // 描边的 2 算在内边距里：选中 / 未选中内容不位移
        padding: EdgeInsets.symmetric(horizontal: s.padH - 2, vertical: s.padV - 2),
        decoration: BoxDecoration(
          // 深色主题的 soft 是半透明的，先叠到卡片底上，不然透出的是页面底、比没选中的格子还暗
          color: selected ? Color.alphaBlend(mm.soft, mm.elev) : mm.elev,
          borderRadius: BorderRadius.circular(s.radius),
          border: Border.all(color: selected ? mm.accent : Colors.transparent, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                if (code != null) ...[RegionTag(code), const SizedBox(width: 6)],
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _nameStyle(s.name, mm.t1),
                  ),
                ),
                if (nested) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.layers_rounded, size: 14, color: mm.t2),
                ],
                if (pinned) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '已固定，再点一次恢复自动选择',
                    child: Icon(Icons.push_pin_rounded, size: dense ? 13 : 14, color: mm.accent),
                  ),
                ],
              ],
            ),
            SizedBox(height: s.gap),
            FitRow(
              text: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _subStyle(mm.t2),
              ),
              tail: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 徽标自带 2 的点按边距，间距按视觉 6 配
                  if (medal != null) ...[const SizedBox(width: 4), MedalBadge(medal, size: dense ? 14 : 15)],
                  if (unlocks != null) ...[const SizedBox(width: 4), UnlockBadge(unlocks, size: dense ? 13 : 14)],
                  if (busy)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, right: 8),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: mm.accent),
                      ),
                    )
                  else if (testable) ...[
                    SizedBox(width: medal != null || unlocks != null ? 4 : 6),
                    GestureDetector(
                      onTap: () => proxyDelayTest(proxy, group.testUrl),
                      child: MsChip(delay, mode: mode, bg: mm.card2),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
