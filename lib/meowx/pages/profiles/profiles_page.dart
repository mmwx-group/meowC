import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/pages.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../config/direct_profile.dart';
import '../../panel/account.dart';
import '../../panel/client.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/badges.dart';
import '../../theme/glass_card.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';

/// 配置页：账户卡 →（登录后）我的订阅卡 →（有当前档）用量卡 → 导入卡 → 错误条；
/// 宽屏左栏：账户 + 我的订阅 + 档案列表；右栏：用量卡 + 导入卡。
class ProfilesPage extends ConsumerStatefulWidget {
  const ProfilesPage({super.key});

  @override
  ConsumerState<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends ConsumerState<ProfilesPage> {
  String? _error;

  void _showError(Object e) =>
      setState(() => _error = e is PanelException ? e.message : e.toString());

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final wide = ref.watch(isTwoPaneProvider);
    final loggedIn = ref.watch(isLoggedInProvider);
    final current = ref.watch(currentProfileProvider);
    final errorStrip = _error == null
        ? null
        : GlassCard(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: mm.slow.withValues(alpha: 0.12),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: mm.slow),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: MeowFont.footnote,
                      color: mm.slow,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, size: 16, color: mm.slow),
                  onPressed: () => setState(() => _error = null),
                ),
              ],
            ),
          );

    final account = _AccountCard(onError: _showError);
    final subs = loggedIn ? _MySubscriptionsCard(onError: _showError) : null;
    final usage = current == null
        ? null
        : _UsageCard(profile: current, onError: _showError);
    final import_ = _ImportCard(onError: _showError);

    if (!wide) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          const PageTitle(S.profiles),
          const SizedBox(height: 12),
          account,
          if (subs != null) ...[const SizedBox(height: 12), subs],
          if (usage != null) ...[const SizedBox(height: 12), usage],
          const SizedBox(height: 12),
          import_,
          if (errorStrip != null) ...[const SizedBox(height: 12), errorStrip],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 16, top: 16),
          child: PageTitle(S.profiles),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TwoPane(
            left: ListView(
              padding: const EdgeInsets.only(right: 12, bottom: 16),
              children: [
                account,
                if (subs != null) ...[const SizedBox(height: 12), subs],
                const SizedBox(height: 12),
                const _ProfileList(),
              ],
            ),
            right: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (usage != null) ...[usage, const SizedBox(height: 12)],
                import_,
                if (errorStrip != null) ...[
                  const SizedBox(height: 12),
                  errorStrip,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 账户卡：头像 32 圆角 8 + 状态文案 + 满宽「扫码登录」/「账号登录」；已登录：昵称 /「实时同步已启用」/「退出」。
class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.onError});
  final void Function(Object) onError;

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final code = await BaseNavigator.push<String>(context, const ScanPage());
    if (code == null || code.isEmpty) return;
    final link = Uri.tryParse(code) == null
        ? null
        : parseLoginLink(Uri.parse(code));
    try {
      if (link != null) {
        await ref
            .read(accountActionsProvider)
            .loginWithCode(host: link.base, code: link.code);
      } else if (code.startsWith('http')) {
        await globalState.appController.addProfileFormURL(code);
      } else {
        throw const PanelException('二维码不是 MeowX 登录码或订阅链接');
      }
    } catch (e) {
      onError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final account = ref.watch(meowSettingProvider.select((s) => s.account));
    final loggedIn = account.token.isNotEmpty;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: account.avatarUrl.isNotEmpty
                    ? Image.network(
                        account.avatarUrl,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Image.asset(
                          'assets/images/icon_light.png',
                          width: 32,
                          height: 32,
                        ),
                      )
                    : Image.asset(
                        'assets/images/icon_light.png',
                        width: 32,
                        height: 32,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loggedIn ? account.nickname : '未登录',
                      style: TextStyle(
                        fontSize: MeowFont.headline,
                        fontWeight: FontWeight.w600,
                        color: mm.t1,
                      ),
                    ),
                    Text(
                      loggedIn
                          ? '实时同步已启用 · ${Uri.parse(account.host).host}'
                          : '登录以启用实时同步与账户功能',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: MeowFont.caption,
                        color: mm.t3,
                      ),
                    ),
                  ],
                ),
              ),
              if (loggedIn)
                TextButton(
                  onPressed: () async {
                    try {
                      await ref.read(accountActionsProvider).logout();
                    } catch (e) {
                      onError(e);
                    }
                  },
                  child: const Text('退出'),
                ),
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
                      onPressed: () => _scan(context, ref),
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
                  child: system.isAndroid
                      ? OutlinedButton.icon(
                          onPressed: () =>
                              showLoginSheet(context, ref, onError: onError),
                          icon: const Icon(Icons.person_rounded, size: 18),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('账号登录', maxLines: 1, softWrap: false),
                          ),
                        )
                      : FilledButton.icon(
                          onPressed: () =>
                              showLoginSheet(context, ref, onError: onError),
                          icon: const Icon(Icons.person_rounded, size: 18),
                          label: const Text('账号登录'),
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
              style: TextStyle(fontSize: MeowFont.caption2, color: mm.t3),
            ),
          ],
        ],
      ),
    );
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

