import 'dart:async';

import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/mesh_config.dart';
import '../../state/format.dart';
import '../../state/mesh.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../state/tailscale_status.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';

/// 「喵窝」的显示名（arb 的 meowNest：简体喵窝 / 繁体喵窩 / 英文 MeowNest）；多语言没加载时（单测）用简体。
String meowNestName(BuildContext context) => AppLocalizations.maybeOf(context)?.meowNest ?? '喵窝';

String networkingModeLabel(BuildContext context, NetworkingMode m) => switch (m) {
  NetworkingMode.off => '关闭',
  NetworkingMode.mesh => meowNestName(context),
  NetworkingMode.tailscale => 'Tailscale',
};

/// 「我的」里「组网」一行的行尾。
String networkingSummary(BuildContext context, WidgetRef ref) {
  switch (ref.watch(networkingModeProvider)) {
    case NetworkingMode.mesh:
      return '${meowNestName(context)} · ${meshStatusLine(ref)}';
    case NetworkingMode.tailscale:
      return 'Tailscale · ${ref.watch(subscriptionTailscaleNodesProvider).length} 个组网节点';
    case NetworkingMode.off:
      return '关';
  }
}

/// 喵窝此刻的一行状态（首页卡片、「组网」页、「我的」行尾共用）。
String meshStatusLine(WidgetRef ref) {
  final state = ref.watch(meshProvider);
  final enabled = ref.watch(meowSettingProvider.select((s) => s.mesh.enabled));
  final nodeId = ref.watch(meowSettingProvider.select((s) => s.mesh.nodeId));
  final phase = meshPhase(enabled: enabled, running: ref.watch(isRunningProvider), state: state, fallbackId: nodeId);
  return meshPhaseText(phase, state, fallbackId: nodeId);
}

/// 切到 [target] 之前问一句：代理在跑时切换要重新应用一次配置，正在进行的连接会断开。返回是否继续。
Future<bool> confirmNetworkingSwitch(BuildContext context, String target) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('切换到「$target」'),
      content: const Text('要重新应用一次配置，正在进行的连接会断开。'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('切换')),
      ],
    ),
  );
  return go == true;
}

/// 切换「组网」（「组网」页与首页喵窝卡共用）：不可用就说原因，代理在跑时先确认，最后只重新应用一次配置。
/// [onStart]：确认之后、真正开始切换时调（调用方据此转圈）。返回出错原因（null = 切好了或用户取消）。
Future<String?> switchNetworking(BuildContext context, WidgetRef ref, NetworkingMode target, {VoidCallback? onStart}) async {
  if (target == ref.read(networkingModeProvider)) return null;
  final reason = networkingUnavailableReason(context, ref, target);
  if (reason != null) return reason;
  if (ref.read(isRunningProvider)) {
    if (!await confirmNetworkingSwitch(context, networkingModeLabel(context, target))) return null;
  }
  onStart?.call();
  final ok = await ref.read(meshProvider.notifier).setMode(target);
  return ok ? null : (ref.read(meshProvider).error ?? '切换失败');
}

/// 切到哪个不可用时的原因（null = 可以切）。
String? networkingUnavailableReason(BuildContext context, WidgetRef ref, NetworkingMode mode) {
  switch (mode) {
    case NetworkingMode.off:
      return null;
    case NetworkingMode.mesh:
      if (!ref.read(meshVisibleProvider)) return '${meowNestName(context)}只在登录主控的管理员账号时可用';
      final s = ref.read(meshProvider);
      if (s.availability == MeshAvailability.unavailable) return s.message;
      return null;
    case NetworkingMode.tailscale:
      return ref.read(subscriptionTailscaleNodesProvider).isEmpty ? '当前订阅里没有 Tailscale 组网节点' : null;
  }
}

/// 「组网」页：三选一 关闭 / 喵窝 / Tailscale，下面是选中那个的状态（同 iOS / macOS 的 NetworkingPageContent）。
/// 两个不能同时开；代理在跑时切换要重新应用一次配置，先确认。页面开着时每 3 秒看一次状态文件、每 9 秒问一次主控。
class NetworkingPage extends ConsumerStatefulWidget {
  const NetworkingPage({super.key});

  @override
  ConsumerState<NetworkingPage> createState() => _NetworkingPageState();
}

