import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

import '../config/direct_profile.dart';
import '../pages/connections/connections_page.dart';
import '../pages/dashboard/dashboard_page.dart';
import '../pages/profiles/profiles_page.dart';
import '../pages/proxies/proxies_page.dart';
import '../pages/settings/settings_page.dart';
import '../panel/account.dart';
import '../panel/client.dart';
import '../panel/realtime.dart';
import '../state/meow_settings.dart';
import '../state/status.dart';
import '../theme/icon_rail.dart';
import '../theme/tokens.dart';
import 'meow_tab.dart';

/// MeowX 壳：手机 = 底部 5 Tab；宽屏 = 左侧 IconRail + 内容。
/// Bettbox 内部的 toPage(PageLabel) 经 currentPageLabelProvider 映射到 Tab；非 Tab 页（日志 / 请求 / 资源 / 脚本）走 push。
class MeowRoot extends ConsumerStatefulWidget {
  const MeowRoot({super.key});

  @override
  ConsumerState<MeowRoot> createState() => _MeowRootState();
}

class _MeowRootState extends ConsumerState<MeowRoot> {
  late final ProviderSubscription<PageLabel> _pageSub;
  late final ProviderSubscription<String?> _profileSub;
  late final ProviderSubscription<bool> _initSub;
  late final ProviderSubscription<(String, String, bool)> _realtimeSub;
  RealtimeClient? _realtime;

  @override
  void initState() {
    super.initState();
    // 主控 RPC 的 User-Agent 带上版本，主控日志与安全事件里认得出是哪个版本的 MeowX
    try {
      PanelClient.userAgent = 'MeowX/${globalState.packageInfo.version} (${system.isAndroid ? 'Android' : 'Windows'})';
    } catch (e) {
      commonPrint.log('set PanelClient.userAgent failed: $e');
    }
    _realtimeSub = ref.listenManual(
      Provider<(String, String, bool)>((r) {
        final a = r.watch(meowSettingProvider.select((s) => s.account));
        return (a.host, a.token, r.watch(isRunningProvider));
      }),
      (prev, next) => _syncRealtime(next),
      fireImmediately: true,
    );
    _profileSub = ref.listenManual(currentProfileIdProvider, (prev, next) => _syncDirectMode(next));
    // 等 Bettbox 把偏好加载完（isInit）再补内置直连档，否则会被随后加载的配置覆盖
    _initSub = ref.listenManual(initProvider, (prev, next) {
      if (next) unawaited(_ensureDirect());
    }, fireImmediately: true);
    _pageSub = ref.listenManual(currentPageLabelProvider, (prev, next) {
      if (prev == next) return;
      final tab = MeowTab.fromPageLabel(next);
      if (tab != null) {
        if (ref.read(meowTabProvider) != tab) {
          ref.read(meowTabProvider.notifier).state = tab;
        }
        return;
      }
      _pushBettboxPage(next);
    });
  }

  /// 切到内置直连档 → mode=direct；不在直连档上而 direct 是当初自动设的 → 恢复 rule。
  /// 按状态对账（启动时也跑一次），不依赖「恰好监听到从直连档切走的那一下」——漏一次就会一直停在直连、所有规则看起来都走 DIRECT。
  void _syncDirectMode(String? profileId) {
    final c = globalState.appController;
    final mode = ref.read(patchClashConfigProvider).mode;
    final settings = ref.read(meowSettingProvider.notifier);
    if (isDirectProfile(profileId)) {
      // 直连档上的 direct 一律算自动的（在它上面手选直连没有意义），旧版本留下的状态也借此补上标记
      if (!ref.read(meowSettingProvider).autoDirectMode) {
        settings.updateState((s) => s.copyWith(autoDirectMode: true));
      }
      if (mode != Mode.direct) c.changeMode(Mode.direct);
    } else if (profileId != null && ref.read(meowSettingProvider).autoDirectMode) {
      settings.updateState((s) => s.copyWith(autoDirectMode: false));
      if (mode == Mode.direct) c.changeMode(Mode.rule);
    }
  }

