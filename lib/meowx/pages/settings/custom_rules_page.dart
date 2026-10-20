import 'package:bett_box/models/meow.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/custom_rules.dart';
import '../../state/meow_settings.dart';
import '../../state/overrides.dart';
import '../../state/status.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';

/// 当前订阅的主代理组（界面上「代理（节点选择）」用；null = 没有代理组或还不知道，只显示「代理」）。
/// 优先用应用配置时按交给内核的那份记下的（[appliedMainProxyGroup]，Bettbox 的规则覆写、停用组都算进去了）；
/// 当前订阅还没应用过才按订阅原始配置推断。
final mainProxyGroupProvider = Provider<String?>((ref) {
  void changed() => ref.invalidateSelf();
  appliedMainProxyGroup.addListener(changed);
  ref.onDispose(() => appliedMainProxyGroup.removeListener(changed));
  final applied = appliedMainProxyGroup.value;
  if (applied != null && applied.$1 == ref.watch(currentProfileIdProvider)) return applied.$2;
  final raw = ref.watch(currentRawConfigProvider);
  if (raw.isEmpty) return null;
  return resolveMainProxyGroup(raw['proxy-groups'], raw['rules'] ?? raw['rule']);
});

/// 改自定义规则：写进 MeowX 设置，连着就重新套用配置（规则在 patchRawConfig 里经前置规则插进去）。
void updateCustomRules(WidgetRef ref, List<MeowCustomRule> Function(List<MeowCustomRule> rules) change) {
  ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(customRules: change(s.customRules)));
  if (ref.read(isRunningProvider)) globalState.appController.applyProfileDebounce(silence: true);
}

/// 「我的 › 设置 › 自定义规则」：域名（或 IP）走直连 / 代理 / 拒绝。列表顺序即优先级，点一条编辑，× 删除。
class CustomRulesPage extends ConsumerWidget {
  const CustomRulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(meowSettingProvider.select((s) => s.customRules));
    final group = ref.watch(mainProxyGroupProvider);
    return MeSubPage.list(
      title: '自定义规则',
      actions: [
        RoundGlassButton(
          icon: Icons.add_rounded,
          filled: true,
          tooltip: '添加',
          onTap: rules.length >= overridesLimit ? null : () => showCustomRuleEditor(context, ref),
        ),
      ],
      children: [
        MeSection(
          children: [
            if (rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Text(
                  '让某个域名固定走直连、代理或拒绝。点右上角「+」添加，也可以在「动态」里点开一条连接设置',
                  style: TextStyle(fontSize: MeowFont.footnote, color: context.mm.t2),
                ),
              ),
            for (final (i, r) in rules.indexed)
              _RuleRow(
                rule: r,
                group: group,
                onTap: () => showCustomRuleEditor(context, ref, index: i),
                onDelete: () => updateCustomRules(ref, (list) => [...list]..removeAt(i)),
              ),
          ],
        ),
        MeCaption('${rules.length} / $overridesLimit · 排在订阅规则之前、从上往下匹配，只在规则模式下生效'),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.rule, required this.group, required this.onTap, required this.onDelete});
  final MeowCustomRule rule;
  final String? group;
  final VoidCallback onTap, onDelete;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 2, 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t1),
                  ),
                  Text(
                    '${rule.match.label} · ${customRuleActionLabel(rule.action, group)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.footnote, color: actionColor(mm, rule.action)),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.close_rounded, size: 18, color: mm.t2),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 动作的字色：直连绿、拒绝红、代理用强调色（同连接列表里出站的配色）。
Color actionColor(MeowTokens mm, MeowRuleAction action) => switch (action) {
  MeowRuleAction.direct => mm.good,
  MeowRuleAction.reject => mm.slow,
  MeowRuleAction.proxy => mm.accent,
};

/// 新增（[index] 为空）或编辑第 [index] 条。域名输入可以是整条链接，保存时规范化；输入的是 IP 时匹配方式固定为 IP。
Future<void> showCustomRuleEditor(BuildContext context, WidgetRef ref, {int? index}) async {
  final existing = index == null ? null : ref.read(meowSettingProvider).customRules[index];
  final group = ref.read(mainProxyGroupProvider);
  final input = TextEditingController(text: existing?.value ?? '');
  var match = existing?.match == MeowRuleMatch.domain ? MeowRuleMatch.domain : MeowRuleMatch.suffix;
  var action = existing?.action ?? MeowRuleAction.direct;
  String? err;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final mm = ctx.mm;
        final isIp = normalizeCustomRuleHost(input.text)?.ip ?? false;
        return AlertDialog(
          // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
          scrollable: true,
          title: Text(existing == null ? '添加规则' : '编辑规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: input,
                autofocus: existing == null,
                autocorrect: false,
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() => err = null),
                decoration: InputDecoration(
                  labelText: '域名或 IP',
                  hintText: 'example.com、https://www.example.com/a',
                  hintMaxLines: 2,
                  errorText: err,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 14),
              Text('匹配', style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
              const SizedBox(height: 6),
              if (isIp)
                Text('IP（只匹配这一个地址）', style: TextStyle(fontSize: MeowFont.footnote, color: mm.t1))
              else
                MeowSegment<MeowRuleMatch>(
                  height: 38,
                  fontSize: 13,
                  onCard: true,
                  items: [for (final m in const [MeowRuleMatch.domain, MeowRuleMatch.suffix]) (m, m.label)],
                  value: match,
                  onChanged: (v) => setState(() => match = v),
                ),
              const SizedBox(height: 14),
              Text('动作', style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
              const SizedBox(height: 6),
              MeowSegment<MeowRuleAction>(
                height: 38,
                fontSize: 13,
                onCard: true,
                items: [for (final a in MeowRuleAction.values) (a, a.label)],
                value: action,
                onChanged: (v) => setState(() => action = v),
              ),
              const SizedBox(height: 6),
              Text(
                group == null ? '订阅里没有代理组：「代理」规则不生效，按订阅规则走' : '代理 = 走「$group」',
                style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final h = normalizeCustomRuleHost(input.text);
                if (h == null) {
                  setState(() => err = customRuleHostInvalidMessage);
                  return;
                }
                final rule = MeowCustomRule(
                  value: h.value,
                  match: h.ip ? MeowRuleMatch.ip : (h.suffixHint ? MeowRuleMatch.suffix : match),
                  action: action,
                );
                updateCustomRules(ref, (list) => index == null ? upsertCustomRule(list, rule) : replaceCustomRule(list, index, rule));
                Navigator.of(ctx).pop();
              },
              child: Text(existing == null ? '添加' : '保存'),
            ),
          ],
        );
      },
    ),
  );
}
