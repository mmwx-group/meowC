import 'package:bett_box/common/common.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/account.dart';
import '../../panel/avatar_cache.dart';
import '../../panel/client.dart';
import '../../state/meow_settings.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../scan/scan_page.dart';

/// 账户头像（网络图）的解码宽度上限，见 [AccountCard] 里的用处。
const _avatarCacheWidth = 720;

/// 账户卡（M3 主色容器，画布稿 Me）：圆角方块头像 + 昵称 + 同步状态，同一行末尾一颗「退出登录」；
/// 未登录时下面是「扫码登录」/「账号登录」和说明。
/// [compact] = 宽屏第 1 列里的小一号。
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key, required this.onError, this.compact = false});

  final void Function(Object) onError;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final fg = cs.onPrimaryContainer;
    final account = ref.watch(meowSettingProvider.select((s) => s.account));
    final loggedIn = account.token.isNotEmpty;
    // 登录已过期：留着昵称头像，说明换成「登录已过期，请重新登录」，下面照常给登录按钮
    final expired = ref.watch(isSessionExpiredProvider);
    // 主控上传的头像存的是站内路径，接上主控地址才加载得出来
    final avatarUrl = absoluteAvatarUrl(account.avatarUrl, account.host);
    final avatarSize = compact ? 52.0 : 64.0;
    // 没有头像时：透明底的手绘猫娘头（浅色黑发、深色银发），不裁形、没有底（2026-11-17 用户要求去掉头像后面的背景；
    // 以前是整张 App 图标裁成饼干形，图标自带的深底露成一块）
    final fallback = Image.asset(
      Theme.of(context).brightness == Brightness.dark
          ? 'assets/images/brand_head_dark_256.png'
          : 'assets/images/brand_head_light_256.png',
      width: avatarSize,
      height: avatarSize,
    );
    final dark = context.isDarkMode;
    final cardBg = dark ? Color.alphaBlend(cs.primary.withValues(alpha: 0.10), cs.card) : cs.primaryContainer;
    return M3Card(
      radius: compact ? MeowShape.xl : MeowShape.xlInc,
      color: cardBg,
      padding: EdgeInsets.all(compact ? 14 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 主控上的头像剪成圆角方块（同 iOS：圆角 = 边长的 1/3）；没有头像时的猫娘头本身透明，不裁。
              // 以前剪成九瓣饼干形，头像自带的深底露成一朵花（2026-11-18 用户要求删掉）
              avatarUrl.isEmpty
                  ? fallback
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(avatarSize / 3),
                      child: _CachedAvatar(url: avatarUrl, size: avatarSize, fallback: fallback),
                    ),
              SizedBox(width: compact ? 12 : 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loggedIn || expired ? account.nickname : '未登录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: compact ? 19 : 22, fontWeight: FontWeight.w900, color: fg),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (loggedIn || expired) ...[
                          StatusDot(color: expired ? cs.error : context.m3.ok, size: 7),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            // 不带主控域名（同 iOS）
                            loggedIn
                                ? '实时同步已启用'
                                : expired
                                ? '登录已过期，请重新登录'
                                : '登录以启用实时同步与账户功能',
                            maxLines: loggedIn ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact ? MeowFont.caption : MeowFont.footnote,
                              color: expired ? cs.error : fg.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 退出登录跟在昵称后面（2026-11-17 用户反馈：放在下面一行时右边空一大块）
              if (loggedIn) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: compact ? 34 : 38,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: fg,
                      side: BorderSide(color: fg.withValues(alpha: 0.6)),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      try {
                        await ref.read(accountActionsProvider).logout();
                      } catch (e) {
                        onError(e);
                      }
                    },
                    child: const Text('退出登录', maxLines: 1, softWrap: false),
                  ),
                ),
              ],
            ],
          ),
          if (!loggedIn) ...[
            const SizedBox(height: 14),
            // 双按钮各占半宽：1.4 倍字时「内边距 32 + 图标 18 + 间距 6.4 + 四字 78.8」≈ 135，
            // 屏宽 < ~338dp 就折成「扫码登/录」；label 在按钮内部已是 Flexible，FittedBox 只缩不放
            Row(
              children: [
                if (system.isAndroid) ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => scanLoginOrSubscription(context, ref, onError: onError),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                      label: const FittedBox(fit: BoxFit.scaleDown, child: Text('扫码登录', maxLines: 1, softWrap: false)),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton.icon(
                    // 有扫码时账号登录是次要钮：卡片底配墨色字
                    style: system.isAndroid
                        ? FilledButton.styleFrom(
                            backgroundColor: cs.surfaceContainerLowest.withValues(alpha: 0.72),
                            foregroundColor: cs.onSurface,
                          )
                        : null,
                    onPressed: () => showLoginSheet(context, ref, onError: onError),
                    icon: const Icon(Icons.person_rounded, size: 18),
                    label: const FittedBox(fit: BoxFit.scaleDown, child: Text('账号登录', maxLines: 1, softWrap: false)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              system.isAndroid
                  ? '在桌面端「个人菜单 → 扫码登录手机」出示二维码，用手机扫一扫即可登录'
                  // Windows / Linux 没有扫码：网页「扫码登录手机」对话框里的「登录客户端」按钮用 miaomiaowu:// 深链唤起本 App 完成登录。
                  // 菜单名要和网页 user-menu.tsx 的一字不差（#970）
                  : '在网页端「个人菜单 → 扫码登录手机」里点「登录客户端」，MeowX 会自动打开并完成登录',
              style: TextStyle(fontSize: MeowFont.caption, color: fg.withValues(alpha: 0.8)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 主控上的头像：经 [AvatarCache] 走本地缓存（下过一次之后从磁盘读，不再每次请求主控）；没拿到时显示 [fallback]。
class _CachedAvatar extends StatefulWidget {
  const _CachedAvatar({required this.url, required this.size, required this.fallback});
  final String url;
  final double size;
  final Widget fallback;

  @override
  State<_CachedAvatar> createState() => _CachedAvatarState();
}

class _CachedAvatarState extends State<_CachedAvatar> {
  late Future<Uint8List?> _bytes = AvatarCache.shared.load(widget.url);

  @override
  void didUpdateWidget(_CachedAvatar old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _bytes = AvatarCache.shared.load(widget.url);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    initialData: AvatarCache.shared.peek(widget.url),
    builder: (_, snap) {
      final bytes = snap.data;
      if (bytes == null) return widget.fallback;
      return Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // 主控给多大的图就解多大，碰上几千像素的头像要占十几 MB：解码宽度封顶（比这小的图原样解）。
        // 只限宽度——两个方向都限会把非正方形的头像压变形；取 60dp × 3 倍屏 × 4：引擎缩图用的是不带 mipmap 的双线性，
        // 一步缩太多会出锯齿，剩下的几倍交给绘制时的 mipmap。
        cacheWidth: _avatarCacheWidth,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    },
  );
}

/// 扫一扫：MeowX 登录码 → 登录；订阅链接 → 导入。
Future<void> scanLoginOrSubscription(
  BuildContext context,
  WidgetRef ref, {
  required void Function(Object) onError,
}) async {
  final code = await BaseNavigator.push<String>(context, const MeowScanPage());
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
Future<void> showLoginSheet(BuildContext context, WidgetRef ref, {required void Function(Object) onError}) async {
  final account = ref.read(meowSettingProvider).account;
  final host = TextEditingController(text: account.host);
  final user = TextEditingController();
  final pass = TextEditingController();
  final code = TextEditingController();
  String? twoFactorToken;
  bool busy = false;
  await showMeowDialog<void>(
    context,
    title: '登录妙妙屋X',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final mm = ctx.mm;
        Future<void> submit() async {
          setState(() => busy = true);
          try {
            final actions = ref.read(accountActionsProvider);
            final r = twoFactorToken == null
                ? await actions.login(host: host.text, username: user.text.trim(), password: pass.text)
                : await actions.complete2fa(twoFactorToken: twoFactorToken!, code: code.text.trim());
            if (r is LoginNeeds2FA) {
              setState(() => twoFactorToken = r.twoFactorToken);
              return;
            }
            await actions.afterLogin();
            if (ctx.mounted) Navigator.of(ctx).pop();
          } catch (e) {
            onError(e);
            if (ctx.mounted) Navigator.of(ctx).pop();
          } finally {
            if (ctx.mounted) setState(() => busy = false);
          }
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (twoFactorToken != null) ...[
                Text(
                  '二步验证',
                  style: TextStyle(fontSize: MeowFont.headline, fontWeight: FontWeight.w700, color: mm.t1),
                ),
                const SizedBox(height: 8),
              ],
              if (twoFactorToken == null) ...[
                TextField(
                  controller: host,
                  decoration: const InputDecoration(labelText: '主控地址', hintText: 'https://panel.example.com'),
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
                child: FilledButton(onPressed: busy ? null : submit, child: Text(busy ? '登录中…' : '登录')),
              ),
            ],
          ),
        );
      },
    ),
  );
}
