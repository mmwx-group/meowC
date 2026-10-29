import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/pages/proxies/group_widgets.dart';
import 'package:bett_box/meowx/pages/proxies/node_grid.dart';
import 'package:bett_box/meowx/pages/proxies/proxies_page.dart';
import 'package:bett_box/meowx/panel/account.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/badges.dart';
import 'package:bett_box/meowx/theme/motion.dart';
import 'package:bett_box/meowx/theme/unlock_badge.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/haptics.dart';

// 各 Notifier 换成不碰 globalState / 核心的替身，页面本身的布局保持真实。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Groups extends Groups {
  _Groups(this.initial);
  final List<Group> initial;

  @override
  List<Group> build() => initial;

  @override
  void onUpdate(List<Group> value) {}
}

class _Style extends ProxiesStyleSetting {
  @override
  ProxiesStyle build() => const ProxiesStyle();

  @override
  void onUpdate(ProxiesStyle value) {}
}

class _PageLabel extends CurrentPageLabel {
  @override
  PageLabel build() => PageLabel.proxies;

  @override
  void onUpdate(PageLabel value) {}
}

const _url = 'https://test.example/204';
const _longName = '🇭🇰 香港 01 · IEPL 专线（名字很长很长很长的节点）';

const _nodes = [
  Proxy(name: _longName, type: 'Vless'),
  Proxy(name: '香港 02 · BGP', type: 'Trojan'),
  Proxy(name: '东京 01 · IIJ', type: 'Hysteria2'),
  Proxy(name: '大阪 02', type: 'Shadowsocks'),
  Proxy(name: '新加坡 01', type: 'Vmess'),
  Proxy(name: '台北 01 · HiNet', type: 'AnyTLS'),
  Proxy(name: '洛杉矶 01 · 9929', type: 'Miu'),
  Proxy(name: '圣何塞 02', type: 'Trojan'),
  Proxy(name: '首尔 01', type: 'Shadowsocks'),
  Proxy(name: '法兰克福 01', type: 'Mieru'),
  Proxy(name: '伦敦 01', type: 'Trojan'),
  Proxy(name: 'Premium-Node-Without-Region-12345', type: 'Vless'),
];

final _groups = [
  Group(
    name: '节点选择',
    type: GroupType.Selector,
    now: '自动选择',
    testUrl: _url,
    all: [const Proxy(name: '自动选择', type: 'URLTest'), ..._nodes.take(3), const Proxy(name: 'DIRECT', type: 'Direct')],
  ),
  Group(name: '自动选择', type: GroupType.URLTest, now: _longName, testUrl: _url, all: _nodes),
  Group(name: 'AI 服务（名字也很长的一个代理组）', type: GroupType.Fallback, now: '洛杉矶 01 · 9929', testUrl: _url, all: _nodes.sublist(4, 9)),
  Group(name: '负载均衡', type: GroupType.LoadBalance, now: '', testUrl: _url, all: _nodes.sublist(0, 4)),
];

const _delays = <String, int?>{
  _longName: 38,
  '香港 02 · BGP': 152,
  '东京 01 · IIJ': 61,
  '大阪 02': 12345,
  '新加坡 01': 0,   // 测试中
  '台北 01 · HiNet': null,   // 没测过
  '洛杉矶 01 · 9929': 148,
  '伦敦 01': -1,   // 超时
  '自动选择': 38,
};

NodeMedal _medal(String name, String medal) => NodeMedal(
  name: name,
  medal: medal,
  routes: const [ReturnRoute(carrier: 'telecom', region: '广东', routeType: 'CN2 GIA', gold: true)],
);

NodeUnlocks _unlock(String name, String status) =>
    NodeUnlocks(name: name, entries: [UnlockEntry(service: 'netflix', status: status, region: 'HK')]);

Profile _profile({String? current = '自动选择', Map<String, String> selected = const {'节点选择': '自动选择'}}) => Profile(
  id: 'p1',
  label: '测试订阅',
  autoUpdateDuration: const Duration(days: 1),
  currentGroupName: current,
  selectedMap: selected,
);

/// 测试中途要改的当前订阅（点节点 / 换组在真实界面里就是换一个 Profile 对象）。
final _liveProfile = StateProvider<Profile?>((ref) => null);

