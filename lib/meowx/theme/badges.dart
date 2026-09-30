import 'package:flutter/material.dart';

import '../app/strings.dart';
import '../panel/models.dart';
import '../state/latency.dart';
import 'popover.dart';
import 'tokens.dart';

/// 延迟胶囊：caption2 等宽 bold，底同色 0.15；null →「—」灰；≤0 →「超时」灰。
class LatencyChip extends StatelessWidget {
  const LatencyChip(this.ms, {super.key, this.mode = LatencyMode.url, this.testing = false});

  final int? ms;
  final LatencyMode mode;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final String text;
    final Color color;
    if (ms == null) {
      text = '—';
      color = mm.t3;
    } else if (ms == 0) {
      // Bettbox 的 delayMap 用 0 表示「测试中」，不是超时
      text = '…';
      color = mm.t3;
    } else if (ms! < 0 || ms! >= 100000) {
      text = S.timeout;
      color = mm.t3;
    } else {
      text = '$ms ms';
      color = latencyColor(ms!, mode, mm);
    }
    return Opacity(
      opacity: testing || ms == 0 ? 0.35 : 1,
      child: Container(
        constraints: const BoxConstraints(minWidth: 30),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: MeowFont.mono(size: MeowFont.caption2, weight: FontWeight.bold, color: color),
        ),
      ),
    );
  }
}

/// 类型徽标：caption2 等宽，底同色 0.16。
class TypeBadge extends StatelessWidget {
  const TypeBadge(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: MeowFont.mono(size: MeowFont.caption2, weight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// 协议 → （显示名, 颜色）。mihomo /proxies 里的 type 首字母大写，统一小写比较。
({String label, Color color}) protoStyle(String type, MeowTokens mm) {
  final t = type.toLowerCase();
  return switch (t) {
    'vless' => (label: 'vless', color: mm.pur),
    'vmess' => (label: 'vmess', color: mm.accent),
    'trojan' => (label: 'trojan', color: mm.slow),
    'shadowsocks' || 'ss' => (label: 'ss', color: mm.good),
    'shadowsocksr' || 'ssr' => (label: 'ssr', color: mm.good),
    'hysteria2' || 'hysteria' => (label: 'hy2', color: mm.down),
    'tuic' => (label: 'tuic', color: mm.down),
    'anytls' => (label: 'anytls', color: mm.teal),
    'wireguard' => (label: 'wg', color: mm.orange),
    'mieru' => (label: 'mieru', color: const Color(0xFF3EB489)),
    'socks5' || 'http' || 'ssh' => (label: t, color: mm.t2),
    _ => (label: t, color: mm.t2),
  };
}

/// 代理组类型 → （显示名, 颜色）。
({String label, Color color}) groupBadge(String type, MeowTokens mm) {
  return switch (type.toLowerCase()) {
    'selector' || 'select' => (label: 'select', color: mm.pur),
    'urltest' || 'url-test' => (label: 'url-test', color: mm.accent),
    'fallback' => (label: 'fallback', color: mm.good),
    'loadbalance' || 'load-balance' => (label: 'load-balance', color: mm.orange),
    'relay' => (label: 'relay', color: mm.t2),
    final other => (label: other, color: mm.t2),
  };
}

const groupTypeNames = {'selector', 'urltest', 'fallback', 'loadbalance', 'relay'};

bool isGroupType(String type) => groupTypeNames.contains(type.toLowerCase());

/// 内置策略：DIRECT/REJECT/REJECT-DROP/PASS/GLOBAL 副标题
String? builtinSubtitle(String name) => switch (name.toUpperCase()) {
  'DIRECT' => S.builtinDirect,
  'REJECT' || 'REJECT-DROP' => S.builtinReject,
  'PASS' => S.builtinPass,
  'GLOBAL' => S.builtinGlobal,
  _ => null,
};

/// 节点奖牌（服务端判定）：金 / 银；点按弹三网回程明细，点其他地方关闭。
class MedalBadge extends StatelessWidget {
  const MedalBadge(this.medal, {super.key, this.size = 14, this.tappable = true});
  final NodeMedal medal;
  final double size;
  final bool tappable;

  /// 与 iOS / macOS 同一套 RGB（金 #D99E26 / 银 #9EA3AD），图标同为五角星、无底纯色。
  static Color color(String medal) => medal == 'gold' ? const Color(0xFFD99E26) : const Color(0xFF9EA3AD);

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.star_rounded, size: size, color: color(medal.medal));
    if (!tappable) return icon;
    return Builder(
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showAnchoredPopover(ctx, builder: (_) => MedalDetail(medal: medal)),
        child: Padding(padding: const EdgeInsets.all(2), child: icon),
      ),
    );
  }
}

/// 三网回程明细：每个运营商一行。
class MedalDetail extends StatelessWidget {
  const MedalDetail({super.key, required this.medal});
  final NodeMedal medal;

  static String carrierCN(String c) => switch (c.toLowerCase()) {
    'telecom' || 'ct' => '电信',
    'unicom' || 'cu' => '联通',
    'mobile' || 'cm' => '移动',
    _ => c,
  };

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final gold = medal.medal == 'gold';
    // 运营商名列宽 = 2 个汉字，跟着文字缩放走，三行一样宽、后面的列对齐
    final carrierWidth = MediaQuery.textScalerOf(context).scale(MeowFont.caption) * 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MedalBadge(medal, size: 16, tappable: false),
              const SizedBox(width: 6),
              Expanded(child: Text(medal.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: mm.t1))),
              const SizedBox(width: 8),
              Text(gold ? '金牌' : '银牌', style: TextStyle(fontSize: MeowFont.caption2, fontWeight: FontWeight.w600, color: gold ? mm.orange : mm.t3)),
            ],
          ),
          Divider(height: 14, color: mm.t3.withValues(alpha: 0.2)),
          if (medal.routes.isEmpty)
            Text('暂无三网回程数据', style: TextStyle(fontSize: MeowFont.caption, color: mm.t2))
          else
            for (final r in medal.routes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: carrierWidth, child: Text(carrierCN(r.carrier), maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w500, color: mm.t1))),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${r.routeType}${r.region != null ? '（${r.region}）' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2))),
                    if (r.gold) Icon(Icons.star_rounded, size: 13, color: mm.orange),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