  Future<void> _ensureDirect() async {
    // 测速方式与 mihomo unified-delay 对齐（HTTPS 延迟 = true，真连接 = false）
    final mode = ref.read(meowSettingProvider).latencyMode;
    if (mode != LatencyMode.tcping && ref.read(patchClashConfigProvider).unifiedDelay != (mode == LatencyMode.url)) {
      ref.read(patchClashConfigProvider.notifier).updateState((c) => c.copyWith(unifiedDelay: mode == LatencyMode.url));
    }
    try {
      final profiles = ref.read(profilesProvider);
      final added = await ensureDirectProfile(profiles);
      if (added != null && mounted) {
        ref.read(profilesProvider.notifier).value = [...profiles, added];
      }
      // 没有任何当前档时以直连档为当前：首页电源键可用，用量卡的菜单可切换
      if (mounted && ref.read(currentProfileIdProvider) == null) {
        ref.read(currentProfileIdProvider.notifier).value = directProfileId;
      }
      if (mounted) _syncDirectMode(ref.read(currentProfileIdProvider));
    } catch (e) {
      commonPrint.log('ensureDirectProfile failed: $e');
    }
  }

  @override
  void dispose() {
    _pageSub.close();
    _profileSub.close();
    _initSub.close();
    _realtimeSub.close();
    _realtime?.stop();
    super.dispose();
  }

  void _syncRealtime((String, String, bool) state) {
    final (host, token, running) = state;
    final want = host.isNotEmpty && token.isNotEmpty && running;
    if (!want) {
      _realtime?.stop();
      _realtime = null;
      return;
    }
    if (_realtime != null && _realtime!.token == token && _realtime!.client.base == PanelClient(host).base) return;
    _realtime?.stop();
    _realtime = RealtimeClient(
      client: ref.read(panelClientProvider) ?? PanelClient(host),
      token: token,
      onEvent: (type, _) {
        if (type != 'subscription_changed') return;
        final current = ref.read(currentProfileProvider);
        if (current != null && current.url.isNotEmpty) {
          globalState.appController.updateProfile(current);
        }
        ref.read(accountActionsProvider).refreshSubscriptions();
      },
    )..start();
  }

  void _pushBettboxPage(PageLabel label) {
    final items = navigation.getItems(openLogs: true, hasProxies: true);
    final item = items.where((e) => e.label == label).firstOrNull;
    if (item == null || !mounted) return;
    BaseNavigator.push(context, item.builder(context));
  }

  void _select(MeowTab tab) {
    if (ref.read(meowTabProvider) == tab) return;
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(meowTabProvider.notifier).state = tab;
    // 同步 Bettbox 的当前页标签：连接页轮询、代理页测速等内部逻辑据此判断可见性
    ref.read(currentPageLabelProvider.notifier).value = tab.pageLabel;
  }

  Widget _page(MeowTab tab) => switch (tab) {
    MeowTab.home => const DashboardPage(),
    MeowTab.proxies => const ProxiesPage(),
    MeowTab.connections => const ConnectionsPage(),
    MeowTab.profiles => const ProfilesPage(),
    MeowTab.settings => const SettingsPage(),
  };

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(meowTabProvider);
    final wide = ref.watch(isWideLayoutProvider);
    final mm = context.mm;
    final content = IndexedStack(
      index: tab.index,
      children: [for (final t in MeowTab.values) _page(t)],
    );

