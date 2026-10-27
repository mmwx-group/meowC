import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/po0.dart';
import '../../state/meow_settings.dart';
import '../../theme/page_title.dart';
import '../me/me_kit.dart';

/// 自定义 po0 服务器：用户自己添加的加白目标（地址 + token），本机偏好、退出登录不清。
/// 列表里 token 只显示脱敏写法，完整 token 只在添加时的输入框里出现。
/// 增删后由 MeowRoot 的 po0 监听统一处理：开关开着就立刻重算列表、上报一次、更新直连规则。
class Po0ServersPage extends ConsumerWidget {
  const Po0ServersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(meowSettingProvider.select((s) => s.po0Custom));
    final enabled = ref.watch(meowSettingProvider.select((s) => s.po0Enabled));
    return MeSubPage.list(
      title: '自定义 po0 服务器',
      actions: [
        RoundGlassButton(icon: Icons.add_rounded, filled: true, tooltip: '添加', onTap: () => _add(context, ref)),
      ],
      children: [
        MeItemsCard(
          items: [for (final c in list) c.address],
          subtitles: [for (final c in list) maskPo0Token(c.token)],
          empty: '添加 po0 的加白服务器地址与 token，本机出口 IP 会上报给它加白。点右上角「+」添加',
          onDelete: (i) => ref
              .read(meowSettingProvider.notifier)
              .updateState((s) => s.copyWith(po0Custom: [...s.po0Custom]..removeAt(i))),
        ),
        MeCaption(
          enabled
              ? '与主控登记的服务器一起，每 10 分钟及网络变化时上报本机出口 IP；没登录也会上报这里的服务器。'
              : '「po0 加白」开关未打开，打开后才会上报这里的服务器。',
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final address = TextEditingController();
    final token = TextEditingController();
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
                    .updateState((s) => s.copyWith(po0Custom: [...s.po0Custom, Po0CustomServer(address: addr!, token: t)]));
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
