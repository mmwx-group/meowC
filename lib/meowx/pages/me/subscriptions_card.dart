import 'dart:async';
import 'package:collection/collection.dart';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/meowx/pages/editor/editor_page.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../config/direct_profile.dart';
import '../../panel/account.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/morph_menu.dart';
import '../../theme/tokens.dart';
import 'me_kit.dart';

enum _ProfileAction { refresh, rename, view, delete }

/// 订阅卡：本机的配置档（当前档展开显示用量，点其它档 = 切换；内置直连档恒在末尾）
/// + 账户下的订阅（单独一组、带刷新钮；点 = 已下载的直接切换，没下载的下载并切换）+ 导入入口。[compact] = 宽屏第 1 列里的小一号，导入钮在卡片底部。
class SubscriptionsCard extends ConsumerStatefulWidget {
  const SubscriptionsCard({super.key, required this.onError, this.compact = false});

  final void Function(Object) onError;
  final bool compact;

  @override
  ConsumerState<SubscriptionsCard> createState() => _SubscriptionsCardState();
}

class _SubscriptionsCardState extends ConsumerState<SubscriptionsCard> {
  bool _importing = false;

  /// 最近一次拉到的账户订阅：刷新期间（provider 是 loading、没有值）继续显示它，列表不闪
  List<RemoteSubscription> _lastSubs = const [];

  @override
  void initState() {
    super.initState();
    final v = ref.read(remoteSubsProvider);
    if (ref.read(isLoggedInProvider) && v.hasValue && (v.value?.isEmpty ?? true)) {
      Future.microtask(() => ref.read(accountActionsProvider).refreshSubscriptions());
    }
  }

