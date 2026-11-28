import 'package:bett_box/meowx/pages/settings/mesh_relay_pages.dart';
import 'package:bett_box/meowx/pages/settings/mesh_relay_text.dart';
import 'package:bett_box/meowx/pages/settings/networking_page.dart';
import 'package:bett_box/meowx/state/mesh.dart';
import 'package:bett_box/meowx/state/mesh_relay.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 喵窝设备中继的界面：路径文字（本机实时状态优先、主控补名字）、设备行的中继标签、中继设置页。

const _t = MeshRelayText.zh();

final _paths = MeshPathsSnapshot.parse({
  'links': [
    {
      'a': {'type': 'device', 'id': 7, 'name': 'pixel-8', 'ip': '100.64.0.7'},
      'b': {'type': 'device', 'id': 5, 'name': 'macbook', 'ip': '100.64.0.5'},
      'path': 'peer_relay',
      'via': {'device_id': 3, 'name': 'openwrt', 'owner': 'self'},
      'via_addr': '203.0.113.7:40000',
      'reported_by': 'both',
      'reported_at': DateTime.now().toUtc().toIso8601String(),
    },
    {
      'a': {'type': 'device', 'id': 7, 'name': 'pixel-8', 'ip': '100.64.0.7'},
      'b': {'type': 'device', 'id': 9, 'name': 'nas', 'ip': '100.64.0.9'},
      'path': 'derp',
      'derp': {'region_code': 'meowx-3', 'name': 'hkaliyun'},
      'reported_by': 'b',
      'reported_at': DateTime.now().toUtc().subtract(const Duration(minutes: 7)).toIso8601String(),
      'stale': true,
    },
  ],
  'relays': [
    {
      'device_id': 3,
      'name': 'openwrt',
      'owner': 'self',
      'state': 'active',
      'port': 40000,
      'sessions': [
        {
          'vni': 1,
          'a': {'type': 'device', 'id': 7, 'name': 'pixel-8'},
          'b': {'type': 'other'},
          'bytes': 2048,
        },
      ],
      'unmatched_sessions': 1,
    },
  ],
});