    final Widget body;
    if (wide) {
      // 和代理页标题「N 个节点」同一口径：只数当前模式下可见组里的叶子节点。
      // 之前数的是核心原始组，直连配置下 GLOBAL 里的 DIRECT / REJECT 也算进来，没有代理组也显示 2（#969）
      final proxyCount = ref.watch(currentGroupsStateProvider.select(
        (s) => allLeafProxies(s.value).length,
      ));
      body = Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 16, bottom: 16),
            child: IconRail(
              items: [
                for (final t in MeowTab.values)
                  RailItem(
                    icon: t.icon,
                    label: t.label,
                    badge: switch (t) {
                      MeowTab.proxies => proxyCount,
                      MeowTab.connections => ref.watch(connectionCountProvider),
                      _ => null,
                    },
                  ),
              ],
              selected: tab.index,
              bottomItemIndex: MeowTab.settings.index,
              onSelect: (i) => _select(MeowTab.values[i]),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: content),
        ],
      );
    } else {
      body = content;
    }

    return MeowBackScope(
      child: Scaffold(
        backgroundColor: mm.bg,
        // 手机：底栏是悬浮的液态玻璃胶囊，内容从它下面滚过去（extendBody），各页自己把 MediaQuery.padding.bottom 加进底部留白
        extendBody: !wide,
        body: SafeArea(bottom: wide, child: body),   // 状态栏下留白
        // liquid_glass_widgets：Impeller（Android 10+）上高亮胶囊是真折射 + 高光，按住放大、拖动带果冻形变；
        // Skia（Android 8–9、Windows 3.44）自动降级为模糊 + 双高光，仍可拖动。底轨也用 premium：边缘亮线 + 暗带只有它画得出来。
        bottomNavigationBar: wide
            ? null
            : lg.GlassTabBar.bottom(
                selectedIndex: tab.index,
                onTabSelected: (i) {
                  HapticFeedback.selectionClick();
                  _select(MeowTab.values[i]);
                },
                quality: lg.GlassQuality.premium,
                backgroundQuality: lg.GlassQuality.premium,
                settings: _barGlass(context.isDarkMode),
                selectedIconColor: mm.accent,
                selectedLabelColor: mm.accent,
                unselectedIconColor: mm.t1.withValues(alpha: 0.78),
                unselectedLabelColor: mm.t1.withValues(alpha: 0.78),
                iconSize: 23,
                tabs: [for (final t in MeowTab.values) lg.GlassTab(icon: Icon(t.icon), label: t.label)],
              ),
      ),
    );
  }
}

/// 底栏胶囊的玻璃：对齐 Surfing 底栏（Kyant backdrop 的 LiquidBottomTabs）——
/// 95% 不透明的奶白 / 深灰底 + 边缘亮线与内侧暗带 + 24dp 柔和投影，内容滚到下面时不再透出一片灰；选中块仍是 10% 灰药丸。
/// 暗带（edgeAbsorption）只在 Impeller 的 premium 着色器上好看；Skia（Android 8–9、Windows 窄窗口）降级成 standard 时
/// 它会变成一圈很重的灰色斜面，所以只在支持着色器滤镜时才加。
lg.LiquidGlassSettings _barGlass(bool dark) => lg.LiquidGlassSettings(
      glassColor: dark ? const Color(0xF2242327) : const Color(0xF2FAFAFA),
      bodyMode: lg.GlassBodyMode.clear,
      thickness: 30,
      blur: 20,
      chromaticAberration: 0,
      lightIntensity: 1.0,
      ambientStrength: 1,
      ambientRim: 0.6,
      edgeAbsorption: ui.ImageFilter.isShaderFilterSupported ? 0.18 : 0,
      refractiveIndex: 1.59,
      saturation: 1.5,
      lightAngle: 0.75 * math.pi,
      shadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 24, offset: Offset(0, 4))],
    );

/// 连接数角标（宽屏 IconRail 用），由连接页 / 首页的轮询写入。
final connectionCountProvider = StateProvider<int>((ref) => 0);

/// Android 返回键：先弹子页 → 再回首页 → 最后交给 Bettbox 的退出 / 后台逻辑。
class MeowBackScope extends ConsumerWidget {
  const MeowBackScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!system.isAndroid) return child;
    final backBlock = ref.watch(backBlockProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || backBlock) return;
        final nav = globalState.navigatorKey.currentState;
        if (nav?.userGestureInProgress == true) return;
        if (nav != null && nav.canPop()) {
          nav.pop();
          return;
        }
        if (ref.read(meowTabProvider) != MeowTab.home) {
          ref.read(meowTabProvider.notifier).state = MeowTab.home;
          ref.read(currentPageLabelProvider.notifier).value = PageLabel.dashboard;
          return;
        }
        await globalState.appController.handleBackOrExit();
      },
      child: child,
    );
  }
}