  Future<void> _import() async {
    final url = await _showImportSheet(context);
    if (url == null || !mounted) return;
    setState(() => _importing = true);
    try {
      // 失败由 Bettbox 自己弹框提示；它还会把导航栈弹回首层，所以表单要先关掉再调
      await globalState.appController.addProfileFormURL(url);
      // 与 iOS 一致：手动导入的订阅直接成为当前档（Bettbox 只在没有当前档时才切）
      final added = ref.read(profilesProvider).where((p) => p.url == url).firstOrNull;
      if (added != null && ref.read(currentProfileIdProvider) != added.id) {
        ref.read(currentProfileIdProvider.notifier).value = added.id;
      }
    } catch (e) {
      widget.onError(e);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  List<MeowMenuEntry<_ProfileAction>> _menuItems(Profile p) => [
    if (p.url.isNotEmpty) const MeowMenuItem(_ProfileAction.refresh, '刷新'),
    if (!isDirectProfile(p.id)) const MeowMenuItem(_ProfileAction.rename, '重命名'),
    const MeowMenuItem(_ProfileAction.view, '查看配置'),
    if (!isDirectProfile(p.id)) MeowMenuItem(_ProfileAction.delete, '删除', color: context.mm.slow),
  ];

  Future<void> _run(_ProfileAction action, Profile p) async {
    try {
      switch (action) {
        case _ProfileAction.refresh:
          MeowHaptics.tap();
          unawaited(ref.read(accountActionsProvider).refreshProfile());   // 昵称 / 头像跟着用户点的刷新走，不定时拉
          await globalState.appController.updateProfile(p);
        case _ProfileAction.rename:
          final name = (await mePrompt(context, '重命名', p.label ?? ''))?.trim();
          if (!mounted || name == null || name.isEmpty || name == p.label) return;
          // 只改档名、不动配置文件，不用重载内核；之后刷新也留着这个名字（Profile.update 只在没名字时才取主控给的标题）。
          // setProfile 与 appController.setProfile 同一句，重名会自动加后缀
          final latest = ref.read(profilesProvider).getProfile(p.id);
          if (latest != null) ref.read(profilesProvider.notifier).setProfile(latest.copyWith(label: name));
        case _ProfileAction.view:
          final content = await (await p.getFile()).readAsString();
          await ensureEditorRuntime();   // 编辑器的 Rust 库按需加载，进页面前等它就绪
          if (!mounted) return;
          await BaseNavigator.push<String>(
            context,
            EditorPage(title: p.label ?? p.id, content: content, readOnly: true),
            maintainState: false,
          );
        case _ProfileAction.delete:
          await globalState.appController.deleteProfile(p.id);
      }
    } catch (e) {
      widget.onError(e);
    }
  }

  /// 非当前档没有「⋯」钮：长按 / 右键在指针处弹同一份菜单。
  Future<void> _menuAt(Offset position, Profile p) async {
    // 没有触发按钮：从指针那一点长出来（起点是卡片白、直角）
    final action = await showMeowMenu<_ProfileAction>(
      context,
      anchor: position & Size.zero,
      entries: _menuItems(p),
      width: 200,
      fromColor: context.mm.elev,
      fromRadius: 0,
    );
    if (action != null) await _run(action, p);
  }

  Future<void> _download(RemoteSubscription s) async {
    try {
      await ref.read(accountActionsProvider).importSubscription(s);
    } catch (e) {
      widget.onError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final compact = widget.compact;
    final profiles = withDirectProfileLast(ref.watch(profilesProvider));
    final currentId = ref.watch(currentProfileIdProvider);
    final loggedIn = ref.watch(isLoggedInProvider);
    final host = ref.watch(meowSettingProvider.select((s) => s.account.host));
    final subs = ref.watch(remoteSubsProvider);
    if (subs.hasValue) _lastSubs = subs.value!;
    final importing = ref.watch(importingSubProvider);
    // 账户下的订阅单独一组、全部列出（同 iOS）：已经下载到本机的点了直接切到那一档，没下载的先下载再切。
    // 认「已下载」按地址（与首页切换菜单、iOS 同一套规则，见 notDownloadedSubscriptions），不看档名
    Profile? localOf(RemoteSubscription sub) => profiles.firstWhereOrNull(
      (p) => p.url.isNotEmpty && notDownloadedSubscriptions(remote: [sub], host: host, localUrls: [p.url]).isEmpty,
    );
    final note = TextStyle(fontSize: MeowFont.caption, color: mm.t2);
    final cs = context.cs;

    // 本机的订阅档：一组分段清单（当前档 = 次色容器底 + 主色勾，画布稿）
    final local = [
      for (final p in profiles)
        if (p.id == currentId)
          _CurrentTile(
            profile: p,
            menu: MeowMenuButton<_ProfileAction>(
              width: 200,
              alignEnd: true,
              onSelected: (a) => _run(a, p),
              entries: () => _menuItems(p),
              builder: (_, open) => IconButton(
                tooltip: '订阅管理',
                icon: Icon(Icons.more_horiz_rounded, color: cs.onSecondaryContainer),
                onPressed: open,
              ),
            ),
          )
        else
          _ProfileTile(
            profile: p,
            onTap: () => ref.read(currentProfileIdProvider.notifier).value = p.id,
            onMenu: (pos) => _menuAt(pos, p),
          ),
    ];
    final remote = [
      for (final sub in _lastSubs)
        _RemoteTile(
          sub: sub,
          busy: importing == sub.name,
          onTap: importing != null
              ? null
              : () {
                  final local = localOf(sub);
                  if (local != null) {
                    ref.read(currentProfileIdProvider.notifier).value = local.id;
                  } else {
                    _download(sub);
                  }
                },
        ),
    ];
    final importButton = Material(
      color: cs.secondaryContainer,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _importing ? null : _import,
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 18, color: cs.onSecondaryContainer),
                const SizedBox(width: 4),
                Text(
                  _importing ? '导入中…' : '导入',
                  style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w700, color: cs.onSecondaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Widget label(String text, Widget? trailing) => Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 8),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: compact ? MeowFont.caption : MeowFont.footnote, fontWeight: FontWeight.w700, color: cs.primary),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        label('订阅', importButton),
        M3SegmentedList(children: local),
        if (profiles.every((p) => isDirectProfile(p.id)) && (!loggedIn || _lastSubs.isEmpty))
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
            child: Text('还没有订阅：点「导入」粘贴订阅链接，一键导入全部节点', style: note),
          ),
        if (loggedIn) ...[
          const SizedBox(height: 16),
          label(
            '账户下的订阅',
            IconButton(
              tooltip: '刷新我的订阅',
              onPressed: subs.isLoading
                  ? null
                  : () {
                      final actions = ref.read(accountActionsProvider);
                      unawaited(actions.refreshProfile());
                      actions.refreshSubscriptions();
                    },
              icon: subs.isLoading
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
                  : Icon(Icons.refresh_rounded, size: 20, color: cs.primary),
            ),
          ),
          if (remote.isNotEmpty) M3SegmentedList(children: remote),
          switch (subs) {
            AsyncError(:final error) => Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text('拉取失败：$error', style: note.copyWith(color: cs.error)),
            ),
            AsyncData(:final value) when value.isEmpty => Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
              child: Text('账户下暂无订阅（或主控未放行 /api/subscriptions）', style: note),
            ),
            _ => const SizedBox.shrink(),
          },
        ],
      ],
    );
  }
}

