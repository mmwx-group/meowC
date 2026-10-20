import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/custom_rules.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../settings/custom_rules_page.dart';

/// 连接详情里的「这个域名走：直连 / 代理 / 拒绝」：一点就加一条自定义规则（同「我的 › 设置 › 自定义规则」）。
/// 有域名时可选「仅此域名 / 含子域名」（默认含子域名）；连接只有 IP 时按这个 IP 加（IP-CIDR /32、/128）。
/// 已有规则命中这条连接时显示出来，可删除。
class ConnRuleCard extends ConsumerStatefulWidget {
  const ConnRuleCard({super.key, required this.host, required this.ip});

  /// 连接的域名（没有就是空）与目标 IP
  final String host, ip;

  @override
  ConsumerState<ConnRuleCard> createState() => _ConnRuleCardState();
}

class _ConnRuleCardState extends ConsumerState<ConnRuleCard> {
  /// 规范化后的目标：有域名用域名，否则用 IP；都不合法 = null（不显示这张卡）
  CustomRuleHost? get _target =>
      normalizeCustomRuleHost(widget.host) ?? (widget.ip.isEmpty ? null : normalizeCustomRuleHost(widget.ip));

  late var _match = _initialMatch();

  /// 已有「仅此域名」的规则就停在那一档，否则默认含子域名
  MeowRuleMatch _initialMatch() {
    final t = _target;
    final rules = ref.read(meowSettingProvider).customRules;
    final exactDomain = t != null && rules.any((r) => r.value == t.value && r.match == MeowRuleMatch.domain);
    return exactDomain ? MeowRuleMatch.domain : MeowRuleMatch.suffix;
  }

  @override
  Widget build(BuildContext context) {
    final t = _target;
    if (t == null) return const SizedBox.shrink();
    final mm = context.mm;
    final rules = ref.watch(meowSettingProvider.select((s) => s.customRules));
    final group = ref.watch(mainProxyGroupProvider);
    final match = t.ip ? MeowRuleMatch.ip : _match;
    final exact = rules.where((r) => r.value == t.value && r.match == match).firstOrNull;
    final current = t.ip ? customRuleFor(rules, host: '', ip: t.value) : customRuleFor(rules, host: t.value, ip: widget.ip);

    void apply(MeowRuleAction action) =>
        updateCustomRules(ref, (list) => upsertCustomRule(list, MeowCustomRule(value: t.value, match: match, action: action)));

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.ip ? '这个 IP 走' : '这个域名走', style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
          const SizedBox(height: 2),
          Text(
            t.value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: MeowFont.mono(size: MeowFont.footnote, weight: FontWeight.w600, color: mm.t1),
          ),
          if (!t.ip) ...[
            const SizedBox(height: 8),
            MeowSegment<MeowRuleMatch>(
              height: 32,
              fontSize: 12,
              onCard: true,
              items: [for (final m in const [MeowRuleMatch.domain, MeowRuleMatch.suffix]) (m, m.label)],
              value: _match,
              onChanged: (v) => setState(() => _match = v),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              for (final (i, a) in const [MeowRuleAction.direct, MeowRuleAction.proxy, MeowRuleAction.reject].indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: _ActionButton(
                    label: customRuleActionLabel(a, group),
                    color: actionColor(mm, a),
                    selected: exact?.action == a,
                    onTap: () => apply(a),
                  ),
                ),
              ],
            ],
          ),
          if (current != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '当前规则：${current.match == MeowRuleMatch.ip ? '' : '${current.match.label} '}${current.value} → '
                    '${customRuleActionLabel(current.action, group)}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
                  ),
                ),
                IconButton(
                  tooltip: '删除规则',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline_rounded, size: 18, color: mm.slow),
                  onPressed: () => updateCustomRules(
                    ref,
                    (list) => [
                      for (final r in list)
                        if (r.value != current.value || r.match != current.match) r,
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 动作按钮：选中 = 墨色实心配页面底色的字（同分段的选中态），未选 = 次级底配动作色的字。
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.color, required this.selected, required this.onTap});
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? mm.t1 : mm.card2,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? mm.bg : color),
            ),
          ),
        ),
      ),
    );
  }
}
