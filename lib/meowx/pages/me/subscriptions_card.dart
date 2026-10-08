import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/pages.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../config/direct_profile.dart';
import '../../panel/account.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';

enum _ProfileAction { refresh, view, delete }

/// 订阅卡：本机的配置档（当前档展开显示用量，点其它档 = 切换；内置直连档恒在末尾）
/// + 账户下还没导入的订阅（点 = 下载并切换）+ 导入入口。[compact] = 宽屏第 1 列里的小一号，导入钮在卡片底部。
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

  List<PopupMenuEntry<_ProfileAction>> _menuItems(Profile p) => [
    if (p.url.isNotEmpty) const PopupMenuItem(value: _ProfileAction.refresh, child: Text('刷新')),
    const PopupMenuItem(value: _ProfileAction.view, child: Text('查看配置')),
    if (!isDirectProfile(p.id))
      PopupMenuItem(
        value: _ProfileAction.delete,
        child: Text('删除', style: TextStyle(color: context.mm.slow)),
      ),
  ];

  Future<void> _run(_ProfileAction action, Profile p) async {
    final c = globalState.appController;
    try {
      switch (action) {
        case _ProfileAction.refresh:
          await c.updateProfile(p);
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
          await c.deleteProfile(p.id);
      }
    } catch (e) {
      widget.onError(e);
    }
  }

  /// 非当前档没有「⋯」钮：长按 / 右键在指针处弹同一份菜单。
  Future<void> _menuAt(Offset position, Profile p) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_ProfileAction>(
      context: context,
      position: RelativeRect.fromRect(position & Size.zero, Offset.zero & overlay.size),
      items: _menuItems(p),
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
    final host = Uri.tryParse(ref.watch(meowSettingProvider.select((s) => s.account.host)))?.host ?? '';
    final subs = ref.watch(remoteSubsProvider);
    if (subs.hasValue) _lastSubs = subs.value!;
    final importing = ref.watch(importingSubProvider);
    // 已经导入过的账户订阅就是上面的某一档（导入时档名 = 订阅名），不再重复列
    final pending = [
      if (loggedIn)
        for (final s in _lastSubs)
          if (!profiles.any((p) => p.label == s.name && p.url.isNotEmpty && Uri.tryParse(p.url)?.host == host)) s,
    ];
    final note = TextStyle(fontSize: MeowFont.caption, color: mm.t2);
    final gap = SizedBox(height: compact ? 8 : 10);

    final tiles = <Widget?>[
      for (final p in profiles)
        if (p.id == currentId)
          _CurrentTile(
            profile: p,
            menu: PopupMenuButton<_ProfileAction>(
              tooltip: '订阅管理',
              padding: EdgeInsets.zero,
              icon: Icon(Icons.more_horiz_rounded, size: 20, color: mm.t2),
              onSelected: (a) => _run(a, p),
              itemBuilder: (_) => _menuItems(p),
            ),
          )
        else
          _ProfileTile(
            profile: p,
            onTap: () => ref.read(currentProfileIdProvider.notifier).value = p.id,
            onMenu: (pos) => _menuAt(pos, p),
          ),
      for (final s in pending)
        _RemoteTile(sub: s, busy: importing == s.name, onTap: importing != null ? null : () => _download(s)),
      if (profiles.every((p) => isDirectProfile(p.id)) && pending.isEmpty)
        Text('还没有订阅：点「导入订阅」粘贴订阅链接，一键导入全部节点', style: note),
      if (loggedIn)
        switch (subs) {
          AsyncError(:final error) => Text('拉取失败：$error', style: note.copyWith(color: mm.slow)),
          AsyncData(:final value) when value.isEmpty => Text('账户下暂无订阅（或主控未放行 /api/subscriptions）', style: note),
          _ => null,
        },
    ].nonNulls.toList();

    return Container(
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(compact ? 22 : 24)),
      padding: compact ? const EdgeInsets.fromLTRB(12, 6, 12, 12) : const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '订阅',
                    style: TextStyle(
                      fontSize: compact ? MeowFont.caption : MeowFont.footnote,
                      fontWeight: FontWeight.w600,
                      color: mm.t2,
                    ),
                  ),
                ),
                if (loggedIn)
                  IconButton(
                    tooltip: '刷新我的订阅',
                    visualDensity: VisualDensity.compact,
                    onPressed: subs.isLoading ? null : () => ref.read(accountActionsProvider).refreshSubscriptions(),
                    icon: subs.isLoading
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: mm.t2),
                          )
                        : MeowIcon(MeowGlyph.refresh, size: 16, color: mm.t2),
                  ),
                if (!compact)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _importing ? null : _import,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: Text(
                      _importing ? '导入中…' : '导入订阅',
                      style: const TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          for (final (i, t) in tiles.indexed) ...[if (i > 0) gap, t],
          if (compact) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _importing ? null : _import,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: Text(_importing ? '导入中…' : '导入订阅'),
            ),
          ],
        ],
      ),
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