/// 「128.4 / 500 GB」：两边都到 GB 时合用一个单位（设计稿的写法），否则各带各的单位。
String _usageText(int used, int total) {
  const gb = 1024 * 1024 * 1024;
  if (total <= 0) return '${fmtSize(used)} / ${S.unlimited}';
  if (used < gb || total < gb) return '${fmtSize(used)} / ${fmtSize(total)}';
  final t = total / gb;
  return '${(used / gb).toStringAsFixed(1)} / ${t.toStringAsFixed(t == t.roundToDouble() ? 0 : 1)} GB';
}

/// 当前档（画布稿）：次色容器底、四角 28；主色圆里一个勾 + 名 / 用量 · 到期 · 更新时间 +「⋯」菜单；有总量时下面一条波浪进度。
class _CurrentTile extends StatelessWidget {
  const _CurrentTile({required this.profile, required this.menu});
  final Profile profile;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final info = profile.subscriptionInfo;
    final used = (info?.upload ?? 0) + (info?.download ?? 0);
    final total = info?.total ?? 0;
    final frac = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final expire = info?.expire ?? 0;
    // subscription-userinfo 缺失时 Bettbox 也会给一个全 0 的 SubscriptionInfo，按「无用量信息」处理
    final hasUsage = info != null && (total > 0 || used > 0 || expire > 0);
    final direct = isDirectProfile(profile.id);
    final meta = [
      if (direct)
        '内置 · 流量全部直连'
      else if (!hasUsage)
        (profile.url.isEmpty ? '本地配置' : '订阅未提供用量信息')
      else ...[
        _usageText(used, total),
        if (expire <= 0)
          '未知到期'
        else if (isPermanentExpire(expire))
          '永久'
        else
          '到期 ${fmtDate(DateTime.fromMillisecondsSinceEpoch(expire * 1000))}',
      ],
      if (!direct && profile.lastUpdateDate != null) '${fmtRelative(profile.lastUpdateDate!)}更新',
    ].join(' · ');
    final fg = cs.onSecondaryContainer;
    return Semantics(
      label: '当前订阅',
      child: Container(
        decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(MeowShape.xl)),
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                M3IconTile(icon: Icons.check_rounded, shape: M3TileShape.circle, bg: cs.primary, fg: cs.onPrimary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.label ?? profile.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: MeowFont.body, fontWeight: FontWeight.w700, color: fg),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: MeowFont.caption, color: fg.withValues(alpha: 0.85)),
                      ),
                    ],
                  ),
                ),
                SizedBox.square(dimension: 44, child: menu),
              ],
            ),
            if (hasUsage && total > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(54, 8, 14, 0),
                child: M3WavyProgress(value: frac, color: frac > 0.9 ? cs.error : null, height: 10),
              ),
          ],
        ),
      ),
    );
  }
}

