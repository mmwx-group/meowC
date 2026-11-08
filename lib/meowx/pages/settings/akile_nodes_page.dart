import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/account.dart';
import '../../panel/akile.dart';
import '../../state/akile_reporter.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../me/me_kit.dart';

/// 当前订阅里可以拿来加白的节点（应用配置时记下的 type / server / port，见 [akileCandidates]）。测试里换掉它。
final akileCandidatesProvider = Provider<List<AkileCandidate>>(
  (ref) => akileCandidates(ref.watch(localNodeKeysProvider)),
);

/// 「AkileCDN 节点」：API Key + 要加白的节点（本机偏好、退出登录不清）。Key 只显示脱敏写法，完整 Key 只在密码样式的
/// 输入框里。增删 / 换 Key 后由 MeowRoot 的 AkileCDN 监听统一处理：开关开着时新加的节点立刻报一次、换 Key 全部报一次。
/// 结论在内存里（[akileResultsProvider]），上报的地方一更新这里就跟着变，不用轮询。
class AkileNodesPage extends ConsumerWidget {
  const AkileNodesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final key = ref.watch(meowSettingProvider.select((s) => s.akileKey));
    final enabled = ref.watch(meowSettingProvider.select((s) => s.akileEnabled));
    final nodes = ref.watch(meowSettingProvider.select((s) => s.akileNodes));
    final results = ref.watch(akileResultsProvider);
    final hasKey = isValidAkileKey(key);
    final full = nodes.length >= akileMaxNodes;
    final addHint = !hasKey ? akileNeedKeyMessage : (full ? akileNodesFullMessage : null);
    return MeSubPage.list(
      title: akileNodesTitle,
      children: [
        MeSection(
          title: 'API Key',
          children: [
            if (hasKey)
              MeRow(
                label: maskAkileKey(key),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(onPressed: () => _changeKey(context, ref), child: const Text('更换')),
                    TextButton(
                      onPressed: () => _deleteKey(context, ref),
                      style: TextButton.styleFrom(foregroundColor: mm.slow),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              )
            else
              const _KeyInput(),
          ],
        ),
        MeSection(
          title: '节点',
          children: [
            if (nodes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Text(
                  '还没有节点',
                  style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2),
                ),
              ),
            for (final (i, n) in nodes.indexed)
              _NodeRow(
                node: n,
                result: results[n.ruleId],
                onDelete: () => ref
                    .read(meowSettingProvider.notifier)
                    .updateState((s) => s.copyWith(akileNodes: [...s.akileNodes]..removeAt(i))),
              ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: addHint == null ? () => mePush(context, const AkileNodePickerPage()) : null,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text(akileAddButton),
            ),
            if (addHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  addHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
                ),
              ),
          ],
        ),
        MeCaption(enabled ? akileDescription : akileDisabledHint),
      ],
    );
  }

  Future<void> _changeKey(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
          scrollable: true,
          title: const Text('更换 API Key'),
          content: _keyField(controller, err),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final (k, e) = parseAkileKey(controller.text);
                if (e != null) {
                  setState(() => err = e);
                  return;
                }
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(akileKey: k!));
                Navigator.of(ctx).pop();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteKey(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 API Key'),
        content: const Text('删除后不再更新白名单；节点留着，填回 Key 后接着更新。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(akileKey: ''));
  }
}

/// Key 的密码样式输入框（没有 Key 时放在卡片里，「更换」时放在对话框里）。
Widget _keyField(TextEditingController controller, String? error, {ValueChanged<String>? onSubmitted}) => TextField(
  controller: controller,
  autofocus: onSubmitted == null,
  obscureText: true,
  autocorrect: false,
  enableSuggestions: false,
  keyboardType: TextInputType.visiblePassword,
  onSubmitted: onSubmitted,
  decoration: InputDecoration(
    labelText: 'API Key',
    hintText: 'ak_…',
    helperText: akileKeyHint,
    helperMaxLines: 3,
    errorText: error,
    errorMaxLines: 3,
  ),
);

/// 没有 Key 时：密码输入框 + 保存。
class _KeyInput extends ConsumerStatefulWidget {
  const _KeyInput();

  @override
  ConsumerState<_KeyInput> createState() => _KeyInputState();
}