class _NetworkingPageState extends ConsumerState<NetworkingPage> {
  Timer? _timer;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) unawaited(ref.read(meshProvider.notifier).tick(devicesEvery: Duration.zero));
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && TickerMode.getValuesNotifier(context).value.enabled) {
        unawaited(ref.read(meshProvider.notifier).tick(devicesEvery: const Duration(seconds: 9)));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _choose(NetworkingMode value) async {
    if (_switching) return;
    setState(() => _error = null);
    final err = await switchNetworking(context, ref, value, onStart: () => setState(() => _switching = true));
    if (mounted) {
      setState(() {
        _switching = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final mode = ref.watch(networkingModeProvider);
    final meshVisible = ref.watch(meshVisibleProvider);
    final hasTs = ref.watch(subscriptionTailscaleNodesProvider).isNotEmpty;
    final meshState = ref.watch(meshProvider);
    final options = [
      NetworkingMode.off,
      if (meshVisible || mode == NetworkingMode.mesh) NetworkingMode.mesh,
      NetworkingMode.tailscale,
    ];
    final dimmed = {
      if (!hasTs) NetworkingMode.tailscale,
      if (meshState.availability == MeshAvailability.unavailable && mode != NetworkingMode.mesh) NetworkingMode.mesh,
    };
    return MeSubPage.list(
      title: '组网',
      children: [
        MeSection(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: MeowSegment<NetworkingMode>(
                          items: [for (final o in options) (o, networkingModeLabel(context, o))],
                          value: mode,
                          onChanged: (v) => unawaited(_choose(v)),
                          onCard: true,
                          height: 40,
                          dimmed: dimmed,
                        ),
                      ),
                      if (_switching || meshState.busy) ...[
                        const SizedBox(width: 10),
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(fontSize: MeowFont.caption, color: mm.slow)),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (mode == NetworkingMode.mesh) ...const [MeshDetails()],
        // 没开喵窝也能先把设备名设好（管理员、主控说可用时）
        if (mode != NetworkingMode.mesh && meshState.availability == MeshAvailability.available)
          MeSection(
            title: '${meowNestName(context)}设备名',
            note: '打开前可先设好',
            children: const [MeshHostnameRow()],
          ),
        if (mode == NetworkingMode.tailscale) const _TailscaleDetails(),
        MeCaption('${meowNestName(context)}与订阅里的 Tailscale 组网节点只能开一个：两边都用 100.64.0.0/10 的地址，同时开会互相抢路由。'),
      ],
    );
  }
}

/// 喵窝的状态、我的设备、我的站点、退出喵窝（「组网」页里选了喵窝时）。
class MeshDetails extends ConsumerWidget {
  const MeshDetails({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final name = meowNestName(context);
    final state = ref.watch(meshProvider);
    final mesh = ref.watch(meowSettingProvider.select((s) => s.mesh));
    final running = ref.watch(isRunningProvider);
    final phase = meshPhase(enabled: mesh.enabled, running: running, state: state, fallbackId: mesh.nodeId);
    final self = state.selfDevice(mesh.nodeId);
    final statusColor = switch (phase) {
      MeshPhase.connected => mm.good,
      MeshPhase.failed => mm.slow,
      _ => mm.t2,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeSection(
          title: name,
          children: [
            MeRow(
              label: '状态',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(color: statusColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      meshPhaseText(phase, state, fallbackId: mesh.nodeId),
                      maxLines: 2,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: MeowFont.footnote, color: statusColor),
                    ),
                  ),
                ],
              ),
            ),
            if (state.selfAddress(mesh.nodeId) case final ip when ip.isNotEmpty)
              MeRow(label: '本机地址', value: ip, mono: true, onTap: () => _copy(ip)),
            const MeshHostnameRow(),
          ],
        ),
        if (state.devices.isNotEmpty) ...[
          const SizedBox(height: 12),
          MeSection(
            title: '我的设备',
            note: '点按复制地址',
            children: [
              for (final d in state.devices)
                _DeviceRow(device: d, isSelf: d.id == self?.id, selfOnline: phase == MeshPhase.connected, path: state.pathOf(d)),
            ],
          ),
        ],
        if (state.sites.isNotEmpty) ...[
          const SizedBox(height: 12),
          MeSection(
            title: '我的站点',
            children: [for (final s in state.sites) _SiteRow(site: s)],
          ),
        ],
        if (mesh.enabled) ...[
          const SizedBox(height: 12),
          const _LeaveButton(),
        ],
        MeCaption('$name由主控提供：同一账号的设备互相访问，OpenWrt 开放的局域网（家里的 NAS、路由器后台）在外面也能直接打开。设备之间端到端加密，主控与中继看不到内容。'),
      ],
    );
  }
}