/// 我的订阅卡：行 = 名 + 「已用 X / Y · 到期 yyyy-MM-dd」+ 下载图标；点击 = 下载并切换为当前。
class _MySubscriptionsCard extends ConsumerStatefulWidget {
  const _MySubscriptionsCard({required this.onError});
  final void Function(Object) onError;

  @override
  ConsumerState<_MySubscriptionsCard> createState() =>
      _MySubscriptionsCardState();
}

class _MySubscriptionsCardState extends ConsumerState<_MySubscriptionsCard> {
  @override
  void initState() {
    super.initState();
    final v = ref.read(remoteSubsProvider);
    if (v.hasValue && (v.value?.isEmpty ?? true)) {
      Future.microtask(
        () => ref.read(accountActionsProvider).refreshSubscriptions(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final subs = ref.watch(remoteSubsProvider);
    final importing = ref.watch(importingSubProvider);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '我的订阅',
                style: TextStyle(
                  fontSize: MeowFont.headline,
                  fontWeight: FontWeight.w600,
                  color: mm.t1,
                ),
              ),
              const Spacer(),
              RoundGlassButton(
                icon: Icons.refresh_rounded,
                busy: subs.isLoading,
                onTap: () =>
                    ref.read(accountActionsProvider).refreshSubscriptions(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          switch (subs) {
            AsyncData(:final value) when value.isEmpty => Text(
              '账户下暂无订阅（或主控未放行 /api/subscriptions）',
              style: TextStyle(fontSize: MeowFont.footnote, color: mm.t3),
            ),
            AsyncData(:final value) => Column(
              children: [
                for (final s in value)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: importing != null
                        ? null
                        : () async {
                            try {
                              await ref
                                  .read(accountActionsProvider)
                                  .importSubscription(s);
                            } catch (e) {
                              widget.onError(e);
                            }
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: MeowFont.subheadline,
                                    fontWeight: FontWeight.w500,
                                    color: mm.t1,
                                  ),
                                ),
                                Text(
                                  _subtitle(s),
                                  style: MeowFont.mono(
                                    size: MeowFont.caption2,
                                    color: mm.t3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          importing == s.name
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: mm.accent,
                                  ),
                                )
                              : Icon(
                                  Icons.download_rounded,
                                  size: 20,
                                  color: mm.accent,
                                ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            AsyncError(:final error) => Text(
              '拉取失败：$error',
              style: TextStyle(fontSize: MeowFont.footnote, color: mm.slow),
            ),
            _ => Padding(
              padding: const EdgeInsets.all(8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: mm.t3,
                  ),
                ),
              ),
            ),
          },
        ],
      ),
    );
  }

  static String _subtitle(RemoteSubscription s) {
    final parts = <String>[];
    if (s.trafficTotal != null && s.trafficTotal! > 0) {
      parts.add(
        '已用 ${fmtSize(s.trafficUsed ?? 0)} / ${fmtSize(s.trafficTotal!)}',
      );
    } else if (s.trafficUsed != null) {
      parts.add('已用 ${fmtSize(s.trafficUsed!)}');
    }
    if (s.expireAt != null) parts.add('到期 ${fmtDate(s.expireAt!.toLocal())}');
    return parts.isEmpty
        ? (s.filename.isNotEmpty ? s.filename : '—')
        : parts.join(' · ');
  }
}

/// 用量卡：名 + 「当前」徽标；「已用 / 总量」等宽；进度条 6pt；到期 + 更新于；溢出菜单；accent 描边。
class _UsageCard extends ConsumerWidget {
  const _UsageCard({required this.profile, required this.onError});
  final Profile profile;
  final void Function(Object) onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final info = profile.subscriptionInfo;
    final used = (info?.upload ?? 0) + (info?.download ?? 0);
    final total = info?.total ?? 0;
    final frac = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final expire = info?.expire ?? 0;
    // subscription-userinfo 缺失时 Bettbox 也会给一个全 0 的 SubscriptionInfo，按「无用量信息」处理
    final hasUsage = info != null && (total > 0 || used > 0 || expire > 0);
    final expireText = expire <= 0
        ? '未知到期'
        : isPermanentExpire(expire)
        ? '永久'
        : '到期 ${fmtDate(DateTime.fromMillisecondsSinceEpoch(expire * 1000))}';
    final profiles = ref.watch(profilesProvider);
    return GlassCard(
      radius: 18,
      border: Border.all(color: mm.accent, width: 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  profile.label ?? profile.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: MeowFont.headline,
                    fontWeight: FontWeight.w600,
                    color: mm.t1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TypeBadge('当前', color: mm.accent),
              _ProfileMenu(
                profile: profile,
                others: profiles.where((p) => p.id != profile.id).toList(),
                onError: onError,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (hasUsage) ...[
            Text(
              total > 0
                  ? '${fmtSize(used)} / ${fmtSize(total)}'
                  : '${fmtSize(used)} / ${S.unlimited}',
              style: MeowFont.mono(
                size: MeowFont.title3,
                weight: FontWeight.w600,
                color: mm.t1,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 6,
                backgroundColor: mm.t3.withValues(alpha: 0.15),
                color: frac > 0.9 ? mm.slow : mm.accent,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            [
              if (hasUsage)
                expireText
              else
                (profile.url.isEmpty ? '本地配置' : '订阅未提供用量信息'),
              if (profile.lastUpdateDate != null)
                '更新于 ${fmtRelative(profile.lastUpdateDate!)}',
            ].join(' · '),
            style: TextStyle(fontSize: MeowFont.caption, color: mm.t3),
          ),
        ],
      ),
    );
  }
}

/// 溢出菜单：切换到 X / 刷新 / 删除
class _ProfileMenu extends ConsumerWidget {
  const _ProfileMenu({
    required this.profile,
    required this.others,
    required this.onError,
  });
  final Profile profile;
  final List<Profile> others;
  final void Function(Object) onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    return PopupMenuButton<String>(
      tooltip: '',
      icon: Icon(Icons.more_horiz_rounded, color: mm.t2),
      onSelected: (v) async {
        final c = globalState.appController;
        try {
          if (v == 'refresh') {
            await c.updateProfile(profile);
          } else if (v == 'delete') {
            await c.deleteProfile(profile.id);
          } else if (v.startsWith('switch:')) {
            ref.read(currentProfileIdProvider.notifier).value = v.substring(7);
          }
        } catch (e) {
          onError(e);
        }
      },
      itemBuilder: (_) => [
        for (final p in others)
          PopupMenuItem(
            value: 'switch:${p.id}',
            child: Text(
              '切换到 ${p.label ?? p.id}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (profile.url.isNotEmpty)
          const PopupMenuItem(value: 'refresh', child: Text('刷新')),
        if (!isDirectProfile(profile.id))
          PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: mm.slow)),
          ),
      ],
    );
  }
}