class _KeyInputState extends ConsumerState<_KeyInput> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final (k, e) = parseAkileKey(_controller.text);
    if (e != null) {
      setState(() => _error = e);
      return;
    }
    ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(akileKey: k!));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 4, 12, 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _keyField(_controller, _error, onSubmitted: (_) => _save())),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: FilledButton(onPressed: _save, child: const Text('保存')),
        ),
      ],
    ),
  );
}

/// 一个节点：节点名 / `规则 #<id>[ · <label>] · 端口 <port>` / 上一次结果（成功绿、失败红、没报过灰）+ 删除。
class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.node, required this.result, required this.onDelete});

  final MeowAkileNode node;
  final AkileResult? result;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final r = result;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 2, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.name.isEmpty ? '规则 #${node.ruleId}' : node.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w500, color: mm.t1),
                ),
                Text(
                  akileNodeDetail(node),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
                ),
                Text(
                  r?.summary ?? akileNeverReported,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: MeowFont.caption, color: r == null ? mm.t2 : (r.ok ? mm.good : mm.slow)),
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
    );
  }
}

/// 「从订阅添加节点」：列出当前订阅里的节点（节点名 + server:port，可搜索），点一个就用它的端口查规则——
/// 一条直接加入，多条弹出选择，没有 / 出错弹提示。加好了回到节点页。
class AkileNodePickerPage extends ConsumerStatefulWidget {
  const AkileNodePickerPage({super.key});

  @override
  ConsumerState<AkileNodePickerPage> createState() => _AkileNodePickerPageState();
}

class _AkileNodePickerPageState extends ConsumerState<AkileNodePickerPage> {
  final _search = TextEditingController();

  /// 正在查规则的节点（查的时候别的不能点）
  AkileCandidate? _busy;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _message(String text) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      content: Text(text),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('好'))],
    ),
  );

  void _back() {
    final sheet = MeSheetScope.maybeOf(context);
    if (sheet != null) {
      sheet.navigator.back();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _pick(AkileCandidate c) async {
    final key = ref.read(meowSettingProvider).akileKey;
    if (!isValidAkileKey(key)) return _message(akileNeedKeyMessage);
    if (ref.read(meowSettingProvider).akileNodes.length >= akileMaxNodes) return _message(akileNodesFullMessage);
    setState(() => _busy = c);
    final lookup = await ref.read(akileRulesLookupProvider)(key, c.port);
    if (!mounted) return;
    setState(() => _busy = null);
    if (lookup.error != null) return _message(lookup.error!);
    final AkileRule? rule;
    if (lookup.rules.isEmpty) {
      return _message(akileNoRulesMessage(c.port));
    } else if (lookup.rules.length == 1) {
      rule = lookup.rules.single;
    } else {
      rule = await showDialog<AkileRule>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text(akilePickRuleTitle),
          children: [
            for (final r in lookup.rules)
              SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(r), child: Text(r.line)),
          ],
        ),
      );
      if (rule == null || !mounted) return;
    }
    final err = checkNewAkileNode(ref.read(meowSettingProvider).akileNodes, rule.id);
    if (err != null) return _message(err);
    final node = MeowAkileNode(name: c.name, port: c.port, ruleId: rule.id, label: rule.summary);
    ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(akileNodes: [...s.akileNodes, node]));
    _back();
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final all = ref.watch(akileCandidatesProvider);
    final shown = filterAkileCandidates(all, _search.text);
    return MeSubPage.list(
      title: akileAddButton,
      children: [
        if (all.isNotEmpty)
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索节点名 / 地址',
              prefixIcon: Icon(Icons.search_rounded, size: 20, color: mm.t2),
              filled: true,
              fillColor: mm.elev,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
            ),
          ),
        MeSection(
          children: [
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Text(
                  all.isEmpty ? akileNoCandidatesMessage : '没有匹配的节点',
                  style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2),
                ),
              ),
            for (final c in shown)
              MeRow(
                label: c.name,
                subtitle: c.address,
                trailing: _busy == c
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onTap: _busy == null ? () => _pick(c) : null,
              ),
          ],
        ),
        const MeCaption('用节点的端口查 AkileCDN 里监听这个端口的规则；查到一条直接加入，多条时选一条。'),
      ],
    );
  }
}
