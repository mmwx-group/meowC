import 'package:bett_box/common/common.dart';
import 'package:bett_box/pages/pages.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/account.dart';
import '../../panel/client.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import 'me_kit.dart';

/// 账户卡（樱粉主卡）：头像 + 昵称 + 同步状态 +「退出」；未登录时下面是「扫码登录」/「账号登录」和说明。
/// [compact] = 宽屏第 1 列里的小一号。
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key, required this.onError, this.compact = false});

  final void Function(Object) onError;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final account = ref.watch(meowSettingProvider.select((s) => s.account));
    final loggedIn = account.token.isNotEmpty;
    final avatarSize = compact ? 52.0 : 60.0;
    final fallback = BrandHead(size: avatarSize);
    return Container(
      decoration: BoxDecoration(color: mm.hero, borderRadius: BorderRadius.circular(compact ? 22 : 28)),
      padding: EdgeInsets.all(compact ? 12 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (account.avatarUrl.isEmpty)
                fallback
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(avatarSize * 0.31),
                  child: Image.network(
                    account.avatarUrl,
                    width: avatarSize,
                    height: avatarSize,
                    fit: BoxFit.cover,
                    // 主控给多大的图就解多大，碰上几千像素的头像要占十几 MB：解码宽度封顶在显示宽度的 4 倍（比这小的图原样解）。
                    // 只限宽度——两个方向都限会把非正方形的头像压变形；留 4 倍是因为引擎缩图用的是不带 mipmap 的双线性，
                    // 一步缩太多会出锯齿，剩下的几倍交给绘制时的 mipmap
                    cacheWidth: (avatarSize * MediaQuery.devicePixelRatioOf(context) * 4).ceil(),
                    errorBuilder: (_, _, _) => fallback,
                  ),
                ),
              SizedBox(width: compact ? 10 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loggedIn ? account.nickname : '未登录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 18 : MeowFont.title3,
                        fontWeight: FontWeight.w700,
                        fontFamilyFallback: meowRounded,
                        color: mm.t1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (loggedIn) ...[StatusDot(color: mm.good, size: 7), const SizedBox(width: 5)],
                        Expanded(
                          child: Text(
                            loggedIn ? '实时同步已启用 · ${Uri.parse(account.host).host}' : '登录以启用实时同步与账户功能',
                            maxLines: loggedIn ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: compact ? MeowFont.caption2 : MeowFont.caption, color: mm.t2),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (loggedIn) ...[
                const SizedBox(width: 8),
                MePill(
                  label: '退出',
                  height: compact ? 36 : 44,
                  onTap: () async {
                    try {
                      await ref.read(accountActionsProvider).logout();
                    } catch (e) {
                      onError(e);
                    }
                  },
                ),
              ],
            ],
          ),
          if (!loggedIn) ...[
            const SizedBox(height: 12),
            // 双按钮各占半宽：1.4 倍字时「内边距 32 + 图标 18 + 间距 6.4 + 四字 78.8」≈ 135，
            // 屏宽 < ~338dp 就折成「扫码登/录」；label 在按钮内部已是 Flexible，FittedBox 只缩不放
            Row(
              children: [
                if (system.isAndroid) ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => scanLoginOrSubscription(context, ref, onError: onError),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('扫码登录', maxLines: 1, softWrap: false),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton.icon(
                    // 有扫码时账号登录是次要钮：卡片底配墨色字
                    style: system.isAndroid
                        ? FilledButton.styleFrom(backgroundColor: mm.elev, foregroundColor: mm.t1)
                        : null,
                    onPressed: () => showLoginSheet(context, ref, onError: onError),
                    icon: const Icon(Icons.person_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('账号登录', maxLines: 1, softWrap: false),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              system.isAndroid
                  ? '在桌面端「个人菜单 → 扫码登录手机」出示二维码，用手机扫一扫即可登录'
                  // Windows 没有扫码：网页「扫码登录手机」对话框里的「登录客户端」按钮用 miaomiaowu:// 深链唤起本 App 完成登录。
                  // 菜单名要和网页 user-menu.tsx 的一字不差（#970）
                  : '在网页端「个人菜单 → 扫码登录手机」里点「登录客户端」，MeowX 会自动打开并完成登录',
              style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2),
            ),
          ],
        ],
      ),
    );
  }
}

/// 扫一扫：MeowX 登录码 → 登录；订阅链接 → 导入。
Future<void> scanLoginOrSubscription(
  BuildContext context,
  WidgetRef ref, {
  required void Function(Object) onError,
}) async {
  final code = await BaseNavigator.push<String>(context, const ScanPage());
  if (code == null || code.isEmpty) return;
  final link = Uri.tryParse(code) == null ? null : parseLoginLink(Uri.parse(code));
  try {
    if (link != null) {
      await ref.read(accountActionsProvider).loginWithCode(host: link.base, code: link.code);
    } else if (code.startsWith('http')) {
      await globalState.appController.addProfileFormURL(code);
    } else {
      throw const PanelException('二维码不是 MeowX 登录码或订阅链接');
    }
  } catch (e) {
    onError(e);
  }
}

/// 账号密码登录（含二步验证）。
Future<void> showLoginSheet(
  BuildContext context,
  WidgetRef ref, {
  required void Function(Object) onError,
}) async {
  final account = ref.read(meowSettingProvider).account;
  final host = TextEditingController(text: account.host);
  final user = TextEditingController();
  final pass = TextEditingController();
  final code = TextEditingController();
  String? twoFactorToken;
  bool busy = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final mm = ctx.mm;
        Future<void> submit() async {
          setState(() => busy = true);
          try {
            final actions = ref.read(accountActionsProvider);
            final r = twoFactorToken == null
                ? await actions.login(
                    host: host.text,
                    username: user.text.trim(),
                    password: pass.text,
                  )
                : await actions.complete2fa(
                    twoFactorToken: twoFactorToken!,
                    code: code.text.trim(),
                  );
            if (r is LoginNeeds2FA) {
              setState(() => twoFactorToken = r.twoFactorToken);
              return;
            }
            await actions.refreshSubscriptions();
            if (ctx.mounted) Navigator.of(ctx).pop();
          } catch (e) {
            onError(e);
            if (ctx.mounted) Navigator.of(ctx).pop();
          } finally {
            if (ctx.mounted) setState(() => busy = false);
          }
        }

        // 键盘高度留在外层：横屏 + 键盘时剩余高度放不下整张表单，内层滚动才能滑到密码框和登录钮
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            // edge-to-edge 下导航栏透明压在表单底部；键盘弹出时 paddingOf.bottom 自动归 0，不会与键盘高度重复
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              20 + MediaQuery.paddingOf(ctx).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  twoFactorToken == null ? '登录妙妙屋X' : '二步验证',
                  style: TextStyle(
                    fontSize: MeowFont.title3,
                    fontWeight: FontWeight.w600,
                    color: mm.t1,
                  ),
                ),
                const SizedBox(height: 12),
                if (twoFactorToken == null) ...[
                  TextField(
                    controller: host,
                    decoration: const InputDecoration(
                      labelText: '主控地址',
                      hintText: 'https://panel.example.com',
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: user,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: pass,
                    decoration: const InputDecoration(labelText: '密码'),
                    obscureText: true,
                    onSubmitted: (_) => submit(),
                  ),
                ] else
                  TextField(
                    controller: code,
                    decoration: const InputDecoration(labelText: '验证码 / 恢复码'),
                    autofocus: true,
                    onSubmitted: (_) => submit(),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy ? '登录中…' : '登录'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