/// 「设备名」：显示现在生效的名字（自定义的，或留空时的自动名：安卓机型 / 计算机名）+「修改」；
/// 编辑时就地换成输入框 + 保存 / 取消，下面预览「将显示为 名字.MagicDNS 后缀」（同 iOS / macOS 的设备名一行）。
/// 多台同型号设备默认同名，主控会给后来的加 -1、-2，用户可以自己起个好认的名字。
class MeshHostnameRow extends ConsumerStatefulWidget {
  const MeshHostnameRow({super.key});

  @override
  ConsumerState<MeshHostnameRow> createState() => _MeshHostnameRowState();
}

class _MeshHostnameRowState extends ConsumerState<MeshHostnameRow> {
  final _controller = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    _controller.text = ref.read(meowSettingProvider).mesh.customHostname;
    setState(() {
      _editing = true;
      _error = null;
    });
  }

  void _cancel() => setState(() {
    _editing = false;
    _error = null;
  });

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final err = await ref.read(meshProvider.notifier).setCustomHostname(_controller.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = err;
      if (err == null) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final mesh = ref.watch(meowSettingProvider.select((s) => s.mesh));
    final auto = ref.watch(meshAutoHostnameProvider).valueOrNull ?? (mesh.customHostname.isEmpty ? mesh.hostname : '');
    final effective = meshEffectiveHostname(custom: mesh.customHostname, auto: auto);
    if (!_editing) {
      return MeRow(
        label: '设备名',
        subtitle: mesh.customHostname.isEmpty ? '自动（本机型号 / 计算机名）' : null,
        value: effective.isEmpty ? null : effective,
        mono: true,
        trailing: Text(
          '修改',
          style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: mm.accent),
        ),
        onTap: _start,
      );
    }
    final magicDns = ref.watch(meshProvider.select((s) => s.magicDns));
    final suffix = magicDns.isNotEmpty ? magicDns : mesh.magicDns;
    final parsed = parseMeshCustomHostname(_controller.text);
    final preview = parsed.error != null
        ? parsed.error!
        : '将显示为 ${meshDnsName(meshEffectiveHostname(custom: parsed.name, auto: auto), suffix)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('设备名', style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w500, color: mm.t1)),
          const SizedBox(height: 6),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            maxLength: 63,
            style: MeowFont.mono(size: MeowFont.footnote, color: mm.t1),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => unawaited(_save()),
            decoration: InputDecoration(
              isDense: true,
              hintText: auto.isEmpty ? '留空用自动名' : auto,
              counterText: '',
              errorText: _error,
              errorMaxLines: 2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            preview,
            style: TextStyle(fontSize: MeowFont.caption, color: parsed.error != null ? mm.slow : mm.t2),
          ),
          const SizedBox(height: 2),
          Text(
            '留空用自动名；名字已被别的设备占用时，主控会自动在后面加 -1、-2。',
            style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _saving ? null : _cancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : () => unawaited(_save()),
                child: _saving
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

void _copy(String text) {
  Clipboard.setData(ClipboardData(text: text));
  globalState.showNotifier('已复制 $text');
}

/// 一台设备：在线时写内核看到的路径（直连 / 中继 · 区域，拿不到内核状态时只写「在线」），离线写离线多久。
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.isSelf, required this.selfOnline, this.path});
  final MeshDevice device;
  final bool isSelf;
  final bool selfOnline;

  /// 内核里这台对端的状态（直连地址 / 中继）
  final TsPeer? path;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final online = isSelf ? selfOnline : device.online;
    final seen = device.lastSeen;
    final value = isSelf
        ? (online ? '在线' : '')
        : online
        ? (path?.pathText ?? '在线')
        : (seen == null ? '离线' : '离线 · ${fmtRelative(seen.toLocal())}');
    return MeRow(
      leading: StatusDot(color: online ? mm.good : mm.t3),
      label: '${device.name}${isSelf ? '（本机）' : ''}',
      subtitle: [if (device.ipv4.isNotEmpty) device.ipv4, ...device.routes].join(' · '),
      value: value.isEmpty ? null : value,
      onTap: device.ipv4.isEmpty ? null : () => _copy(device.ipv4),
    );
  }
}

