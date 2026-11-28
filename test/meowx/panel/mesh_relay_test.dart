import 'package:bett_box/meowx/panel/client.dart';
import 'package:bett_box/meowx/panel/mesh.dart';
import 'package:flutter_test/flutter_test.dart';

// 喵窝设备中继的主控接口（接口稿 MEOWX_MESH_PEER_RELAY_API.md）：解析、带状态码的出错、404 后 1 小时不再调。

/// 只换掉加密 RPC：按路径回事先排好的（状态码, 应答），记下每次的调用
class _Client extends PanelClient {
  _Client(this.answers) : super('https://panel.example.com');
  final Map<String, ({int status, Map<String, dynamic> body})> answers;
  final calls = <({String path, String method, Map<String, dynamic> payload})>[];

  @override
  Future<({int status, Map<String, dynamic> body})> rpcWithStatus(
    String path, {
    String method = 'POST',
    Map<String, dynamic> payload = const {},
    String? token,
  }) async {
    calls.add((path: path, method: method, payload: payload));
    return answers[path] ?? (status: 404, body: <String, dynamic>{'error': 'not found'});
  }
}

const _pathsBody = {
  'updated_at': '2026-11-28T10:00:05Z',
  'links': [
    {
      'a': {'type': 'device', 'id': 12, 'name': 'iphone', 'ip': '100.64.0.5'},
      'b': {'type': 'server', 'id': 7, 'name': 'po0', 'ip': '100.64.0.21'},
      'path': 'peer_relay',
      'via': {'device_id': 15, 'name': 'home-openwrt', 'owner': 'self'},
      'via_addr': '203.0.113.7:40000',
      'reported_by': 'both',
      'reported_at': '2026-11-28T10:00:00Z',
      'stale': false,
    },
    {
      // 主控认不出是哪台中继：省略 via，只有 via_addr
      'a': {'type': 'device', 'id': 12, 'name': 'iphone', 'ip': '100.64.0.5'},
      'b': {'type': 'device', 'id': 20, 'name': 'nas', 'ip': '100.64.0.20'},
      'path': 'peer_relay',
      'via_addr': '198.51.100.3:40000',
      'reported_by': 'a',
      'reported_at': '2026-11-28T09:59:00Z',
      'stale': true,
    },
    {
      'a': {'type': 'device', 'id': 12, 'name': 'iphone', 'ip': '100.64.0.5'},
      'b': {'type': 'server', 'id': 9, 'name': 'Tokyo', 'ip': '100.64.0.25'},
      'path': 'derp',
      'derp': {'region_code': 'meowx-3', 'server_id': 3, 'name': 'hkaliyun'},
      'reported_by': 'a',
      'reported_at': '2026-11-28T09:59:50Z',
      'stale': false,
    },
    {
      // 不认识的 path 丢掉
      'a': {'type': 'device', 'id': 12},
      'b': {'type': 'device', 'id': 13},
      'path': 'unknown',
    },
  ],
  'relays': [
    {
      'device_id': 15,
      'name': 'home-openwrt',
      'owner': 'self',
      'share': 'self',
      'state': 'active',
      'port': 40000,
      'sessions': [
        {
          'vni': 12345,
          'a': {'type': 'device', 'id': 12, 'name': 'iphone'},
          'b': {'type': 'other'},
          'bytes': 5180000,
          'since': '2026-11-28T09:40:00Z',
        },
      ],
      'unmatched_sessions': 2,
    },
    // 别人共享给所有人的中继：只有 id / 名字 / 主人 / 状态
    {'device_id': 30, 'name': 'bob-nas', 'owner': 'other', 'state': 'active'},
  ],
};