List<Override> _overrides({
  bool wide = false,
  bool twoPane = false,
  ProxyLayout layout = ProxyLayout.tabs,
  NodeCardSize size = NodeCardSize.standard,
  Profile? profile,
  bool live = false,
  List<Group>? groups,
}) {
  final gs = groups ?? _groups;
  return [
    isWideLayoutProvider.overrideWithValue(wide),
    isTwoPaneProvider.overrideWithValue(twoPane),
    if (live) ...[
      _liveProfile.overrideWith((ref) => profile),
      currentProfileProvider.overrideWith((ref) => ref.watch(_liveProfile)),
      // 真实实现经 appController 写进订阅；这里直接换当前订阅对象，效果相同
      rememberGroupProvider.overrideWith(
        (ref) => (name) => ref.read(_liveProfile.notifier).update((p) => p?.copyWith(currentGroupName: name)),
      ),
    ] else ...[
      currentProfileProvider.overrideWithValue(profile),
      rememberGroupProvider.overrideWithValue((_) {}),
    ],
    currentGroupsStateProvider.overrideWithValue(GroupsState(value: gs)),
    groupsProvider.overrideWith(() => _Groups(gs)),
    currentPageLabelProvider.overrideWith(_PageLabel.new),
    proxiesStyleSettingProvider.overrideWith(_Style.new),
    meowSettingProvider.overrideWith(() => _Meow(MeowSettings(proxyLayout: layout, nodeCardSize: size))),
    proxyMetaProvider.overrideWithValue(const {_longName: ProxyMeta(type: 'vless', reality: true, flow: 'xtls-rprx-vision')}),
    medalsProvider.overrideWith((ref) => {_longName: _medal(_longName, 'gold'), '东京 01 · IIJ': _medal('东京 01 · IIJ', 'silver')}),
    unlocksProvider.overrideWith((ref) => {_longName: _unlock(_longName, 'yes'), '香港 02 · BGP': _unlock('香港 02 · BGP', 'no')}),
    // 延迟按（成员, 测试地址）逐个给：真 provider 要读 globalState 里的测速表
    for (final name in {for (final g in gs) ...g.all.map((p) => p.name)})
      getDelayProvider(proxyName: name, testUrl: _url).overrideWith((ref) => _delays[name]),
  ];
}

