import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/po0.dart';
import '../../panel/whitelist_common.dart';
import '../../state/meow_settings.dart';
import '../../state/po0_reporter.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../me/me_kit.dart';
import 'whitelist_widgets.dart';

/// 自定义 po0 服务器：用户自己添加的加白目标（地址 + token + 可选备注），本机偏好、退出登录不清。
/// 列表里 token 只显示脱敏写法，完整 token 只在添加时的输入框里出现。点一行改备注（改备注不触发上报）。
/// 开关开着、拉到主控列表时，上面另列主控登记的服务器（只读，显示主控给的名字）。每台都带上一次加白的结果，
/// 行尾的盾牌钮点开槽位气泡（规格：MeowX 仓库 Design/po0-ggy-results.md）。
/// 增删后由 MeowRoot 的 po0 监听统一处理：开关开着就立刻重算列表、上报一次、更新直连规则。
class Po0ServersPage extends ConsumerWidget {
  const Po0ServersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(meowSettingProvider.select((s) => s.po0Custom));
    final enabled = ref.watch(meowSettingProvider.select((s) => s.po0Enabled));
    final panel = ref.watch(po0PanelServersProvider);
    final results = ref.watch(po0ResultsProvider);
    final mm = context.mm;
    final conflict = results.values.any((r) => r.kind == Po0ResultKind.slotConflict);
    return MeSubPage.list(
      title: '自定义 po0 服务器',
      actions: [
        RoundGlassButton(icon: Icons.add_rounded, filled: true, tooltip: '添加', onTap: () => _add(context, ref)),
      ],
      children: [
        WhitelistClock(
          builder: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (panel.isNotEmpty) ...[
                MeSection(
                  title: '主控登记的服务器',
                  children: [
                    for (final s in panel)
                      WhitelistItemRow(
                        title: s.name.isEmpty ? po0UrlLabel(s.url) : s.name,
                        monoTitle: s.name.isEmpty,
                        subtitle: s.name.isEmpty ? null : po0UrlLabel(s.url),
                        result: po0ResultLine(results[s.url]),
                        tone: po0Tone(results[s.url]),
                        actions: [Po0SlotButton(url: s.url, title: s.name.isEmpty ? po0UrlLabel(s.url) : s.name)],
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              MeSection(
                title: panel.isEmpty ? null : '自己添加的',
                children: [
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                      child: Text(
                        '添加 po0 的加白服务器地址与 token，本机出口 IP 会上报给它加白。点右上角「+」添加',
                        style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
                      ),
                    ),
                  for (final (i, c) in list.indexed) _customRow(context, ref, i, c, results),
                ],
              ),
            ],
          ),
        ),
        if (conflict) const MeCaption('槽位冲突：本机 IP 已经钉在这台 po0 的另一个槽位上，先到 po0 面板删除旧槽位再等下一次上报。'),
        MeCaption(
          enabled
              ? '与主控登记的服务器一起，每 10 分钟及网络变化时上报本机出口 IP；没登录也会上报这里的服务器。点一行可以改备注，盾牌按钮查看这台 po0 的白名单槽位。'
              : '「po0 加白」开关未打开，打开后才会上报这里的服务器。',
        ),
      ],
    );
  }

  Widget _customRow(BuildContext context, WidgetRef ref, int i, Po0CustomServer c, Map<String, Po0Result> results) {
    final (title, subtitle) = po0CustomLabels(c);
    final url = po0CustomTarget(c)?.url;
    final r = url == null ? null : results[url];
    return WhitelistItemRow(
      title: title,
      monoTitle: c.note.trim().isEmpty,
      subtitle: subtitle,
      result: po0ResultLine(r),
      tone: po0Tone(r),
      onTap: () => _editNote(context, ref, i, c),
      actions: [
        if (url != null) Po0SlotButton(url: url, title: title),
        IconButton(
          tooltip: '删除',
          icon: Icon(Icons.close_rounded, size: 18, color: context.mm.t2),
          onPressed: () => ref
              .read(meowSettingProvider.notifier)
              .updateState((s) => s.copyWith(po0Custom: [...s.po0Custom]..removeAt(i))),
        ),
      ],
    );
  }

  /// 改备注：只换这一条的 note（按地址 + token 认回，免得对话框开着时列表变了改错条）；不触发上报。
  Future<void> _editNote(BuildContext context, WidgetRef ref, int i, Po0CustomServer c) async {
    final note = await editWhitelistNote(context, subject: '${c.address} · ${maskPo0Token(c.token)}', initial: c.note);
    if (note == null) return;
    ref
        .read(meowSettingProvider.notifier)
        .updateState(
          (s) => s.copyWith(
            po0Custom: [
              for (final x in s.po0Custom)
                if (x.address == c.address && x.token == c.token) x.copyWith(note: note) else x,
            ],
          ),
        );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final address = TextEditingController();
    final token = TextEditingController();
    final note = TextEditingController();
    String? addressErr, tokenErr;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
          scrollable: true,
          title: const Text('添加 po0 服务器'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: address,
                autofocus: true,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: '加白服务器地址',
                  hintText: '1.2.3.4 或 fw.example.com:8443',
                  helperText: 'po0 后台里的加白服务器地址，不一定是节点地址',
                  helperMaxLines: 2,
                  errorText: addressErr,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: token,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: 'Token',
                  hintText: 'pgnfw_…（可带 @槽位）',
                  errorText: tokenErr,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 8),
              whitelistNoteField(note),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final (addr, ae) = parsePo0Address(address.text);
                final t = token.text.trim();
                var te = validatePo0Token(t);
                if (ae == null && te == null) {
                  final url = po0ReportUrl(addr!, t);
                  final existing = ref.read(meowSettingProvider).po0Custom;
                  if (existing.any((c) => po0CustomTarget(c)?.url == url)) te = '这个地址与 token 已经添加过';
                }
                if (ae != null || te != null) {
                  setState(() {
                    addressErr = ae;
                    tokenErr = te;
                  });
                  return;
                }
                ref
                    .read(meowSettingProvider.notifier)
                    .updateState(
                      (s) => s.copyWith(
                        po0Custom: [
                          ...s.po0Custom,
                          Po0CustomServer(address: addr!, token: t, note: normalizeWhitelistNote(note.text)),
                        ],
                      ),
                    );
                Navigator.of(ctx).pop();
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}