class _SiteRow extends ConsumerWidget {
  const _SiteRow({required this.site});
  final MeshSite site;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final locals = ref.watch(meshLocalIPv4sProvider);
    final conflict = meshActiveSites([site.advertised], locals).isEmpty && Ipv4Cidr.parse(site.advertised) != null;
    final note = conflict
        ? '和当前所在网络是同一网段，这次没有接入；在 OpenWrt 上改成「总是映射」后用映射段访问'
        : site.mapped
        ? '和别的站点同网段，已映射：主机号不变，用映射段地址访问'
        : '原样开放：直接用局域网地址访问';
    return MeRow(
      label: site.mapped ? '${site.original} → ${site.advertised}' : site.original,
      subtitle: note,
      subtitleColor: conflict ? mm.slow : null,
      subtitleMaxLines: null,
    );
  }
}

/// 退出喵窝：确认后从主控删掉这台设备、关掉喵窝（以后再打开会作为新设备重新入网）。
class _LeaveButton extends ConsumerWidget {
  const _LeaveButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final name = meowNestName(context);
    final busy = ref.watch(meshProvider.select((s) => s.busy));
    return MeSection(
      children: [
        MeRow(
          label: '退出$name',
          subtitle: '从主控删掉这台设备并关闭$name',
          trailing: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onTap: busy
              ? null
              : () async {
                  final go = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('退出$name'),
                      content: Text('这台设备会从主控的设备列表里删掉、$name关闭；以后再打开会作为新设备重新入网。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: mm.slow),
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('退出并删除'),
                        ),
                      ],
                    ),
                  );
                  if (go == true) await ref.read(meshProvider.notifier).leave();
                },
        ),
      ],
    );
  }
}

/// 选了 Tailscale：订阅里的组网节点，各自的状态（内核 meowTailscaleStatus；页面开着、代理在跑时每 3 秒问一次，
/// 没启动的节点会被启动）、本机地址、需要登录时的链接、各设备直连还是中继。
class _TailscaleDetails extends ConsumerStatefulWidget {
  const _TailscaleDetails();

  @override
  ConsumerState<_TailscaleDetails> createState() => _TailscaleDetailsState();
}

class _TailscaleDetailsState extends ConsumerState<_TailscaleDetails> {
  Timer? _timer;
  Map<String, TsStatus?> _status = const {};
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_poll);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && TickerMode.getValuesNotifier(context).value.enabled) unawaited(_poll());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || !mounted || !ref.read(isRunningProvider)) return;
    _polling = true;
    try {
      final next = <String, TsStatus?>{};
      for (final n in ref.read(subscriptionTailscaleNodesProvider)) {
        next[n] = (await fetchTailscaleStatus(n)).status;
      }
      if (mounted) setState(() => _status = next);
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final nodes = ref.watch(subscriptionTailscaleNodesProvider);
    final running = ref.watch(isRunningProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final n in nodes) ...[
          Builder(
            builder: (context) {
              final st = running ? _status[n] : null;
              final self = st?.self?.addresses.where((a) => !a.contains(':')).firstOrNull;
              return MeSection(
                title: n,
                children: [
                  MeRow(
                    label: '状态',
                    value: !running ? '连接后启动' : (st?.stateText ?? '…'),
                  ),
                  if (self != null) MeRow(label: '本机地址', value: self, mono: true, onTap: () => _copy(self)),
                  if (st != null && st.needsLogin && st.authUrl.isNotEmpty)
                    MeRow(
                      label: '在浏览器里登录',
                      subtitle: '这个节点没有 auth key，登录一次后设备一直保留在 tailnet 里',
                      chevron: true,
                      onTap: () => launchUrl(Uri.parse(st.authUrl), mode: LaunchMode.externalApplication),
                    ),
                  for (final p in st?.peers ?? const <TsPeer>[])
                    MeRow(
                      leading: StatusDot(color: p.online ? mm.good : mm.t3),
                      label: p.name,
                      subtitle: p.addresses.where((a) => !a.contains(':')).join(' · '),
                      value: p.online ? p.pathText : '离线',
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
        ],
        const MeCaption('组网节点由订阅下发（规则把 tailnet 的地址与 MagicDNS 名字交给它）。没有 auth key 的节点要在浏览器里登录一次，之后设备一直保留在 tailnet 里。'),
      ],
    );
  }
}

/// 宽屏「我的」里「组网」一行：点开「组网」页。
class NetworkingRow extends ConsumerWidget {
  const NetworkingRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MeRow(
    label: '组网',
    value: networkingSummary(context, ref),
    chevron: true,
    onTap: () => mePush(context, const NetworkingPage()),
  );
}
