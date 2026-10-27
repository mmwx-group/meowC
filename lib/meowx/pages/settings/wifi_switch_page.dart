import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

import '../../state/meow_settings.dart';
import '../../state/wifi_switch.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';

/// 入口行 / 宽屏分组里的摘要。
String wifiSwitchSummary(MeowSettings s, {required bool paused}) {
  if (!s.wifiSwitchEnabled) return '未开启';
  final parts = [
    s.wifiRules.isEmpty ? '没有规则' : '${s.wifiRules.length} 条规则',
    if (paused) '已暂停',
  ];
  return parts.join(' · ');
}

/// 宽屏「我的」页的分组：总开关 + 进规则页的入口。
class WifiSwitchRows extends ConsumerWidget {
  const WifiSwitchRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(meowSettingProvider);
    final paused = ref.watch(wifiPausedProvider);
    return MeRows(
      children: [
        MeSwitchRow(
          label: 'Wi-Fi 智能开关',
          subtitle: '连上指定 Wi-Fi 时断开代理，离开后自动连上',
          value: s.wifiSwitchEnabled,
          onChanged: (v) => setWifiSwitchEnabled(ref, v),
        ),
        MeRow(
          label: '规则与权限',
          value: wifiSwitchSummary(s, paused: paused),
          chevron: true,
          onTap: () => mePush(context, const WifiSwitchPage()),
        ),
      ],
    );
  }
}

/// 「我的 › Wi-Fi 智能开关」：总开关、当前网络与定位权限引导、SSID 规则、其它网络的动作。
class WifiSwitchPage extends ConsumerStatefulWidget {
  const WifiSwitchPage({super.key});

  @override
  ConsumerState<WifiSwitchPage> createState() => _WifiSwitchPageState();
}

class _WifiSwitchPageState extends ConsumerState<WifiSwitchPage> with WidgetsBindingObserver {
  /// 定位权限 / 定位服务（页面自己读：总开关关着时控制器不读网络）
  WifiNetworkState? _perm;

