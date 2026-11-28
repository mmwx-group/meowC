import 'dart:async';

import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/format.dart';
import '../../state/mesh.dart';
import '../../state/mesh_relay.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';
import 'mesh_relay_text.dart';

// 喵窝设备中继的界面（Design/mesh-peer-relay.md §2.4 / §2.6）：设备行的路径文字、设备详情、中继设置。
// 手机 / 电脑本身不当中继：本机那一行没有中继入口，只有上报过中继能力（capable）的设备才有开关。

/// 「x 分钟前」（主控的记录 30 分钟后就不再列出，按分钟写；更久的写成时刻）
String meshAgo(MeshRelayText t, DateTime at, [DateTime? now]) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inMinutes < 1) return t.justNow;
  if (diff.inMinutes < 120) return t.minutesAgo('${diff.inMinutes}');
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${fmtDate(l)} ${two(l.hour)}:${two(l.minute)}';
}

/// 路径的一行字：直连 / 经 X 中继 / 经设备中继 ip:port / 经中继服务器 Y / 空闲；主控的旧记录后面注「x 分钟前」。
String meshPathLabel(MeshRelayText t, MeshPathView v, {DateTime? now}) {
  final base = switch (v.kind) {
    MeshPathKind.direct => t.pathDirect,
    MeshPathKind.idle => t.pathIdle,
    MeshPathKind.peerRelay => v.relayName.isNotEmpty
        ? (v.relayOther ? t.pathViaRelayOther(v.relayName) : t.pathViaRelay(v.relayName))
        : v.relayAddr.isNotEmpty
        ? t.pathViaRelayAddr(v.relayAddr)
        : t.pathViaDeviceRelay,
    MeshPathKind.derp => v.derpName.isNotEmpty
        ? t.pathViaDerp(v.derpName)
        : v.derpRegion.isNotEmpty
        ? t.pathViaDerp(v.derpRegion)
        : t.pathViaDerpPlain,
  };
  final at = v.reportedAt;
  if (v.fromPanel && v.stale && at != null) return '$base · ${meshAgo(t, at, now)}';
  return base;
}

String meshRelayStateLabel(MeshRelayText t, String state) => switch (state) {
  MeshRelayState.disabled => t.relayStateDisabled,
  MeshRelayState.pending => t.relayStatePending,
  MeshRelayState.active => t.relayStateActive,
  MeshRelayState.versionTooOld => t.relayStateVersionTooOld,
  MeshRelayState.error => t.relayStateError,
  MeshRelayState.offline => t.relayStateOffline,
  _ => state,
};

/// 错误码（主控的，或本地先查出来的）→ 给人看的话；认不得的码用主控给的说明。
String meshRelayErrorText(MeshRelayText t, String code, [String panelMessage = '']) => switch (code) {
  'invalid_request' => t.errInvalidRequest,
  'invalid_port' => t.errInvalidPort,
  'invalid_endpoint' => t.errInvalidEndpoint,
  'invalid_ddns_host' => t.errInvalidDdns,
  'share_not_allowed' => t.errShareNotAllowed,
  'device_not_found' => t.errDeviceNotFound,
  'device_relay_disabled' => t.errDisabled,
  'rate_limited' => t.errRateLimited,
  _ => panelMessage.isNotEmpty ? panelMessage : code,
};

/// 设备行 / 详情用：这台设备现在的路径（本机内核优先，主控补名字）。本机自己、或喵窝没在跑时为 null。
MeshPathView? meshDevicePath(MeshState mesh, MeshRelayViewState relay, MeshDevice d, {int? fallbackId}) {
  final self = mesh.selfDevice(fallbackId);
  if (self != null && self.id == d.id) return null;
  final link = self == null
      ? null
      : relay.paths?.linkBetween(selfId: self.id, selfIp: self.ipv4, deviceId: d.id, deviceIp: d.ipv4);
  return meshPathView(local: mesh.pathOf(d), link: link, paths: relay.paths);
}

void _copy(String text) {
  Clipboard.setData(ClipboardData(text: text));
  globalState.showNotifier('已复制 $text');
}

