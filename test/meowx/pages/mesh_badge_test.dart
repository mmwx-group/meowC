import 'package:bett_box/meowx/config/mesh_whitelist.dart';
import 'package:bett_box/meowx/pages/proxies/mesh_badge.dart';
import 'package:bett_box/meowx/pages/settings/mesh_relay_text.dart';
import 'package:bett_box/meowx/state/mesh.dart';
import 'package:bett_box/meowx/state/mesh_relay.dart';
import 'package:flutter_test/flutter_test.dart';

// 节点上的「喵窝」小标的气泡内容（meshViaInfo）：路径类型以本机内核为准，中继设备名本机认出的优先、再用主控的。

const _t = MeshRelayText.zh();
const _ip = '100.64.0.20';

MeshState _mesh(TsPeer server, {bool running = true, List<MeshServer> servers = const [MeshServer(name: '东京 po0', meshIp: _ip)]}) =>
    MeshState(
      availability: MeshAvailability.available,
      devices: const [MeshDevice(id: 7, name: 'pixel-8', ipv4: '100.64.0.7', online: true)],
      servers: servers,
      engine: TsStatus(
        state: running ? 'Running' : 'Starting',
        self: const TsPeer(id: 7, name: 'pixel-8', addresses: ['100.64.0.7']),
        peers: [server],
      ),
    );

TsPeer _server({String peerRelay = '', String via = '', String curAddr = '', String relay = 'meowx-1', bool active = true}) => TsPeer(
  id: 20,
  name: 'tokyo',
  addresses: const [_ip],
  online: true,
  active: active,
  relay: relay,
  curAddr: curAddr,
  peerRelay: peerRelay,
  peerRelayVia: via,
);

final _paths = MeshPathsSnapshot.parse({
  'links': [
    {
      'a': {'type': 'device', 'id': 7, 'name': 'pixel-8', 'ip': '100.64.0.7'},
      'b': {'type': 'server', 'id': 1, 'name': '东京 po0', 'ip': _ip},
      'path': 'peer_relay',
      'via': {'device_id': 3, 'name': 'home-openwrt', 'owner': 'self'},
      'via_addr': '203.0.113.7:40000',
      'derp': {'region_code': 'meowx-1', 'name': 'hkaliyun'},
      'reported_by': 'a',
      'reported_at': DateTime.now().toUtc().toIso8601String(),
    },
  ],
});

final _derpPaths = MeshPathsSnapshot.parse({
  'links': [
    {
      'a': {'type': 'device', 'id': 7, 'ip': '100.64.0.7'},
      'b': {'type': 'server', 'id': 1, 'ip': _ip},
      'path': 'derp',
      'derp': {'region_code': 'meowx-1', 'name': 'hkaliyun'},
    },
  ],
});

void main() {
  test('设备中继：本机认出中继设备名（短名），小字是去掉 vni 的中继地址，不补主控记录', () {
    final info = meshViaInfo(
      _t,
      ip: _ip,
      mesh: _mesh(_server(peerRelay: '203.0.113.7:40000:vni:12', via: 'home-openwrt.meowx.internal.')),
      paths: _paths,
      selfId: 7,
    );
    expect(info.target, '东京 po0');
    expect(info.kind, MeshViaKind.peerRelay);
    expect(info.path, '经 home-openwrt 中继');
    expect(info.details, ['中继地址 203.0.113.7:40000']);
    expect(info.panel, isNull);
  });

  test('设备中继：本机认不出、主控认得出 → 大字用主控的名字，并补「主控记录：经 X 中继」；都认不出只写「经设备中继」', () {
    final byPanel = meshViaInfo(_t, ip: _ip, mesh: _mesh(_server(peerRelay: '203.0.113.7:40000:vni:12')), paths: _paths, selfId: 7);
    expect(byPanel.path, '经 home-openwrt 中继');
    expect(byPanel.panel, '主控记录：经 home-openwrt 中继');
    // IPv6、不带 vni 字样的写法
    final none = meshViaInfo(_t, ip: _ip, mesh: _mesh(_server(peerRelay: '[2001:db8::7]:40000:12')), paths: null, selfId: 7);
    expect(none.path, '经设备中继');
    expect(none.details, ['中继地址 [2001:db8::7]:40000']);
    expect(none.panel, isNull);
  });

  test('直连：对端地址；中继服务器：主控给的服务器名 + 区域代码；没有服务器名时写区域代码', () {
    final direct = meshViaInfo(_t, ip: _ip, mesh: _mesh(_server(curAddr: '198.51.100.9:41641')), paths: _paths, selfId: 7);
    expect(direct.kind, MeshViaKind.direct);
    expect(direct.path, '直连');
    expect(direct.details, ['对端地址 198.51.100.9:41641']);

    final derp = meshViaInfo(_t, ip: _ip, mesh: _mesh(_server()), paths: _derpPaths, selfId: 7);
    expect(derp.kind, MeshViaKind.derp);
    expect(derp.path, '经中继服务器 hkaliyun');
    expect(derp.details, ['中继服务器区域 meowx-1']);

    final plain = meshViaInfo(_t, ip: _ip, mesh: _mesh(_server()), paths: null, selfId: 7);
    expect(plain.path, '经中继服务器 meowx-1');
  });

  test('空闲：本机没流量时不按主控的旧记录写路径；服务器不在 servers 里时只写地址', () {
    final idle = meshViaInfo(
      _t,
      ip: _ip,
      mesh: _mesh(_server(active: false), servers: const []),
      paths: _paths,
      selfId: 7,
    );
    expect(idle.kind, MeshViaKind.idle);
    expect(idle.path, '空闲');
    expect(idle.details, ['有流量时先经中继服务器，同时尝试直连或设备中继']);
    expect(idle.target, _ip);
  });

  test('喵窝没在跑 / 内核里没有这台服务器', () {
    expect(meshViaInfo(_t, ip: _ip, mesh: _mesh(_server(), running: false)).path, '喵窝没有连着');
    expect(meshViaInfo(_t, ip: '100.64.0.99', mesh: _mesh(_server())).path, '喵窝设备列表里没有这台服务器');
    expect(meshViaInfo(_t, ip: _ip, mesh: const MeshState()).kind, MeshViaKind.unavailable);
  });

  test('主控设备列表还没拿到：按内核里的本机编号找主控记录', () {
    final m = _mesh(_server(peerRelay: '203.0.113.7:40000:vni:12'));
    final noDevices = MeshState(availability: m.availability, servers: m.servers, engine: m.engine);
    expect(meshViaInfo(_t, ip: _ip, mesh: noDevices, paths: _paths).path, '经 home-openwrt 中继');
  });

  test('白名单节点经喵窝时记下各自的 server（气泡据此找服务器）', () {
    final raw = <String, dynamic>{
      'proxies': [
        {'name': '东京 · 喵窝', 'type': 'ss', 'server': _ip, 'port': 443, '_mmwx-mesh': true},
        {'name': '香港', 'type': 'ss', 'server': '203.0.113.1', 'port': 443},
      ],
    };
    final patch = applyMeshWhitelist(raw, const [], on: true);
    expect(patch.viaMeshServers, {'东京 · 喵窝': _ip});
  });
}