/// 其它档：分段清单的一行，图标块（内置直连 / 本地文件 / 订阅）+ 名 / 用量；点 = 设为当前，长按 / 右键 = 菜单。
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.profile, required this.onTap, required this.onMenu});
  final Profile profile;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final info = profile.subscriptionInfo;
    final total = info?.total ?? 0;
    final direct = isDirectProfile(profile.id);
    final subtitle = direct
        ? '内置 · 流量全部直连'
        : total > 0
        ? _usageText(info!.upload + info.download, total)
        : (profile.url.isEmpty ? '本地配置' : '订阅');
    return GestureDetector(
      onLongPressStart: (d) => onMenu(d.globalPosition),
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: M3ListRow(
        title: profile.label ?? profile.id,
        titleSize: 15,
        subtitle: subtitle,
        subtitleMaxLines: 1,
        onTap: onTap,
        leading: M3IconTile(
          icon: direct ? Icons.alt_route_rounded : (profile.url.isEmpty ? Icons.description_outlined : Icons.cloud_outlined),
          shape: direct ? M3TileShape.leafA : M3TileShape.rounded,
          bg: cs.surfaceContainerHighest,
          fg: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 账户下的订阅：图标块 + 名 /「已用 X / Y · 到期 yyyy-MM-dd」+ 下载图标；点 = 已下载的直接切换，没下载的下载并切换。
class _RemoteTile extends StatelessWidget {
  const _RemoteTile({required this.sub, required this.busy, required this.onTap});
  final RemoteSubscription sub;
  final bool busy;
  final VoidCallback? onTap;

  String get _subtitle {
    final s = sub;
    final parts = <String>[];
    if (s.trafficTotal != null && s.trafficTotal! > 0) {
      parts.add('已用 ${fmtSize(s.trafficUsed ?? 0)} / ${fmtSize(s.trafficTotal!)}');
    } else if (s.trafficUsed != null) {
      parts.add('已用 ${fmtSize(s.trafficUsed!)}');
    }
    if (s.expireAt != null) parts.add('到期 ${fmtDate(s.expireAt!.toLocal())}');
    return parts.isEmpty ? (s.filename.isNotEmpty ? s.filename : '—') : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return M3ListRow(
      title: sub.name,
      titleSize: 15,
      subtitle: _subtitle,
      onTap: onTap,
      leading: M3IconTile(
        icon: Icons.inventory_2_outlined,
        shape: M3TileShape.leafB,
        bg: cs.tertiaryContainer,
        fg: cs.onTertiaryContainer,
      ),
      trailing: busy
          ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
          : Icon(Icons.download_rounded, color: cs.primary),
    );
  }
}

/// 导入订阅的输入表单（带回弹的对话框）：返回要导入的地址（取消 → null）。
Future<String?> _showImportSheet(BuildContext context) {
  final url = TextEditingController();
  void submit(BuildContext ctx) {
    final v = url.text.trim();
    if (v.isNotEmpty) Navigator.of(ctx).pop(v);
  }

  return showMeowDialog<String>(
    context,
    title: '导入订阅',
    builder: (ctx) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '换订阅、加新订阅都在这里：把订阅链接粘到下面，一键导入全部节点',
            style: TextStyle(fontSize: MeowFont.footnote, color: ctx.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: url,
            autofocus: true,
            decoration: const InputDecoration(hintText: '粘贴订阅 URL / 妙妙屋X 短链'),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => submit(ctx),
          ),
          const SizedBox(height: 10),
          Text(
            '也支持 clash://install-config 深链一键导入',
            style: TextStyle(fontSize: MeowFont.caption, color: ctx.cs.onSurfaceVariant),
          ),
        ],
      ),
    ),
    actions: (ctx) => [
      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
      FilledButton(onPressed: () => submit(ctx), child: const Text('导入')),
    ],
  );
}