/// 「中继」小标签（本账号的中继设备；开着且在工作时用强调色）
class MeshRelayTag extends StatelessWidget {
  const MeshRelayTag({super.key, this.active = false});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final color = active ? mm.good : mm.t2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(MeshRelayText.of(context).relayTag, style: TextStyle(fontSize: MeowFont.caption2, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// 页面看得见时每 15 秒读一次主控的路径与中继（controller 里合并重复调用），看不见就不读。
mixin MeshRelayPolling<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Timer? _relayTimer;

  void startRelayPolling() {
    Future.microtask(() {
      if (mounted) unawaited(ref.read(meshRelayProvider.notifier).refresh(force: true));
    });
    _relayTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && TickerMode.getValuesNotifier(context).value.enabled) {
        unawaited(ref.read(meshRelayProvider.notifier).refresh());
      }
    });
  }

  void stopRelayPolling() {
    _relayTimer?.cancel();
    _relayTimer = null;
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 设备详情

class MeshDevicePage extends ConsumerStatefulWidget {
  const MeshDevicePage({super.key, required this.device});
  final MeshDevice device;

  @override
  ConsumerState<MeshDevicePage> createState() => _MeshDevicePageState();
}

class _MeshDevicePageState extends ConsumerState<MeshDevicePage> with MeshRelayPolling {
  @override
  void initState() {
    super.initState();
    startRelayPolling();
  }

  @override
  void dispose() {
    stopRelayPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = MeshRelayText.of(context);
    final mm = context.mm;
    final mesh = ref.watch(meshProvider);
    final relay = ref.watch(meshRelayProvider);
    final nodeId = ref.watch(meowSettingProvider.select((s) => s.mesh.nodeId));
    final d = mesh.devices.firstWhere((x) => x.id == widget.device.id, orElse: () => widget.device);
    final self = mesh.selfDevice(nodeId);
    final isSelf = self?.id == d.id;
    final local = isSelf ? null : mesh.pathOf(d);
    final link = self == null || isSelf
        ? null
        : relay.paths?.linkBetween(selfId: self.id, selfIp: self.ipv4, deviceId: d.id, deviceIp: d.ipv4);
    final now = DateTime.now();
    final localView = local == null ? null : meshPathView(local: local, link: link, paths: relay.paths);
    final panelView = link == null ? null : meshPathView(link: link);
    final relayCfg = relay.relays[d.id];
    final showRelay = mesh.deviceRelayEnabled && !isSelf && relay.isRelay(d.id);
    return MeSubPage.list(
      title: d.name,
      children: [
        MeSection(
          title: t.deviceDetails,
          children: [
            if (d.ipv4.isNotEmpty) MeRow(label: t.deviceAddress, value: d.ipv4, mono: true, onTap: () => _copy(d.ipv4)),
            if (!isSelf)
              MeRow(
                label: t.devicePath,
                value: !d.online
                    ? t.offline
                    : localView != null
                    ? meshPathLabel(t, localView, now: now)
                    : t.notInEngine,
              ),
            if (local != null) ...[
              MeRow(label: t.deviceTraffic, value: '↓ ${fmtSize(local.rxBytes)} · ↑ ${fmtSize(local.txBytes)}', mono: true),
              MeRow(
                label: t.deviceLastHandshake,
                value: local.lastHandshake == null ? t.none : meshAgo(t, local.lastHandshake!, now),
              ),
            ],
          ],
        ),
        if (!isSelf && mesh.deviceRelay != null) ...[
          const SizedBox(height: 12),
          MeSection(
            title: t.devicePeerView,
            note: t.devicePeerViewNote,
            children: [
              if (panelView == null || link == null)
                MeRow(label: t.devicePath, value: t.noRecord)
              else
                MeRow(
                  label: meshPathLabel(t, panelView, now: now),
                  subtitle: [
                    switch (link.reportedBy) {
                      'both' => t.reportedByBoth,
                      'a' => t.reportedByOne(link.a.name),
                      'b' => t.reportedByOne(link.b.name),
                      _ => '',
                    },
                    if (link.reportedAt != null) meshAgo(t, link.reportedAt!, now),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  subtitleColor: link.stale ? mm.t3 : null,
                ),
            ],
          ),
        ],
        if (showRelay) ...[
          const SizedBox(height: 12),
          MeSection(
            children: [
              MeRow(
                leading: MeshRelayTag(active: relayCfg?.state == MeshRelayState.active),
                label: t.relaySettings,
                subtitle: t.relaySettingsNote,
                value: meshRelayStateLabel(t, relayCfg?.state ?? relay.paths?.relayOf(d.id)?.state ?? MeshRelayState.disabled),
                chevron: true,
                onTap: () => mePush(context, MeshRelayPage(deviceId: d.id, name: d.name)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 中继设置

class MeshRelayPage extends ConsumerStatefulWidget {
  const MeshRelayPage({super.key, required this.deviceId, required this.name});
  final int deviceId;
  final String name;

  @override
  ConsumerState<MeshRelayPage> createState() => _MeshRelayPageState();
}

class _MeshRelayPageState extends ConsumerState<MeshRelayPage> with MeshRelayPolling {
  final _port = TextEditingController();
  final _ddns = TextEditingController();
  final List<TextEditingController> _endpoints = [];
  bool _enabled = false;
  String _share = 'self';

  /// 用户改过表单（之后读到的主控数据不再覆盖表单）
  bool _dirty = false;
  bool _filled = false;
  bool _saving = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    startRelayPolling();
    final cached = ref.read(meshRelayProvider).relays[widget.deviceId];
    if (cached != null) _fill(cached);
    Future.microtask(() async {
      try {
        final c = await ref.read(meshRelayProvider.notifier).load(widget.deviceId);
        if (mounted && c != null && !_dirty) setState(() => _fill(c));
      } catch (e) {
        if (mounted) setState(() => _error = _errorOf(e));
      }
    });
  }

  @override
  void dispose() {
    stopRelayPolling();
    _port.dispose();
    _ddns.dispose();
    for (final c in _endpoints) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(MeshRelayConfig c) {
    _enabled = c.enabled;
    _share = c.share;
    _port.text = '${c.port}';
    _ddns.text = c.ddnsHost;
    _disposeLater(List.of(_endpoints));
    _endpoints
      ..clear()
      ..addAll([for (final e in c.staticEndpoints) TextEditingController(text: e)]);
    _filled = true;
  }

  /// 换掉的输入框控制器等这一帧画完再释放（TextField 还挂在上面）
  static void _disposeLater(List<TextEditingController> list) {
    if (list.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in list) {
        c.dispose();
      }
    });
  }

  void _touch() {
    _dirty = true;
    _notice = null;
  }

  String _errorOf(Object e) {
    final t = MeshRelayText.of(context);
    if (e is MeshRelayApiException) return meshRelayErrorText(t, e.code, e.message);
    return '$e';
  }

  Future<void> _save(MeshRelayConfig base) async {
    if (_saving) return;
    final t = MeshRelayText.of(context);
    final port = int.tryParse(_port.text.trim());
    final endpoints = [for (final c in _endpoints) c.text.trim()]..removeWhere((e) => e.isEmpty);
    final ddns = _ddns.text.trim();
    final bad = validateMeshRelayForm(port: port, staticEndpoints: endpoints, ddnsHost: ddns);
    if (bad != null) {
      setState(() => _error = meshRelayErrorText(t, bad));
      return;
    }
    final canShare = ref.read(meshProvider).deviceRelay?.canShare == true;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    final next = base.copyWith(enabled: _enabled, port: port, staticEndpoints: endpoints, ddnsHost: ddns, share: canShare ? _share : 'self');
    try {
      final saved = await ref.read(meshRelayProvider.notifier).save(next);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        if (saved != null) _fill(saved);
        _notice = t.saved;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _errorOf(e);
        // 非管理员设了共享给所有人：改回仅本账号
        if (e is MeshRelayApiException && e.code == 'share_not_allowed') _share = 'self';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = MeshRelayText.of(context);
    final mm = context.mm;
    final mesh = ref.watch(meshProvider);
    final relay = ref.watch(meshRelayProvider);
    final cfg = relay.relays[widget.deviceId];
    final info = relay.paths?.relayOf(widget.deviceId);
    ref.listen<MeshRelayConfig?>(meshRelayProvider.select((s) => s.relays[widget.deviceId]), (_, next) {
      if (next != null && !_filled && !_dirty) setState(() => _fill(next));
    });
    final base = cfg ?? MeshRelayConfig(deviceId: widget.deviceId);
    final canShare = mesh.deviceRelay?.canShare == true;
    final capable = cfg?.capable == true;
    final now = DateTime.now();
    final state = cfg?.state ?? info?.state ?? MeshRelayState.disabled;
    final stuck = cfg != null && meshRelayPendingStuck(cfg, ref.read(meshRelayProvider.notifier).pendingSince(widget.deviceId), now);
    final port = int.tryParse(_port.text.trim()) ?? base.port;
    return MeSubPage.list(
      title: t.relaySettings,
      children: [
        MeSection(
          title: widget.name,
          children: [
            MeRow(
              label: t.relayStatus,
              subtitle: [
                if (cfg != null && cfg.message.isNotEmpty) cfg.message,
                if (cfg != null && cfg.tailscaleVersion.isNotEmpty) t.relayVersion(cfg.tailscaleVersion),
              ].join(' · ').ifEmpty,
              subtitleMaxLines: null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(color: switch (state) {
                    MeshRelayState.active => mm.good,
                    MeshRelayState.error || MeshRelayState.versionTooOld => mm.slow,
                    _ => mm.t3,
                  }),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      meshRelayStateLabel(t, state),
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2),
                    ),
                  ),
                ],
              ),
            ),
            if (stuck)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 14, 10),
                child: Text(t.relayPendingStuck, style: TextStyle(fontSize: MeowFont.caption, color: mm.slow)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!capable)
          MeCaption(t.relayNotCapable)
        else ...[
          MeSection(
            children: [
              MeSwitchRow(
                label: t.relaySwitch,
                subtitle: t.relaySettingsNote,
                value: _enabled,
                onChanged: _saving ? null : (v) => setState(() {
                  _touch();
                  _enabled = v;
                }),
              ),
              _Field(
                label: t.relayPort,
                note: t.relayPortNote,
                controller: _port,
                keyboardType: TextInputType.number,
                onChanged: () => setState(_touch),
              ),
              _EndpointsField(
                t: t,
                controllers: _endpoints,
                onChanged: () => setState(_touch),
              ),
              _Field(
                label: t.relayDdns,
                note: t.relayDdnsNote,
                controller: _ddns,
                hint: 'home.example.com',
                onChanged: () => setState(_touch),
              ),
              if (canShare)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(
                    children: [
                      Expanded(child: Text(t.relayShare, style: TextStyle(fontSize: MeowFont.body, fontWeight: FontWeight.w700, color: mm.t1))),
                      SizedBox(
                        width: 200,
                        child: MeowSegment<String>(
                          items: [('self', t.relayShareSelf), ('all', t.relayShareAll)],
                          value: _share,
                          onChanged: (v) => setState(() {
                            _touch();
                            _share = v;
                          }),
                          onCard: true,
                          height: 34,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: TextStyle(fontSize: MeowFont.caption, color: mm.slow)),
                  ),
                if (_notice != null && _error == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_notice!, style: TextStyle(fontSize: MeowFont.caption, color: mm.good)),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saving ? null : () => unawaited(_save(base)),
                    child: _saving
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(t.save),
                  ),
                ),
              ],
            ),
          ),
          if (_enabled) MeCaption(t.relayPortForward('$port')),
        ],
        const SizedBox(height: 12),
        MeSection(
          title: t.relaySessions,
          children: [
            if (info == null || (info.sessions.isEmpty && info.unmatchedSessions == 0))
              MeRow(label: t.relayNoSessions)
            else ...[
              for (final s in info.sessions)
                MeRow(
                  label: '${_endName(t, s.a)} ⇄ ${_endName(t, s.b)}',
                  subtitle: s.since == null ? null : meshAgo(t, s.since!, now),
                  value: fmtSize(s.bytes),
                  mono: true,
                ),
              if (info.unmatchedSessions > 0) MeRow(label: t.relayUnmatched('${info.unmatchedSessions}')),
            ],
          ],
        ),
      ],
    );
  }

  static String _endName(MeshRelayText t, MeshPathEnd e) => e.isOther || e.name.isEmpty ? t.otherUser : e.name;
}

extension on String {
  String? get ifEmpty => isEmpty ? null : this;
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.note,
    required this.controller,
    required this.onChanged,
    this.hint,
    this.keyboardType,
  });

  final String label;
  final String note;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final String? hint;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: TextStyle(fontSize: MeowFont.body, fontWeight: FontWeight.w700, color: mm.t1)),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: keyboardType ?? TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            style: MeowFont.mono(size: MeowFont.footnote, color: mm.t1),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(isDense: true, hintText: hint),
          ),
          const SizedBox(height: 4),
          Text(note, style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
        ],
      ),
    );
  }
}

/// 静态地址（至多 4 个）：每个一行输入框 + 删除，下面「添加地址」
class _EndpointsField extends StatelessWidget {
  const _EndpointsField({required this.t, required this.controllers, required this.onChanged});

  final MeshRelayText t;
  final List<TextEditingController> controllers;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.relayEndpoints, style: TextStyle(fontSize: MeowFont.body, fontWeight: FontWeight.w700, color: mm.t1)),
          for (var i = 0; i < controllers.length; i++)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controllers[i],
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: MeowFont.mono(size: MeowFont.footnote, color: mm.t1),
                    onChanged: (_) => onChanged(),
                    decoration: const InputDecoration(isDense: true, hintText: '1.2.3.4:40000'),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.remove_circle_outline_rounded, color: mm.t2, size: 20),
                  onPressed: () {
                    final c = controllers.removeAt(i);
                    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
                    onChanged();
                  },
                ),
              ],
            ),
          if (controllers.length < MeshRelayConfig.maxStaticEndpoints)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  controllers.add(TextEditingController());
                  onChanged();
                },
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(t.relayAddEndpoint),
              ),
            ),
          Text(t.relayEndpointsNote, style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
        ],
      ),
    );
  }
}