  /// 页面自己读到的当前 Wi-Fi 名称（还没有规则时控制器不读名称，「添加当前 Wi-Fi」靠它）
  String? _pageSsid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 从系统设置（授权 / 打开定位）回来时重读
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!system.isAndroid) return;
    try {
      // 先让插件按最新权限重挂网络回调（在系统设置里刚给的权限，回调还没挂上）
      await wifiSsidManager.checkPermission();
      final st = await wifiSsidManager.getNetworkState();
      String? ssid;
      if (st.wifi && st.fineLocation && st.locationEnabled) {
        ssid = await wifiSsidManager.getSsid().timeout(const Duration(seconds: 5), onTimeout: () => null);
      }
      if (mounted) {
        setState(() {
          _perm = st;
          _pageSsid = ssid == null || normalizeSsid(ssid).isEmpty ? null : normalizeSsid(ssid);
        });
      }
    } catch (e) {
      commonPrint.log('wifi permission check failed: $e');
    }
    await ref.read(wifiSwitchProvider).refresh();
  }

  Future<void> _requestLocation({required bool background}) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(background ? '改为「始终允许」' : '需要定位权限'),
        content: Text(
          background
              ? '锁屏或 MeowX 不在前台时，安卓只把 Wi-Fi 名称告诉定位权限是「始终允许」的 App。'
                    '接下来会打开系统设置，请在「位置信息」里选「始终允许」。'
              : '安卓只把当前 Wi-Fi 的名称告诉有定位权限的 App。MeowX 只用它读 Wi-Fi 名称来匹配规则，不获取、不上传位置。\n\n'
                    '系统弹窗里选「使用时允许」；之后最好再改成「始终允许」，否则 App 在后台时读不到名称、规则不生效。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('继续')),
        ],
      ),
    );
    if (go != true) return;
    try {
      final res = await wifiSsidManager.requestPermission();
      // 被拒绝过且勾了「不再询问」，系统不再弹窗：只能去应用设置里开
      if (res == WifiSsidPermission.permanentlyDenied) await wifiSsidManager.openAppSettings();
    } on PlatformException catch (e) {
      commonPrint.log('wifi requestPermission failed: $e');
      await wifiSsidManager.openAppSettings();
    }
    await _refresh();
  }

  Future<void> _edit({int? index, String? suggested}) async {
    final rules = ref.read(meowSettingProvider).wifiRules;
    final existing = index == null ? null : rules[index];
    final input = TextEditingController(text: existing?.ssid ?? suggested ?? '');
    var action = existing?.action ?? MeowWifiAction.disconnect;
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          title: Text(existing == null ? '添加 Wi-Fi 规则' : '编辑 Wi-Fi 规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: input,
                autofocus: existing == null && suggested == null,
                autocorrect: false,
                onChanged: (_) => setState(() => err = null),
                decoration: InputDecoration(
                  labelText: 'Wi-Fi 名称（SSID）',
                  helperText: '区分大小写，与系统里显示的一致',
                  errorText: err,
                ),
              ),
              const SizedBox(height: 14),
              Text('连上时', style: TextStyle(fontSize: MeowFont.caption, color: ctx.mm.t2)),
              const SizedBox(height: 6),
              MeowSegment<MeowWifiAction>(
                height: 38,
                fontSize: 13,
                onCard: true,
                items: [for (final a in const [MeowWifiAction.disconnect, MeowWifiAction.connect]) (a, a.label)],
                value: action,
                onChanged: (v) => setState(() => action = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final ssid = normalizeSsid(input.text);
                if (ssid.isEmpty) {
                  setState(() => err = '请输入 Wi-Fi 名称');
                  return;
                }
                final rule = MeowWifiRule(ssid: ssid, action: action);
                updateWifiRules(ref, (list) {
                  if (index == null) return upsertWifiRule(list, rule);
                  // 改名撞上另一条：并成一条
                  final rest = [...list]..removeAt(index);
                  final dup = rest.indexWhere((r) => r.ssid == ssid);
                  if (dup >= 0) return [...rest]..[dup] = rule;
                  return [...rest]..insert(index, rule);
                });
                Navigator.of(ctx).pop();
              },
              child: Text(existing == null ? '添加' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final s = ref.watch(meowSettingProvider);
    final status = ref.watch(wifiSwitchStatusProvider);
    final paused = ref.watch(wifiPausedProvider);
    final snap = status.snapshot;
    final perm = _perm;
    final needSsid = wifiRulesNeedSsid(s.wifiRules);
    final currentSsid = snap?.ssid ?? _pageSsid;
    final canAddCurrent = currentSsid != null && !s.wifiRules.any((r) => r.ssid == currentSsid);

    Widget fix(String label, String subtitle, String button, VoidCallback onTap) => MeRow(
      label: label,
      subtitle: subtitle,
      subtitleColor: mm.slow,
      trailing: MePill(label: button, height: 34, onTap: onTap),
      onTap: onTap,
    );

    final permRows = <Widget>[
      if (perm == null)
        const MeRow(label: '定位权限', value: '读取中…')
      else if (!perm.fineLocation)
        fix('定位权限', '没有定位权限，读不到 Wi-Fi 名称，规则不会生效', '去授权', () => _requestLocation(background: false))
      else if (!perm.locationEnabled)
        fix('定位服务', '系统定位服务关着，读不到 Wi-Fi 名称', '去打开', () => wifiSsidManager.openLocationSettings())
      else if (!perm.backgroundLocation)
        fix('后台读取', '现在是「使用时允许」：锁屏或 App 在后台时读不到名称、不会切换', '始终允许', () => _requestLocation(background: true))
      else
        const MeRow(label: '定位权限', value: '始终允许'),
    ];

    return MeSubPage.list(
      title: 'Wi-Fi 智能开关',
      actions: [
        RoundGlassButton(icon: Icons.add_rounded, filled: true, tooltip: '添加规则', onTap: () => _edit(suggested: currentSsid)),
      ],
      children: [
        MeSection(
          children: [
            MeSwitchRow(
              label: 'Wi-Fi 智能开关',
              subtitle: '连上指定 Wi-Fi 时断开代理，离开后自动连上',
              value: s.wifiSwitchEnabled,
              onChanged: (v) => setWifiSwitchEnabled(ref, v),
            ),
          ],
        ),
        if (s.wifiSwitchEnabled)
          MeSection(
            title: '当前网络',
            children: [
              MeRow(
                label: snap?.label ?? '读取中…',
                subtitle: status.note ?? (status.manualOverride ? '你手动开关过，换到别的网络之前不自动切换' : null),
                subtitleColor: snap?.ssidUnknown ?? false ? mm.slow : null,
                value: paused ? '代理已暂停' : null,
              ),
              if (needSsid) ...permRows,
            ],
          ),
        MeSection(
          title: '规则',
          note: '从上往下第一条命中',
          children: [
            if (s.wifiRules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Text(
                  '例如家里、公司的 Wi-Fi 设成「断开代理」。点右上角「+」添加',
                  style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2),
                ),
              ),
            for (final (i, r) in s.wifiRules.indexed)
              _RuleRow(
                rule: r,
                current: r.ssid == currentSsid,
                onTap: () => _edit(index: i),
                onDelete: () => updateWifiRules(ref, (list) => [...list]..removeAt(i)),
              ),
            if (canAddCurrent)
              MeRow(
                label: '添加当前 Wi-Fi「$currentSsid」',
                leading: Icon(Icons.add_rounded, size: 20, color: mm.accent),
                onTap: () => _edit(suggested: currentSsid),
              ),
          ],
        ),
        MeSection(
          children: [
            MePickerRow<MeowWifiAction>(
              label: '其它网络',
              value: s.wifiOtherAction,
              values: MeowWifiAction.values,
              text: (v) => v.label,
              onChanged: (v) => ref.read(meowSettingProvider.notifier).updateState((x) => x.copyWith(wifiOtherAction: v)),
            ),
          ],
        ),
        const MeCaption(
          '「其它网络」= 没有命中规则的 Wi-Fi、蜂窝和有线网络。只在网络变化时切换；你手动开关之后，换到别的网络之前不再自动切换。\n'
          '「断开代理」是暂停：通知栏保留「已挂起」，离开后自动恢复；你自己关掉的代理不会被自动打开。\n'
          '安卓要有定位权限并打开定位服务才读得到 Wi-Fi 名称（MeowX 不读位置）；读不到名称时不切换。',
        ),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.rule, required this.current, required this.onTap, required this.onDelete});
  final MeowWifiRule rule;
  final bool current;
  final VoidCallback onTap, onDelete;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 2, 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.ssid,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t1),
                  ),
                  Text(
                    current ? '${rule.action.label} · 当前连着' : rule.action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: MeowFont.footnote,
                      color: rule.action == MeowWifiAction.disconnect ? mm.slow : mm.good,
                    ),
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
      ),
    );
  }
}