void main() {
  group('路径文字', () {
    test('本机实时状态优先：内核说走设备中继，中继名按地址从主控补；对不上写「经设备中继 地址」', () {
      const local = TsPeer(name: 'm', active: true, peerRelay: '203.0.113.7:40000:vni:12', relay: 'meowx-3');
      final v = meshPathView(local: local, paths: _paths)!;
      expect(meshPathLabel(_t, v), '经 openwrt 中继');
      const unknown = TsPeer(name: 'm', active: true, peerRelay: '198.51.100.3:40000:12');
      expect(meshPathLabel(_t, meshPathView(local: unknown, paths: _paths)!), '经设备中继 198.51.100.3:40000');
    });

    test('中继服务器写服务器名（主控给的），没有就写区域代码；直连、空闲', () {
      const derp = TsPeer(name: 'n', active: true, relay: 'meowx-3');
      expect(meshPathLabel(_t, meshPathView(local: derp, paths: _paths)!), '经中继服务器 hkaliyun');
      const derp2 = TsPeer(name: 'n', active: true, relay: 'meowx-8');
      expect(meshPathLabel(_t, meshPathView(local: derp2, paths: _paths)!), '经中继服务器 meowx-8');
      const direct = TsPeer(name: 'n', curAddr: '1.2.3.4:41641', peerRelay: '');
      expect(meshPathLabel(_t, meshPathView(local: direct)!), '直连');
      expect(meshPathLabel(_t, meshPathView(local: const TsPeer(name: 'idle'))!), '空闲');
    });

    test('本机内核里没有（或判不出）：按主控的记录，旧记录注「x 分钟前」；他人的中继加注', () {
      final stale = meshPathView(link: _paths.links[1])!;
      expect(stale.fromPanel && stale.stale, isTrue);
      expect(meshPathLabel(_t, stale), '经中继服务器 hkaliyun · 7 分钟前');
      // 本机这会儿空闲：有主控记录就按它
      expect(meshPathLabel(_t, meshPathView(local: const TsPeer(name: 'x'), link: _paths.links[0])!), '经 openwrt 中继');
      final other = MeshPathLink.parse({
        'a': {'type': 'device', 'id': 7},
        'b': {'type': 'server', 'id': 1},
        'path': 'peer_relay',
        'via': {'device_id': 40, 'name': 'bob-nas', 'owner': 'other'},
        'via_addr': '192.0.2.1:40000',
      });
      expect(meshPathLabel(_t, meshPathView(link: other)!), '经 bob-nas 中继（他人的）');
      expect(meshPathView(), isNull);
    });

    test('中继状态与错误码的文字', () {
      expect(meshRelayStateLabel(_t, 'pending'), '等待设备响应');
      expect(meshRelayStateLabel(_t, 'version_too_old'), 'tailscale 版本过低');
      expect(meshRelayErrorText(_t, 'share_not_allowed'), contains('已改回仅本账号'));
      expect(meshRelayErrorText(_t, 'invalid_endpoint'), contains('不能是私网或喵窝地址'));
      expect(meshRelayErrorText(_t, 'whatever', '主控的说明'), '主控的说明');
    });

    test('pending 超过 3 分钟才提示', () {
      const cfg = MeshRelayConfig(deviceId: 3, enabled: true, state: 'pending');
      final now = DateTime(2026, 11, 28, 10);
      expect(meshRelayPendingStuck(cfg, now.subtract(const Duration(minutes: 2)), now), isFalse);
      expect(meshRelayPendingStuck(cfg, now.subtract(const Duration(minutes: 3)), now), isTrue);
      expect(meshRelayPendingStuck(cfg.copyWith(enabled: false), now.subtract(const Duration(hours: 1)), now), isFalse);
      expect(meshRelayPendingStuck(cfg, null, now), isFalse);
    });
  });

  group('界面', () {
    const devices = [
      MeshDevice(id: 7, name: 'pixel-8', ipv4: '100.64.0.7', online: true),
      MeshDevice(id: 3, name: 'openwrt', ipv4: '100.64.0.3', online: true),
      MeshDevice(id: 5, name: 'macbook', ipv4: '100.64.0.5', online: true),
      MeshDevice(id: 9, name: 'nas', ipv4: '100.64.0.9', online: true),
    ];
    final relayState = MeshRelayViewState(
      paths: _paths,
      relays: const {
        3: MeshRelayConfig(
          deviceId: 3,
          name: 'openwrt',
          enabled: true,
          staticEndpoints: ['203.0.113.7:40000'],
          state: 'active',
          capable: true,
          tailscaleVersion: '1.104.5',
        ),
      },
      loadedAt: DateTime.now(),
    );
    MeshState meshState({bool relayOn = true, bool canShare = false}) => MeshState(
      availability: MeshAvailability.available,
      deviceRelay: MeshDeviceRelayFlag(enabled: relayOn, canShare: canShare),
      devices: devices,
      devicesComplete: true,
      devicesAt: DateTime.now(),
      stateNodeId: 7,
      stateNodeIdAt: DateTime.now(),
      engine: const TsStatus(
        state: 'Running',
        self: TsPeer(id: 7, name: 'pixel-8', addresses: ['100.64.0.7'], online: true),
        peers: [
          TsPeer(id: 3, name: 'openwrt', addresses: ['100.64.0.3'], online: true, active: true, curAddr: '192.168.1.1:41641'),
          TsPeer(id: 5, name: 'macbook', addresses: ['100.64.0.5'], online: true, active: true, peerRelay: '203.0.113.7:40000:vni:1', relay: 'meowx-3', rxBytes: 4096, txBytes: 1024),
        ],
      ),
    );

    Future<void> pump(WidgetTester tester, Widget child, {MeshState? mesh, MeshRelayViewState? relay, List<MeshRelayConfig>? saves}) async {
      tester.view.physicalSize = const Size(412, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isRunningProvider.overrideWithValue(true),
            meowSettingProvider.overrideWith(
              () => _Meow(
                const MeowSettings(
                  account: MeowAccount(host: 'https://panel.example.com', token: 't'),
                  tailscaleNodes: false,
                  mesh: MeowMesh(enabled: true, controlUrl: 'https://x', hostname: 'pixel-8', nodeId: 7, panelReason: ''),
                ),
              ),
            ),
            patchClashConfigProvider.overrideWith(_Patch.new),
            meshProvider.overrideWith(() => _FakeMesh(mesh ?? meshState())),
            meshRelayProvider.overrideWith(() => _FakeRelay(relay ?? relayState, saves ?? [])),
            meshAutoHostnameProvider.overrideWith((ref) async => 'pixel-8'),
          ],
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );
      await tester.pump();
    }

    testWidgets('设备行：本机实时路径 + 主控补的中继名；主控的旧记录灰显带时间；本账号中继设备带「中继」标签', (tester) async {
      await pump(tester, const MeshDetails());
      expect(find.text('直连'), findsOneWidget); // openwrt
      expect(find.text('经 openwrt 中继'), findsOneWidget); // macbook：内核说走设备中继，名字来自主控
      expect(find.text('经中继服务器 hkaliyun · 7 分钟前'), findsOneWidget); // nas：本机内核里没有，按主控旧记录
      expect(find.text('中继'), findsOneWidget); // 只有 openwrt 带标签，本机没有
    });

    testWidgets('管理员关了设备中继：路径照常显示，不显示「中继」标签', (tester) async {
      await pump(tester, const MeshDetails(), mesh: meshState(relayOn: false));
      expect(find.text('经 openwrt 中继'), findsOneWidget);
      expect(find.text('中继'), findsNothing);
    });

    testWidgets('设备详情：路径、流量、主控记录；中继设备有中继设置入口', (tester) async {
      await pump(tester, const MeshDevicePage(device: MeshDevice(id: 5, name: 'macbook', ipv4: '100.64.0.5', online: true)));
      expect(find.text('经 openwrt 中继'), findsNWidgets(2)); // 本机实时 + 主控记录
      expect(find.text('两端都报了 · 刚刚'), findsOneWidget);
      expect(find.text('↓ 4 KB · ↑ 1 KB'), findsOneWidget);
      expect(find.text('中继设置'), findsNothing, reason: 'macbook 不是中继设备');
      await pump(tester, const MeshDevicePage(device: MeshDevice(id: 3, name: 'openwrt', ipv4: '100.64.0.3', online: true)));
      expect(find.text('中继设置'), findsOneWidget);
      expect(find.text('正在工作'), findsOneWidget);
    });

    testWidgets('中继设置：读出配置、会话与「另有 n 个未识别的连接」；不是管理员没有共享范围；本地先查静态地址', (tester) async {
      final saves = <MeshRelayConfig>[];
      await pump(tester, const MeshRelayPage(deviceId: 3, name: 'openwrt'), saves: saves);
      await tester.pump();
      expect(find.text('作为喵窝中继'), findsOneWidget);
      expect(find.text('40000'), findsOneWidget);
      expect(find.text('203.0.113.7:40000'), findsOneWidget);
      expect(find.text('共享范围'), findsNothing);
      expect(find.text('pixel-8 ⇄ 其他用户'), findsOneWidget);
      expect(find.text('另有 1 个未识别的连接'), findsOneWidget);
      // 静态地址改成私网：不发请求，就地提示
      await tester.enterText(find.widgetWithText(TextField, '203.0.113.7:40000'), '192.168.1.2:40000');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(saves, isEmpty);
      expect(find.textContaining('不能是私网或喵窝地址'), findsOneWidget);
      // 改回公网、换端口：保存
      await tester.enterText(find.widgetWithText(TextField, '192.168.1.2:40000'), '198.51.100.7:40001');
      await tester.enterText(find.widgetWithText(TextField, '40000'), '40001');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(saves.single.port, 40001);
      expect(saves.single.staticEndpoints, ['198.51.100.7:40001']);
      expect(saves.single.share, 'self');
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('中继设置：管理员看得到共享范围', (tester) async {
      await pump(tester, const MeshRelayPage(deviceId: 3, name: 'openwrt'), mesh: meshState(canShare: true));
      expect(find.text('共享范围'), findsOneWidget);
    });

    testWidgets('中继设置：没上报过中继能力的设备没有开关', (tester) async {
      await pump(
        tester,
        const MeshRelayPage(deviceId: 3, name: 'openwrt'),
        relay: MeshRelayViewState(paths: _paths, relays: const {3: MeshRelayConfig(deviceId: 3)}),
      );
      expect(find.text('作为喵窝中继'), findsNothing);
      expect(find.textContaining('没有上报过中继能力'), findsOneWidget);
    });
  });
}

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Patch extends PatchClashConfig {
  @override
  ClashConfig build() => const ClashConfig();

  @override
  void onUpdate(ClashConfig value) {}
}

class _FakeMesh extends MeshController {
  _FakeMesh(this.initial);
  final MeshState initial;

  @override
  MeshState build() => initial;

  @override
  Future<void> tick({Duration devicesEvery = const Duration(seconds: 30)}) async {}

  @override
  Future<void> refresh() async {}
}

class _FakeRelay extends MeshRelayController {
  _FakeRelay(this.initial, this.saves);
  final MeshRelayViewState initial;
  final List<MeshRelayConfig> saves;

  @override
  MeshRelayViewState build() => initial;

  @override
  Future<void> refresh({bool force = false}) async {}

  @override
  Future<MeshRelayConfig?> load(int deviceId) async => state.relays[deviceId];

  @override
  Future<MeshRelayConfig?> save(MeshRelayConfig config) async {
    saves.add(config);
    return MeshRelayConfig(
      deviceId: config.deviceId,
      enabled: config.enabled,
      port: config.port,
      staticEndpoints: config.staticEndpoints,
      share: config.share,
      state: 'pending',
      capable: true,
    );
  }
}