void main() {
  group('mesh/status 的 device_relay', () {
    test('有字段：开关、最低版本、能否共享', () {
      final s = MeshPanelStatus.parse({
        'available': true,
        'device_relay': {'enabled': true, 'min_version': '1.86.0', 'can_share': false},
      });
      expect(s.deviceRelay, const MeshDeviceRelayFlag(enabled: true, minVersion: '1.86.0'));
    });

    test('老主控没有这个字段 / 不可用时 = null（隐藏全部中继界面）', () {
      expect(MeshPanelStatus.parse({'available': true}).deviceRelay, isNull);
      expect(MeshPanelStatus.parse({'available': true, 'device_relay': null}).deviceRelay, isNull);
      expect(MeshPanelStatus.parse({'available': false, 'reason': 'not_admin', 'device_relay': {'enabled': true}}).deviceRelay, isNull);
    });
  });

  test('PeerRelay 两种写法都认：ip:port:vni:N 与 ip:port:N，IPv6 带方括号', () {
    expect(parseMeshPeerRelay('203.0.113.7:40000:vni:12345'), (hostPort: '203.0.113.7:40000', vni: 12345));
    expect(parseMeshPeerRelay('203.0.113.7:40000:12345'), (hostPort: '203.0.113.7:40000', vni: 12345));
    expect(parseMeshPeerRelay('[2001:db8::7]:40000:vni:9'), (hostPort: '[2001:db8::7]:40000', vni: 9));
    expect(parseMeshPeerRelay('[2001:db8::7]:40000:9'), (hostPort: '[2001:db8::7]:40000', vni: 9));
    for (final bad in ['', '203.0.113.7', '203.0.113.7:40000', '203.0.113.7:0:vni:1', 'x:vni:1', '2001:db8::7:40000:1']) {
      expect(parseMeshPeerRelay(bad), isNull, reason: bad);
    }
  });

  group('GET /user/mesh/paths 的解析', () {
    final p = MeshPathsSnapshot.parse(_pathsBody);

    test('links：经设备中继 / 认不出中继 / 经中继服务器，不认识的 path 丢掉', () {
      expect(p.updatedAt, DateTime.utc(2026, 11, 28, 10, 0, 5));
      expect(p.links, hasLength(3));
      final relay = p.links[0];
      expect(relay.path, 'peer_relay');
      expect(relay.via?.name, 'home-openwrt');
      expect(relay.via?.isOther, isFalse);
      expect(relay.viaAddr, '203.0.113.7:40000');
      expect(relay.reportedBy, 'both');
      expect(relay.b.type, 'server');
      expect(p.links[1].via, isNull);
      expect(p.links[1].viaAddr, '198.51.100.3:40000');
      expect(p.links[1].stale, isTrue);
      expect(p.links[2].derp?.name, 'hkaliyun');
      expect(p.links[2].derp?.regionCode, 'meowx-3');
    });

    test('relays 与 sessions：本账号的带会话与未识别数，别人的只有名字状态；他人一端是 other', () {
      expect(p.relays, hasLength(2));
      final mine = p.relayOf(15)!;
      expect(mine.mine, isTrue);
      expect(mine.port, 40000);
      expect(mine.unmatchedSessions, 2);
      expect(mine.sessions.single.vni, 12345);
      expect(mine.sessions.single.a.name, 'iphone');
      expect(mine.sessions.single.b.isOther, isTrue);
      expect(mine.sessions.single.bytes, 5180000);
      final other = p.relayOf(30)!;
      expect(other.mine, isFalse);
      expect(other.sessions, isEmpty);
    });

    test('按两端找连接（不分 a / b）、按中继地址找中继名、按区域代码找服务器名', () {
      expect(p.linkBetween(selfId: 20, deviceId: 12)?.viaAddr, '198.51.100.3:40000');
      expect(p.linkBetween(selfId: 12, deviceId: 20)?.viaAddr, '198.51.100.3:40000');
      expect(p.linkBetween(selfId: 12, deviceId: 99), isNull);
      expect(p.viaForAddress('203.0.113.7:40000')?.name, 'home-openwrt');
      expect(p.viaForAddress('198.51.100.3:40000'), isNull);
      expect(p.derpForRegion('meowx-3')?.name, 'hkaliyun');
      expect(p.derpForRegion('meowx-9'), isNull);
    });

    test('空应答 / 字段缺失不出错', () {
      final e = MeshPathsSnapshot.parse(const {});
      expect(e.links, isEmpty);
      expect(e.relays, isEmpty);
    });
  });

  group('中继配置', () {
    test('解析：端口缺省 40000，share 只认 self / all', () {
      final c = MeshRelayConfig.parse({
        'device_id': 15,
        'name': 'home-openwrt',
        'enabled': true,
        'port': 0,
        'static_endpoints': ['203.0.113.7:40000'],
        'share': 'weird',
        'state': 'pending',
        'capable': true,
        'tailscale_version': '1.104.5',
        'reported_at': '2026-11-28T10:00:00Z',
      })!;
      expect(c.port, 40000);
      expect(c.share, 'self');
      expect(c.capable, isTrue);
      expect(c.toPayload(), {
        'enabled': true,
        'port': 40000,
        'static_endpoints': ['203.0.113.7:40000'],
        'ddns_host': '',
        'share': 'self',
      });
      expect(MeshRelayConfig.parse({'enabled': true}), isNull);
    });

    test('本地先查：端口范围、静态地址只收公网 IP（私网 / 喵窝 / 回环 / IPv6 ULA 不行）、最多 4 个、DDNS', () {
      String? v({int? port = 40000, List<String> eps = const [], String ddns = ''}) =>
          validateMeshRelayForm(port: port, staticEndpoints: eps, ddnsHost: ddns);
      expect(v(), isNull);
      expect(v(port: 1023), 'invalid_port');
      expect(v(port: 65536), 'invalid_port');
      expect(v(port: null), 'invalid_port');
      expect(v(eps: ['203.0.113.7:40000', '[2001:db8::7]:40000']), isNull);
      for (final bad in [
        '192.168.1.2:40000',
        '10.0.0.1:40000',
        '172.20.0.1:40000',
        '100.64.0.5:40000',
        '127.0.0.1:40000',
        '[fd7a:115c:a1e0::5]:40000',
        '[fe80::1]:40000',
        '203.0.113.7',
        '2001:db8::7:40000',
        'home.example.com:40000',
      ]) {
        expect(v(eps: [bad]), 'invalid_endpoint', reason: bad);
      }
      expect(v(eps: List.filled(5, '203.0.113.7:40000')), 'invalid_endpoint');
      expect(v(ddns: 'home.example.com'), isNull);
      expect(v(ddns: 'not a host'), 'invalid_ddns_host');
    });
  });

  group('接口调用与出错', () {
    test('读路径 / 中继列表 / 一台；保存走 PUT /user/mesh/devices/{id}/relay', () async {
      final client = _Client({
        '/user/mesh/paths': (status: 200, body: Map<String, dynamic>.from(_pathsBody)),
        '/user/mesh/relay': (
          status: 200,
          body: {
            'relays': [
              {'device_id': 15, 'enabled': true, 'port': 40000, 'state': 'active', 'capable': true},
            ],
          },
        ),
        '/user/mesh/relay?device_id=15': (status: 200, body: {'device_id': 15, 'enabled': false, 'state': 'disabled', 'capable': true}),
        '/user/mesh/devices/15/relay': (status: 200, body: {'device_id': 15, 'enabled': true, 'port': 40001, 'state': 'pending', 'capable': true}),
      });
      expect((await client.meshPaths('t')).links, hasLength(3));
      expect((await client.meshRelays('t')).single.capable, isTrue);
      expect((await client.meshRelay('t', 15))?.enabled, isFalse);
      final saved = await client.meshSetRelay('t', const MeshRelayConfig(deviceId: 15, enabled: true, port: 40001));
      expect(saved?.state, 'pending');
      final put = client.calls.last;
      expect(put.method, 'PUT');
      expect(put.payload['port'], 40001);
      expect(put.payload['enabled'], isTrue);
    });

    test('路径上报的正文', () async {
      final client = _Client({'/user/mesh/paths': (status: 200, body: {'success': true})});
      await client.meshReportPaths(
        't',
        deviceId: 12,
        peers: [
          MeshPathPeer(
            ip: '100.64.0.21',
            path: 'peer_relay',
            peerRelay: '203.0.113.7:40000:vni:12345',
            rxBytes: 4200000,
            txBytes: 980000,
            lastHandshake: DateTime.utc(2026, 11, 28, 10),
          ),
          const MeshPathPeer(ip: '100.64.0.31', path: 'derp', derpRegion: 'meowx-7-alt'),
        ],
      );
      final c = client.calls.single;
      expect(c.method, 'POST');
      expect(c.payload, {
        'device_id': 12,
        'peers': [
          {
            'ip': '100.64.0.21',
            'path': 'peer_relay',
            'peer_relay': '203.0.113.7:40000:vni:12345',
            'rx_bytes': 4200000,
            'tx_bytes': 980000,
            'last_handshake': '2026-11-28T10:00:00Z',
          },
          {'ip': '100.64.0.31', 'path': 'derp', 'derp_region': 'meowx-7-alt', 'rx_bytes': 0, 'tx_bytes': 0},
        ],
      });
    });

    test('业务出错带状态码与错误码；HTTP 200 但带 error 也算出错', () async {
      final client = _Client({
        '/user/mesh/devices/15/relay': (status: 403, body: {'error': 'share_not_allowed', 'message': '只有管理员能共享'}),
        '/user/mesh/devices/16/relay': (status: 404, body: {'error': 'device_not_found', 'message': '设备不存在或不属于本账号'}),
        '/user/mesh/devices/17/relay': (status: 409, body: {'error': 'device_relay_disabled', 'message': '管理员关闭了设备中继'}),
        '/user/mesh/paths': (status: 429, body: {'error': 'rate_limited', 'message': '上报太频繁'}),
        '/user/mesh/relay': (status: 200, body: {'error': 'invalid_request', 'message': '请求格式错误'}),
      });
      Future<MeshRelayApiException> err(Future<Object?> f) async {
        try {
          await f;
        } on MeshRelayApiException catch (e) {
          return e;
        }
        fail('应当出错');
      }

      final share = await err(client.meshSetRelay('t', const MeshRelayConfig(deviceId: 15, share: 'all')));
      expect((share.status, share.code, share.message), (403, 'share_not_allowed', '只有管理员能共享'));
      final notFound = await err(client.meshSetRelay('t', const MeshRelayConfig(deviceId: 16)));
      expect(notFound.code, 'device_not_found');
      expect(notFound.missingEndpoint, isFalse, reason: '设备不存在不是「主控没有这个接口」');
      expect((await err(client.meshSetRelay('t', const MeshRelayConfig(deviceId: 17)))).status, 409);
      expect((await err(client.meshReportPaths('t', deviceId: 12, peers: const []))).rateLimited, isTrue);
      expect((await err(client.meshRelays('t'))).code, 'invalid_request');
      // device_not_found 没让门关上
      expect(meshRelayApiGate.allowed(client.host), isTrue);
    });
  });

  group('主控没有这些接口（404）', () {
    test('门：记下后 1 小时内不调，到点再试一次', () {
      var now = DateTime(2026, 11, 28, 10);
      final gate = MeshRelayApiGate(now: () => now);
      expect(gate.allowed('a'), isTrue);
      gate.observe('a', const MeshRelayApiException('x', status: 404, code: 'device_not_found'));
      expect(gate.allowed('a'), isTrue);
      gate.observe('a', const MeshRelayApiException('not found', status: 404));
      expect(gate.allowed('a'), isFalse);
      expect(gate.allowed('b'), isTrue, reason: '按主控分开记');
      now = now.add(const Duration(minutes: 59));
      expect(gate.allowed('a'), isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(gate.allowed('a'), isTrue);
      // 加密通道白名单里还没有这个路径也算
      gate.observe('c', const MeshRelayApiException('path not allowed', status: 403, code: 'path not allowed'));
      expect(gate.allowed('c'), isFalse);
    });

    test('调用回 404 后同一主控的路径 / 中继接口都不再发请求', () async {
      final client = _Client(const {});
      await expectLater(client.meshPaths('t'), throwsA(isA<MeshRelayApiException>().having((e) => e.missingEndpoint, 'missing', isTrue)));
      expect(client.calls, hasLength(1));
      await expectLater(client.meshRelays('t'), throwsA(isA<MeshRelayApiException>()));
      await expectLater(client.meshReportPaths('t', deviceId: 1, peers: const []), throwsA(isA<MeshRelayApiException>()));
      expect(client.calls, hasLength(1), reason: '门关着时不发请求');
    });
  });
}