/// 当前档：柔粉底 + 玫红描边；名 +「当前」+「⋯」菜单；用量进度条；已用 / 总量、到期、更新时间。
class _CurrentTile extends StatelessWidget {
  const _CurrentTile({required this.profile, required this.menu});
  final Profile profile;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
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
        '内置'
      else if (!hasUsage)
        (profile.url.isEmpty ? '本地配置' : '订阅未提供用量信息')
      else if (expire <= 0)
        '未知到期'
      else if (isPermanentExpire(expire))
        '永久'
      else
        '到期 ${fmtDate(DateTime.fromMillisecondsSinceEpoch(expire * 1000))}',
      if (!direct && profile.lastUpdateDate != null) '${fmtRelative(profile.lastUpdateDate!)}更新',
    ].join(' · ');
    final small = TextStyle(fontSize: MeowFont.caption2, color: mm.t2);
    return Container(
      decoration: BoxDecoration(
        color: mm.soft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: mm.accent, width: 2),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.label ?? profile.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        '当前',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: mm.accent, height: 1.2),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 36, height: 36, child: menu),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasUsage) ...[
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 6,
                      backgroundColor: mm.elev,
                      color: frac > 0.9 ? mm.slow : mm.pink,
                    ),
                  ),
                  const SizedBox(height: 7),
                ],
                // 两段放不下一行（大字号 / 窄列）时自动折成两行
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    if (hasUsage) Text(_usageText(used, total), style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2)),
                    Text(meta, style: small),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 其它档：次级底的一行，名 + 用量；点 = 设为当前，长按 / 右键 = 菜单。
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.profile, required this.onTap, required this.onMenu});
  final Profile profile;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final info = profile.subscriptionInfo;
    final total = info?.total ?? 0;
    final trailing = isDirectProfile(profile.id)
        ? '内置'
        : total > 0
        ? _usageText(info!.upload + info.download, total)
        : (profile.url.isEmpty ? '本地配置' : '');
    return Material(
      color: mm.card2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        onLongPressStart: (d) => onMenu(d.globalPosition),
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      profile.label ?? profile.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w500, color: mm.t1),
                    ),
                  ),
                  if (trailing.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      trailing,
                      maxLines: 1,
                      style: total > 0
                          ? MeowFont.mono(size: MeowFont.caption2, color: mm.t2)
                          : TextStyle(fontSize: MeowFont.caption2, color: mm.t2),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 账户下还没导入的订阅：名 +「已用 X / Y · 到期 yyyy-MM-dd」+ 下载图标；点 = 下载并切换为当前。
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
    final mm = context.mm;
    return Material(
      color: mm.card2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sub.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w500, color: mm.t1),
                    ),
                    Text(
                      _subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: mm.accent),
                    )
                  : MeowIcon(MeowGlyph.down, size: 18, color: mm.accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导入订阅的输入表单：返回要导入的地址（取消 → null）。
Future<String?> _showImportSheet(BuildContext context) {
  final url = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      final mm = ctx.mm;
      void submit() {
        final v = url.text.trim();
        if (v.isNotEmpty) Navigator.of(ctx).pop(v);
      }

      // 键盘高度留在外层、表单自己可滚（同登录表单）
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.paddingOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '导入订阅',
                style: TextStyle(fontSize: MeowFont.title3, fontWeight: FontWeight.w600, color: mm.t1),
              ),
              const SizedBox(height: 4),
              Text(
                '换订阅、加新订阅都在这里：把订阅链接粘到下面，一键导入全部节点',
                style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: url,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '粘贴订阅 URL / 妙妙屋X 短链',
                  isDense: true,
                  filled: true,
                  fillColor: mm.card2,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: submit, child: const Text('导入订阅')),
              ),
              const SizedBox(height: 8),
              Text('也支持 clash://install-config 深链一键导入', style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
            ],
          ),
        ),
      );
    },
  );
}