/// 导入卡：说明 + 输入框 + 「导入订阅」主按钮 + 「查看配置」次按钮 + 深链提示。
class _ImportCard extends ConsumerStatefulWidget {
  const _ImportCard({required this.onError});
  final void Function(Object) onError;

  @override
  ConsumerState<_ImportCard> createState() => _ImportCardState();
}

class _ImportCardState extends ConsumerState<_ImportCard> {
  final _url = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() => _busy = true);
    try {
      await globalState.appController.addProfileFormURL(url);
      // 与 iOS 一致：手动导入的订阅直接成为当前档（Bettbox 只在没有当前档时才切）
      final added = ref
          .read(profilesProvider)
          .where((p) => p.url == url)
          .firstOrNull;
      if (added != null && ref.read(currentProfileIdProvider) != added.id) {
        ref.read(currentProfileIdProvider.notifier).value = added.id;
      }
      _url.clear();
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _view() async {
    final profile = ref.read(currentProfileProvider);
    if (profile == null) return;
    try {
      final content = await (await profile.getFile()).readAsString();
      if (!mounted) return;
      await BaseNavigator.push<String>(
        context,
        EditorPage(
          title: profile.label ?? profile.id,
          content: content,
          readOnly: true,
        ),
        maintainState: false,
      );
    } catch (e) {
      widget.onError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final hasProfiles = ref.watch(profilesProvider.select((s) => s.isNotEmpty));
    final hasCurrent = ref.watch(currentProfileProvider) != null;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_alt_rounded, size: 18, color: mm.accent),
              const SizedBox(width: 8),
              Text(
                '导入订阅节点',
                style: TextStyle(
                  fontSize: MeowFont.headline,
                  fontWeight: FontWeight.w600,
                  color: mm.t1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasProfiles ? '换订阅、加新订阅都在这里' : '还没有订阅：把订阅链接粘到下面，一键导入全部节点',
            style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _url,
            decoration: InputDecoration(
              hintText: '粘贴订阅 URL / 妙妙屋X 短链',
              isDense: true,
              filled: true,
              fillColor: mm.t1.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _import(),
          ),
          const SizedBox(height: 10),
          // 同账户卡双按钮：1.4 倍字时「内边距 38.4 + 四字 78.8」≈ 117，屏宽 < ~302dp（小窗 / 分屏）会折行
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _import,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _busy ? '导入中…' : '导入订阅',
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: hasCurrent ? _view : null,
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('查看配置', maxLines: 1, softWrap: false),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '也支持 clash://install-config 深链一键导入',
            style: TextStyle(fontSize: MeowFont.caption2, color: mm.t3),
          ),
        ],
      ),
    );
  }
}

