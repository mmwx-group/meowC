import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/ggy.dart';
import '../../state/ggy_reporter.dart';
import '../../state/meow_settings.dart';
import '../../theme/page_title.dart';
import '../me/me_kit.dart';

/// GGY 加白的 token 列表：本机偏好、退出登录不清。列表里 token 只显示脱敏写法与上一次结果，
/// 完整 token 只在添加时的输入框里出现（可以直接粘贴整条分享链接）。
/// 增删后由 MeowRoot 的 GGY 监听统一处理：开关开着时新增的立刻上报一次。
class GgyTokensPage extends ConsumerWidget {
  const GgyTokensPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = ref.watch(meowSettingProvider.select((s) => s.ggyTokens));
    final enabled = ref.watch(meowSettingProvider.select((s) => s.ggyEnabled));
    final results = ref.watch(ggyResultsProvider);
    // 关着时没有结论（关掉即清），每行都是「还没报过」
    final invalid = tokens.any((t) => results[t]?.kind == GgyResultKind.tokenInvalid);
    return MeSubPage.list(
      title: 'GGY token',
      actions: [
        RoundGlassButton(icon: Icons.add_rounded, filled: true, tooltip: '添加', onTap: () => _add(context, ref)),
      ],
      children: [
        MeItemsCard(
          items: [for (final t in tokens) maskGgyToken(t)],
          subtitles: [for (final t in tokens) results[t]?.summary ?? '还没报过'],
          empty: '添加 GGY 白名单分享链接里的 token，本机出口 IP 会上报给它加白。点右上角「+」添加',
          onDelete: (i) => ref
              .read(meowSettingProvider.notifier)
              .updateState((s) => s.copyWith(ggyTokens: [...s.ggyTokens]..removeAt(i))),
        ),
        if (invalid) const MeCaption('标着「token 无效或已失效」的分享链接已失效：到 GGY 重新生成分享链接，删掉旧的再添加新的 token。'),
        MeCaption(enabled ? '每 10 分钟及网络变化时上报本机出口 IP，上报走直连；没登录也会上报。' : '「GGY 加白」开关未打开，打开后才会上报这里的 token。'),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final token = TextEditingController();
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
          scrollable: true,
          title: const Text('添加 GGY token'),
          content: TextField(
            controller: token,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(
              labelText: 'Token',
              hintText: 'ctecsfw_…',
              helperText: '分享链接里 token= 后面那段，也可以直接粘贴整条链接',
              helperMaxLines: 2,
              errorText: err,
              errorMaxLines: 3,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final (t, e) = checkNewGgyToken(ref.read(meowSettingProvider).ggyTokens, token.text);
                if (e != null) {
                  setState(() => err = e);
                  return;
                }
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(ggyTokens: [...s.ggyTokens, t!]));
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
