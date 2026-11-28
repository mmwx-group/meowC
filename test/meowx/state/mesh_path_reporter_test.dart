import 'dart:async';

import 'package:bett_box/meowx/panel/mesh.dart';
import 'package:bett_box/meowx/state/mesh_path_reporter.dart';
import 'package:bett_box/meowx/state/tailscale_status.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
// fake_async 随 flutter_test 一起来（SDK 钉的版本），不单独写进 pubspec
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

// 喵窝路径上报（Design/mesh-peer-relay.md §2.2 / §2.3）。

final _t0 = DateTime.utc(2026, 11, 28, 10);

TsPeer _peer(
  String ip, {
  String peerRelay = '',
  String curAddr = '',
  String relay = '',
  int rx = 0,
  int tx = 0,
  DateTime? hs,
  bool active = true,
}) => TsPeer(
  name: 'p$ip',
  addresses: [ip, 'fd7a:115c:a1e0::1'],
  online: true,
  active: active,
  peerRelay: peerRelay,
  curAddr: curAddr,
  relay: relay,
  rxBytes: rx,
  txBytes: tx,
  lastHandshake: hs,
);

void main() {
  group('§2.2 路径判定', () {
    test('设备中继 > 直连 > 中继服务器；都没有不报', () {
      // 走设备中继时 CurAddr 为空、Relay 照样有值：先判 PeerRelay
      final a = meshPathPeerOf(_peer('100.64.0.21', peerRelay: '203.0.113.7:40000:vni:12345', relay: 'meowx-7', rx: 5, tx: 6, hs: _t0))!;
      expect((a.path, a.peerRelay, a.endpoint, a.derpRegion), ('peer_relay', '203.0.113.7:40000:vni:12345', '', ''));
      expect((a.rxBytes, a.txBytes, a.lastHandshake), (5, 6, _t0));
      final b = meshPathPeerOf(_peer('100.64.0.30', curAddr: '198.51.100.9:41641', relay: 'meowx-7'))!;
      expect((b.path, b.endpoint, b.derpRegion), ('direct', '198.51.100.9:41641', ''));
      final c = meshPathPeerOf(_peer('100.64.0.31', relay: 'meowx-7-alt'))!;
      expect((c.path, c.derpRegion), ('derp', 'meowx-7-alt'));
      expect(meshPathPeerOf(_peer('100.64.0.32')), isNull);
      // 没有喵窝 IPv4 的不报
      expect(meshPathPeerOf(const TsPeer(name: 'x', addresses: ['fd7a:115c:a1e0::9'], curAddr: '1.2.3.4:1')), isNull);
    });

    test('TsPeer 的解析与路径文字按同一顺序（旧内核没有新字段照样能解）', () {
      final p = TsPeer.parse({
        'id': '3',
        'name': 'nas',
        'addresses': ['100.64.0.3'],
        'online': true,
        'active': true,
        'relay': 'meowx-1',
        'peerRelay': '203.0.113.7:40000:vni:1',
        'rxBytes': 4200000,
        'txBytes': 980000,
        'lastHandshake': '2026-11-28T10:00:00Z',
      })!;
      expect(p.peerRelay, '203.0.113.7:40000:vni:1');
      expect((p.rxBytes, p.txBytes, p.lastHandshake), (4200000, 980000, _t0));
      expect(p.pathText, '经设备中继');
      final old = TsPeer.parse({'id': '4', 'name': 'mac', 'active': true, 'relay': 'meowx-1'})!;
      expect((old.peerRelay, old.rxBytes, old.lastHandshake), ('', 0, null));
      expect(old.pathText, '中继 · meowx-1');
      expect(TsPeer.parse({'name': 'w', 'curAddr': '1.2.3.4:5', 'relay': 'r'})!.pathText, '直连');
    });
  });

  group('§2.3 报谁、什么时候报', () {
    test('只报近 5 分钟握过手、或收发比上次上报多的对端；按地址排序', () {
      final now = _t0;
      final peers = [
        _peer('100.64.0.9', curAddr: '1.1.1.1:1', hs: now.subtract(const Duration(minutes: 4))),
        _peer('100.64.0.5', relay: 'meowx-1', hs: now.subtract(const Duration(minutes: 6)), rx: 100),
        _peer('100.64.0.7', relay: 'meowx-1', hs: now.subtract(const Duration(minutes: 9)), rx: 300),
        _peer('100.64.0.8', relay: 'meowx-1', rx: 999), // 刚启动、没握手记录、也没有上次计数：不算
      ];
      final last = MeshPathMemory(bytes: {'100.64.0.5': (rx: 100, tx: 0), '100.64.0.7': (rx: 200, tx: 0)});
      final plan = meshPathPlan(peers, last: last, now: now);
      expect([for (final p in plan.peers) p.ip], ['100.64.0.7', '100.64.0.9']);
      expect(plan.bytes.keys, containsAll(['100.64.0.5', '100.64.0.7', '100.64.0.8', '100.64.0.9']));
    });

    test('没有活动对端：只在「从有到无」那一次报空列表，之后不报', () {
      final plan = meshPathPlan(const [], last: const MeshPathMemory(), now: _t0);
      expect(plan.shouldSend(const MeshPathMemory()), isFalse, reason: '一直没有：不报');
      const had = MeshPathMemory(signature: 'x', hadPeers: true);
      expect(plan.shouldSend(had), isTrue, reason: '从有到无：报一次空列表');
      expect(plan.shouldSend(plan.remember()), isFalse, reason: '报过空列表之后不再报');
    });

    test('路径变了：类型 / 中继地址变了，或有对端加入 / 离开；只是计数变了不算', () {
      final now = _t0;
      MeshPathPlan plan(List<TsPeer> ps, MeshPathMemory last) => meshPathPlan(ps, last: last, now: now);
      final first = plan([_peer('100.64.0.5', relay: 'meowx-1', hs: now, rx: 1)], const MeshPathMemory());
      final mem = first.remember();
      expect(plan([_peer('100.64.0.5', relay: 'meowx-1', hs: now, rx: 999)], mem).pathChanged(mem), isFalse);
      expect(plan([_peer('100.64.0.5', relay: 'meowx-2', hs: now)], mem).pathChanged(mem), isTrue);
      expect(plan([_peer('100.64.0.5', curAddr: '1.2.3.4:5', hs: now)], mem).pathChanged(mem), isTrue);
      expect(plan([_peer('100.64.0.5', peerRelay: '203.0.113.7:40000:vni:1', hs: now)], mem).pathChanged(mem), isTrue);
      expect(plan([_peer('100.64.0.5', relay: 'meowx-1', hs: now), _peer('100.64.0.6', relay: 'meowx-1', hs: now)], mem).pathChanged(mem), isTrue);
    });
  });

  group('MeshPathReporter', () {
    late List<TsPeer> peers;
    late List<List<MeshPathPeer>> sent;
    late List<int> ids;
    late List<String> logs;
    late bool active;
    late Object? failWith;
    late StreamController<List<ConnectivityResult>> conn;

    MeshPathReporter make(FakeAsync async) {
      final start = DateTime.utc(2026, 11, 28, 10);
      return MeshPathReporter(
        isActive: () => active,
        fetch: () async => TsStatus(
          state: 'Running',
          self: const TsPeer(id: 12, name: 'self', addresses: ['100.64.0.2']),
          peers: peers,
        ),
        send: (id, ps) async {
          ids.add(id);
          sent.add(ps);
          final f = failWith;
          if (f != null) throw f;
        },
        connectivity: () => conn.stream,
        log: logs.add,
        now: () => start.add(async.elapsed),
      );
    }

    setUp(() {
      sent = [];
      ids = [];
      logs = [];
      active = true;
      failWith = null;
      conn = StreamController<List<ConnectivityResult>>.broadcast();
      peers = [_peer('100.64.0.5', relay: 'meowx-1', hs: DateTime.utc(2026, 11, 28, 10), rx: 10)];
    });

    test('开起来马上报一次，之后每 60 秒一次；device_id 用内核 self.id', () {
      fakeAsync((async) {
        final r = make(async);
        r.sync();
        async.elapse(const Duration(milliseconds: 10));
        expect(sent, hasLength(1));
        expect(ids.single, 12);
        expect(sent.single.single.path, 'derp');
        async.elapse(const Duration(seconds: 60));
        expect(sent, hasLength(2));
        async.elapse(const Duration(seconds: 60));
        expect(sent, hasLength(3));
        r.stop();
        async.elapse(const Duration(minutes: 5));
        expect(sent, hasLength(3));
      });
    });

    test('路径变了：本机检查发现后 5 秒防抖补报，两次上报至少隔 5 秒', () {
      fakeAsync((async) {
        final r = make(async);
        r.sync();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        // 打洞成功换成直连：15 秒一次的本机检查发现 → 5 秒后补报
        peers = [_peer('100.64.0.5', curAddr: '198.51.100.9:41641', hs: DateTime.utc(2026, 11, 28, 10), rx: 20)];
        async.elapse(const Duration(seconds: 15));
        expect(sent, hasLength(1));
        async.elapse(const Duration(seconds: 5));
        expect(sent, hasLength(2));
        expect(sent.last.single.path, 'direct');
        // 页面轮询交进来的状态（observe）也能触发：换成经设备中继
        peers = [_peer('100.64.0.5', peerRelay: '203.0.113.7:40000:vni:1', hs: DateTime.utc(2026, 11, 28, 10), rx: 30)];
        r.observe(TsStatus(state: 'Running', self: const TsPeer(id: 12, name: 'self'), peers: peers));
        async.elapse(const Duration(seconds: 5));
        expect(sent, hasLength(3));
        expect(sent.last.single.path, 'peer_relay');
        r.stop();
      });
    });

    test('回前台补报受「至少隔 5 秒」约束', () {
      fakeAsync((async) {
        final r = make(async);
        r.sync();
        async.elapse(const Duration(milliseconds: 10));
        expect(sent, hasLength(1));
        r.onForeground();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1), reason: '离上次不到 5 秒');
        async.elapse(const Duration(seconds: 4));
        expect(sent, hasLength(2));
        r.stop();
      });
    });

    test('换网：5 秒后补报（第一次推来的网络状态只当基线）', () {
      fakeAsync((async) {
        final r = make(async);
        r.sync();
        async.elapse(const Duration(seconds: 10));
        expect(sent, hasLength(1));
        conn.add([ConnectivityResult.wifi]);
        async.elapse(const Duration(seconds: 10));
        expect(sent, hasLength(1));
        conn.add([ConnectivityResult.mobile]);
        async.elapse(const Duration(seconds: 4));
        expect(sent, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(2));
        r.stop();
      });
    });

    test('没有活动对端：报一次空列表后停发，又有了再报', () {
      fakeAsync((async) {
        final r = make(async);
        r.sync();
        async.elapse(const Duration(milliseconds: 10));
        expect(sent, hasLength(1));
        // 6 分钟后握手过期、计数也没涨：报一次空列表
        async.elapse(const Duration(minutes: 6));
        final empties = sent.where((s) => s.isEmpty).length;
        expect(empties, 1);
        final n = sent.length;
        async.elapse(const Duration(minutes: 5));
        expect(sent, hasLength(n), reason: '空列表只报一次');
        // 又有流量了
        peers = [_peer('100.64.0.5', relay: 'meowx-1', hs: DateTime.utc(2026, 11, 28, 10).add(async.elapsed), rx: 50)];
        async.elapse(const Duration(seconds: 61));
        expect(sent.last, isNotEmpty);
        r.stop();
      });
    });

    test('失败不重试、不积压；429 跳过这一轮；从有到无的空列表没报成功下一轮再报', () {
      fakeAsync((async) {
        failWith = const MeshRelayApiException('上报太频繁', status: 429, code: 'rate_limited');
        final r = make(async);
        r.sync();
        async.elapse(const Duration(seconds: 30));
        expect(sent, hasLength(1), reason: '失败后不重试');
        expect(logs.single, contains('限流'));
        expect(r.memory.hadPeers, isFalse, reason: '没报成功不记');
        failWith = null;
        async.elapse(const Duration(seconds: 30));
        expect(sent, hasLength(2));
        expect(r.memory.hadPeers, isTrue);
        r.stop();
      });
    });

    test('主控接口不可用（404 门关着）、或不该报时一个请求都不发', () {
      fakeAsync((async) {
        active = false;
        final r = make(async);
        r.sync();
        async.elapse(const Duration(minutes: 3));
        expect(sent, isEmpty);
        expect(r.isWatching, isFalse);
        final gated = MeshPathReporter(
          isActive: () => true,
          fetch: () async => TsStatus(state: 'Running', self: const TsPeer(id: 1, name: 's'), peers: peers),
          send: (_, ps) async => sent.add(ps),
          apiAvailable: () => false,
          log: logs.add,
        );
        gated.sync();
        async.elapse(const Duration(minutes: 3));
        expect(sent, isEmpty);
        gated.stop();
      });
    });
  });
}