/// 宽屏左栏档案列表：名 + 「当前」+ 紫进度条 + 溢出菜单；点行 = 设为当前。
class _ProfileList extends ConsumerWidget {
  const _ProfileList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final profiles = withDirectProfileLast(ref.watch(profilesProvider));
    final currentId = ref.watch(currentProfileIdProvider);
    if (profiles.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final p in profiles)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: GlassCard(
              radius: 14,
              padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
              border: p.id == currentId ? Border.all(color: mm.accent) : null,
              onTap: () =>
                  ref.read(currentProfileIdProvider.notifier).value = p.id,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                p.label ?? p.id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: MeowFont.subheadline,
                                  fontWeight: FontWeight.w500,
                                  color: mm.t1,
                                ),
                              ),
                            ),
                            if (p.id == currentId) ...[
                              const SizedBox(width: 6),
                              TypeBadge('当前', color: mm.accent),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _frac(p),
                            minHeight: 4,
                            backgroundColor: mm.t3.withValues(alpha: 0.15),
                            color: mm.pur,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ProfileMenu(
                    profile: p,
                    others: profiles.where((o) => o.id != p.id).toList(),
                    onError: (_) {},
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static double _frac(Profile p) {
    final info = p.subscriptionInfo;
    if (info == null || info.total <= 0) return 0;
    return ((info.upload + info.download) / info.total).clamp(0.0, 1.0);
  }
}