/// 按给定窗口尺寸与文字缩放摆出来（溢出、intrinsic 断言都会作为异常让用例失败）。
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required List<Override> overrides,
  double textScale = 1.4,
  double bottomInset = 0,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        home: const Scaffold(body: ProxiesPage()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 点一下测速 / 节点。测速与切节点本身要 appController 和核心，测试里都没有，点下去之后它们抛的错在这里接住：这几条只看震动。
Future<void> _tapAction(WidgetTester tester, Finder finder) async {
  await runZonedGuarded(() async {
    await tester.tap(finder);
    await tester.pump();
  }, (_, _) {});
}

/// 网格的列数是布局阶段按网格自己的宽度算的，从渲染对象上取。
int _gridColumns(WidgetTester tester) {
  final grid = tester.renderObject<RenderSliverGrid>(find.byType(SliverGrid).first);
  return (grid.gridDelegate.getLayout(grid.constraints) as SliverGridRegularTileLayout).crossAxisCount;
}

void main() {
  testWidgets('手机 · 单组布局：窄屏 1.4 倍字号不溢出；标题 / 组按钮 / 摘要 / 节点格', (tester) async {
    await _pump(
      tester,
      size: const Size(320, 1600),
      overrides: _overrides(profile: _profile()),
      bottomInset: 96,
    );

    expect(find.text('节点'), findsOneWidget);
    expect(find.text('4 个代理组 · 13 个节点'), findsOneWidget);   // 12 个节点 + DIRECT，嵌套的组不算
    // 不再有横向组标签 / 左右滑动换组，只有一个组按钮
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(GroupPickerButton), findsOneWidget);
    expect(find.text('12 个成员 · 共 4 个组'), findsOneWidget);
    expect(find.text('切换'), findsOneWidget);
    // 停在订阅记下的组（自动选择）：摘要是 url-test 组的，带「自动选择」开关
    expect(find.byType(GroupSummary), findsOneWidget);
    expect(find.text('url-test'), findsNWidgets(2));   // 组按钮 + 摘要
    expect(find.text('12 个成员 · 自动'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('按延迟自动切换'), findsOneWidget);
    // 测速钮与组延迟合成一个：测过就在钮上显示当前节点的延迟（没测过才是「⚡ 测速」）
    expect(find.descendant(of: find.byType(GroupTestButton), matching: find.text('38')), findsOneWidget);
    // 摘要里的当前节点和节点格：名字连国旗原样显示（和代理组名一个画法），不画地区码标签
    expect(find.byType(RegionTag), findsNothing);
    expect(find.text(_longName), findsNWidgets(2));
    expect(find.text('Premium-Node-Without-Region-12345'), findsOneWidget);
    expect(find.text('vless · reality · vision'), findsOneWidget);
    expect(find.text('hy2'), findsOneWidget);
    // 延迟四态：有值 / 测试中 / 没测过 / 超时
    expect(find.text('38'), findsNWidgets(2));   // 摘要的测速钮 + 格子（延迟只写数字，同 iOS）
    expect(find.text('12345'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    expect(find.text('超时'), findsOneWidget);
    // 奖牌 / 解锁：摘要里当前节点的一份 + 格子里的
    expect(find.byType(MedalBadge), findsNWidgets(3));
    expect(find.byType(UnlockBadge), findsNWidgets(3));
    expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
    // 标准卡片手机上两列；悬浮底栏的高度让进了网格底部留白
    expect(_gridColumns(tester), 2);
    final gridPad = tester.widget<SliverPadding>(
      find.ancestor(of: find.byType(NodeSliverGrid), matching: find.byType(SliverPadding)).first,
    );
    expect(gridPad.padding, const EdgeInsets.fromLTRB(16, 12, 16, 12 + 96));
  });

  testWidgets('排序：「节点视图」菜单里选延迟 / 名称，节点格跟着重排并记下；选默认回到订阅顺序', (tester) async {
    await _pump(tester, size: const Size(412, 1600), overrides: _overrides(profile: _profile()), textScale: 1);
    final container = ProviderScope.containerOf(tester.element(find.byType(ProxiesPage)));
    final names = {for (final p in _nodes) p.name};
    final subscription = [for (final p in _nodes) p.name];
    // 节点格里的名字，按网格顺序（摘要里的当前节点不算）
    List<String> order() => [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(NodeSliverGrid), matching: find.byType(Text))))
        if (names.contains(t.data)) t.data!,
    ];
    // 点了菜单项先亮选中块，menuAutoClose 之后才关菜单、回传
    Future<void> pick(String item) async {
      await tester.tap(find.byTooltip('节点视图'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pump(MeowMotion.menuAutoClose);
      await tester.pumpAndSettle();
    }

    expect(order(), subscription);

    // 延迟：有读数的从低到高（12345 也是读数），测试中 / 没测过的按原顺序接后面，超时垫底
    await pick('延迟');
    expect(container.read(proxiesStyleSettingProvider).sortType, ProxiesSortType.delay);
    expect(order(), [
      _longName,
      '东京 01 · IIJ',
      '洛杉矶 01 · 9929',
      '香港 02 · BGP',
      '大阪 02',
      '新加坡 01',
      '台北 01 · HiNet',
      '圣何塞 02',
      '首尔 01',
      '法兰克福 01',
      'Premium-Node-Without-Region-12345',
      '伦敦 01',
    ]);

    // 名称：中文按拼音（大阪 daban、东京 dongjing、法兰克福 falankefu …），国旗开头的排在最后
    await pick('名称');
    expect(container.read(proxiesStyleSettingProvider).sortType, ProxiesSortType.name);
    expect(order().take(3), ['大阪 02', '东京 01 · IIJ', '法兰克福 01']);
    expect(order().last, _longName);

    await pick('默认');
    expect(order(), subscription);
  });

  testWidgets('手机 · 单组布局：已固定的 url-test 组 / 大卡片单列 / 深色', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 1600),
      overrides: _overrides(
        profile: _profile(selected: const {'节点选择': '自动选择', '自动选择': '东京 01 · IIJ'}),
        size: NodeCardSize.large,
      ),
      brightness: Brightness.dark,
    );

    expect(find.text('12 个成员 · 已固定'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('已手动固定，打开恢复'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    expect(_gridColumns(tester), 1);
  });

  testWidgets('手机 · 单组布局：select 组没有「自动选择」开关，嵌套组 / 内置策略成员的副标题', (tester) async {
    await _pump(
      tester,
      size: const Size(412, 892),
      overrides: _overrides(profile: _profile(current: null)),
      textScale: 1,
    );

    // 没记过停在哪个组 → 第一个组
    expect(find.text('select'), findsNWidgets(2));   // 组按钮 + 摘要
    expect(find.text('5 个成员'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('代理组 · url-test'), findsOneWidget);
    expect(find.text('直连'), findsOneWidget);
    expect(find.byIcon(Icons.layers_rounded), findsOneWidget);
  });

  testWidgets('手机 · 列表布局：组卡收起，点开后接「自动选择」行与节点网格', (tester) async {
    await _pump(
      tester,
      size: const Size(320, 1600),
      overrides: _overrides(profile: _profile(), layout: ProxyLayout.list),
      bottomInset: 96,
    );

    expect(find.byType(GroupCard), findsNWidgets(4));
    expect(find.byType(GroupPickerButton), findsNothing);
    expect(find.byType(NodeSliverGrid), findsNothing);
    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('load-balance'), findsOneWidget);
    // 负载均衡组没有「当前选中」：不画第二行（同 iOS）
    expect(find.text('—'), findsNothing);

    // 展开动画从高度 0 开始（这一帧网格还不在屏上），播完才整段露出
    await tester.tap(find.text('url-test'));
    await tester.pumpAndSettle();
    expect(find.byType(NodeSliverGrid), findsOneWidget);
    expect(find.byType(AutoSelectToggle), findsOneWidget);
    expect(find.text('大阪 02'), findsOneWidget);

    // 收起：节点卡倒序淡出、容器收完之后才拆掉
    await tester.tap(find.text('url-test'));
    await tester.pump();
    expect(find.byType(NodeSliverGrid), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(NodeSliverGrid), findsNothing);
  });

  testWidgets('手机 · 列表布局：组卡头部的测速钮带组延迟（30 高、至少 40 宽），箭头是 40×30 胶囊，点箭头胶囊同样展开 / 收起', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 1600),
      overrides: _overrides(profile: _profile(), layout: ProxyLayout.list),
    );
    final card = find.widgetWithText(GroupCard, 'url-test');
    final test = find.descendant(of: card, matching: find.byType(GroupTestButton));
    expect(test, findsOneWidget);
    expect(tester.getSize(test).height, MeowChip.height);
    expect(tester.getSize(test).width, greaterThanOrEqualTo(MeowChip.width));
    // 延迟在测速钮上，组卡第二行不再重复
    expect(find.descendant(of: test, matching: find.text('38')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('38')), findsOneWidget);
    Finder chevron() => find.descendant(of: card, matching: find.byType(MeowChip));
    expect(chevron(), findsOneWidget);
    expect(tester.getSize(chevron()), const Size(MeowChip.width, MeowChip.height));

    await tester.tap(chevron());
    await tester.pumpAndSettle();
    expect(find.byType(NodeSliverGrid), findsOneWidget);
    await tester.tap(chevron());
    await tester.pumpAndSettle();
    expect(find.byType(NodeSliverGrid), findsNothing);
  });

  testWidgets('手机 · 列表布局：展开上面的组，下面已展开的网格原样留着（不拆掉重建）', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 2400),
      overrides: _overrides(profile: _profile(), layout: ProxyLayout.list),
      textScale: 1,
    );
    final lower = find.byWidgetPredicate((w) => w is NodeSliverGrid && w.group.type == GroupType.Fallback);

    await tester.tap(find.text('fallback'));
    await tester.pumpAndSettle();
    final before = tester.element(lower);
    final cell = tester.element(find.text('洛杉矶 01 · 9929').last);

    // 在它上面插进一行「自动选择」和一张网格
    await tester.tap(find.text('url-test'));
    await tester.pumpAndSettle();
    expect(find.byType(NodeSliverGrid), findsNWidgets(2));
    expect(identical(tester.element(lower), before), isTrue);
    expect(identical(tester.element(find.text('洛杉矶 01 · 9929').last), cell), isTrue);

    await tester.tap(find.text('url-test'));
    await tester.pumpAndSettle();
    expect(find.byType(NodeSliverGrid), findsOneWidget);
    expect(identical(tester.element(lower), before), isTrue);
  });

  testWidgets('手机 · 单组布局：点组按钮弹出选组面板，选组后网格换成该组并记下（窄屏 1.4 倍字号）', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 800),
      overrides: _overrides(profile: _profile(), live: true),
      bottomInset: 96,
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ProxiesPage)));
    expect(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)).group.name, '自动选择');

    await tester.tap(find.byType(GroupPickerButton));
    await tester.pumpAndSettle();
    // 手机是底部弹出面板：标题 + 每组一张组卡（带成员数），当前组高亮
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('选择代理组'), findsOneWidget);
    final cards = find.descendant(of: find.byType(BottomSheet), matching: find.byType(GroupCard));
    expect(cards, findsNWidgets(4));
    expect(
      tester.widgetList<GroupCard>(cards).where((c) => c.selected).map((c) => c.group.name),
      ['自动选择'],
    );
    expect(tester.widgetList<GroupCard>(cards).every((c) => c.showCount), isTrue);

    const target = 'AI 服务（名字也很长的一个代理组）';
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.widgetWithText(GroupCard, target)));
    await tester.pump();
    // 换组当帧旧网格就撤走，只有新的一份在淡入
    expect(find.byType(NodeSliverGrid), findsOneWidget);
    expect(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)).group.name, target);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('5 个成员 · 共 4 个组'), findsOneWidget);
    expect(find.text('5 个成员 · 自动'), findsOneWidget);   // 摘要也换成了 fallback 组的
    expect(find.text('按可用性自动切换'), findsOneWidget);
    // 记在订阅上（重进节点页、重启后照它停）
    expect(container.read(currentProfileProvider)?.currentGroupName, target);

    // 点外面收起面板：不换组
    await tester.tap(find.byType(GroupPickerButton));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(180, 20));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(container.read(currentProfileProvider)?.currentGroupName, target);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机 · 单组布局：重进节点页停在记下的组；记下的组不在了 → 第一个组', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 800),
      overrides: _overrides(profile: _profile(current: '负载均衡')),
      textScale: 1,
    );
    expect(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)).group.name, '负载均衡');
    expect(find.text('load-balance'), findsNWidgets(2));

    await _pump(
      tester,
      size: const Size(360, 800),
      overrides: _overrides(profile: _profile(current: '换订阅后没了的组')),
      textScale: 1,
    );
    expect(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)).group.name, '节点选择');
  });

  testWidgets('手机 · 单组布局：点节点（selectedMap 变）只更新网格，组按钮不重建', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 1600),
      overrides: _overrides(profile: _profile(), live: true),
      textScale: 1,
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ProxiesPage)));
    final button = tester.widget<GroupPickerButton>(find.byType(GroupPickerButton));
    expect(find.byIcon(Icons.push_pin_rounded), findsNothing);

    container.read(_liveProfile.notifier).state = _profile(selected: const {'节点选择': '自动选择', '自动选择': '东京 01 · IIJ'});
    await tester.pump();

    // 网格跟着变了（固定的节点画上图钉），组按钮还是原来那个 widget
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    expect(find.text('12 个成员 · 已固定'), findsOneWidget);
    expect(identical(tester.widget<GroupPickerButton>(find.byType(GroupPickerButton)), button), isTrue);
  });

  testWidgets('节点网格的列数在布局阶段跟着宽度走：窗口变宽 / 只变高都不重建网格', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 800),
      overrides: _overrides(profile: _profile()),
      textScale: 1,
    );
    final grid = tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid));
    expect(_gridColumns(tester), 2);

    tester.view.physicalSize = const Size(700, 800);
    await tester.pump();
    expect(_gridColumns(tester), 3);
    expect(identical(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)), grid), isTrue);

    tester.view.physicalSize = const Size(700, 500);   // 键盘弹出、拖窗口下边
    await tester.pump();
    expect(_gridColumns(tester), 3);
    expect(identical(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)), grid), isTrue);

    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    expect(_gridColumns(tester), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏两栏：左栏代理组 + 右栏当前组；默认第一个组，点左栏换组', (tester) async {
    for (final size in const [Size(1100, 720), Size(760, 600)]) {
      await _pump(
        tester,
        size: size,
        overrides: _overrides(profile: _profile(), wide: true, twoPane: true),
      );

      expect(find.text('全部测速'), findsOneWidget);
      expect(find.byType(GroupCard), findsNWidgets(4));
      expect(find.byType(GroupPickerButton), findsNothing);
      expect(find.byType(GroupSummary), findsOneWidget);
      expect(find.text('5 个成员'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);

      await tester.tap(find.widgetWithText(GroupCard, 'url-test'));
      await tester.pump();
      expect(find.text('12 个成员 · 自动'), findsOneWidget);
      expect(find.text('当前 $_longName'), findsOneWidget);
      expect(find.descendant(of: find.byType(GroupSummary), matching: find.text('38')), findsOneWidget);   // 在测速钮上
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(_gridColumns(tester), size.width > 1000 ? 4 : 2);
    }
  });

  testWidgets('有侧栏但不够两栏（平板竖屏）：用单列形态，留白走壳的约定', (tester) async {
    await _pump(
      tester,
      size: const Size(600, 900),
      overrides: _overrides(profile: _profile(), wide: true),
    );

    expect(find.byType(GroupPickerButton), findsOneWidget);
    expect(find.text('全部测速'), findsNothing);
    expect(_gridColumns(tester), 3);
  });

  testWidgets('有侧栏的单列（平板竖屏 / Windows 窄窗口）：选组面板从组按钮下面弹出', (tester) async {
    await _pump(
      tester,
      size: const Size(600, 900),
      overrides: _overrides(profile: _profile(), wide: true, live: true),
    );
    final buttonRect = tester.getRect(find.byType(GroupPickerButton));

    await tester.tap(find.byType(GroupPickerButton));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('选择代理组'), findsNothing);
    final popover = find.ancestor(of: find.byType(ListView).last, matching: find.byType(Material)).first;
    final rect = tester.getRect(popover);
    expect(rect.top, greaterThan(buttonRect.bottom));
    expect(rect.width, closeTo(440, 0.5));   // 跟按钮宽，最宽 440，居中在按钮下面
    expect(rect.center.dx, closeTo(buttonRect.center.dx, 0.5));
    expect(find.byType(GroupCard), findsNWidgets(4));

    await tester.tap(find.widgetWithText(GroupCard, '负载均衡'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupCard), findsNothing);
    expect(tester.widget<NodeSliverGrid>(find.byType(NodeSliverGrid)).group.name, '负载均衡');
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态：没有配置 → 点按去「我的」；有配置但没有代理组只给说明', (tester) async {
    await _pump(tester, size: const Size(360, 800), overrides: _overrides(groups: const []));

    expect(find.text('0 个代理组 · 0 个节点'), findsOneWidget);
    expect(find.text('还没有配置'), findsOneWidget);
    await tester.tap(find.text('去「我的」页导入订阅'));
    final container = ProviderScope.containerOf(tester.element(find.byType(ProxiesPage)));
    expect(container.read(meowTabProvider), MeowTab.me);

    await _pump(tester, size: const Size(360, 800), overrides: _overrides(profile: _profile(), groups: const []));
    expect(find.text('暂无代理组'), findsOneWidget);
  });

  group('震动', () {
    testWidgets('全部测速 / 测速本组 / 点节点的延迟单测：点下去各轻震一下', (tester) async {
      final haptics = recordHaptics();
      await _pump(tester, size: const Size(360, 1600), overrides: _overrides(profile: _profile()), textScale: 1);
      expect(haptics, isEmpty);

      await _tapAction(tester, find.byTooltip('全部测速'));
      expect(haptics, [kLight]);
      await _tapAction(tester, find.byTooltip('测速本组'));
      expect(haptics, [kLight, kLight]);
      await _tapAction(tester, find.text('152'));   // 香港 02 的延迟胶囊
      expect(haptics, [kLight, kLight, kLight]);
    });

    testWidgets('选节点：换了才震（select 组点已选中的不震）；url-test 组点了就是固定，震', (tester) async {
      final haptics = recordHaptics();
      await _pump(tester, size: const Size(360, 1600), overrides: _overrides(profile: _profile(current: '节点选择')), textScale: 1);

      Finder cell(String name) => find.descendant(of: find.byType(NodeSliverGrid), matching: find.text(name));
      await _tapAction(tester, cell('自动选择'));   // 已选中的
      expect(haptics, isEmpty);
      await _tapAction(tester, cell('香港 02 · BGP'));
      expect(haptics, [kSelection]);

      haptics.clear();
      await _pump(tester, size: const Size(360, 1600), overrides: _overrides(profile: _profile()), textScale: 1);
      await _tapAction(tester, cell('东京 01 · IIJ'));
      expect(haptics, [kSelection]);
    });
  });
}
