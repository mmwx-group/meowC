import 'dart:convert';

import 'package:bett_box/meowx/config/mesh_config.dart';
import 'package:bett_box/meowx/config/meow_patch.dart';
import 'package:bett_box/meowx/panel/mesh.dart';
import 'package:bett_box/meowx/state/mesh.dart';
import 'package:bett_box/meowx/state/tailscale_status.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';

/// 订阅里的组网节点被各处引用的一份配置（照主控下发的写法：节点不在分组里、只被规则与 DNS 引用；外加几种边角）。
Map<String, dynamic> _subscription({String enhancedMode = 'redir-host'}) => {
  'proxies': [
    {'name': '节点A', 'type': 'ss', 'server': '1.2.3.4', 'port': 443, 'cipher': 'aes-128-gcm', 'password': 'x'},
    {'name': '家里', 'type': 'tailscale', 'auth-key': 'tskey-auth-xxx', 'state-dir': 'tailscale-1'},
    {'name': '落地', 'type': 'socks5', 'server': '5.6.7.8', 'port': 1080, 'dialer-proxy': '家里'},
  ],
  'proxy-groups': [
    {'name': '🚀 手动选择', 'type': 'select', 'proxies': ['节点A', '家里', 'DIRECT']},
    {'name': '只有组网', 'type': 'select', 'proxies': ['家里']},
    {'name': '自动', 'type': 'url-test', 'include-all': true, 'proxies': ['家里']},
  ],
  'dns': {
    'enable': true,
    'enhanced-mode': enhancedMode,
    'nameserver': ['223.5.5.5', 'ts://家里'],
    'nameserver-policy': {
      '+.tail1234.ts.net': 'ts://家里',
      '+.corp.example': ['ts://家里', '10.0.0.53'],
      'geosite:cn': '223.5.5.5',
    },
    if (enhancedMode == 'fake-ip') 'fake-ip-filter': ['*.lan'],
  },
  'tun': {'route-address': <String>[], 'route-exclude-address': <String>[]},
  'sub-rules': {
    'sub1': ['IP-CIDR,100.64.0.0/10,家里,no-resolve', 'MATCH,DIRECT'],
  },
};

const _rules = [
  'IP-CIDR,100.64.0.0/10,家里,no-resolve',
  'DOMAIN-SUFFIX,tail1234.ts.net,家里',
  'AND,((NETWORK,TCP),(DST-PORT,22)),家里',
  r'DOMAIN-REGEX,^nas\.home$,家里',
  'SUB-RULE,(NETWORK,UDP),sub1',
  'GEOIP,CN,DIRECT',
  'MATCH,家里',
];

/// mihomo 认的出站：内置的 + 节点 + 代理组。
Set<String> _targets(Map<String, dynamic> raw) => {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'COMPATIBLE',
  'GLOBAL',
  for (final p in raw['proxies'] as List) (p as Map)['name'] as String,
  for (final g in raw['proxy-groups'] as List) (g as Map)['name'] as String,
};

/// 同内核 ParseRulePayload 取规则的出站（SUB-RULE 的最后一格是子规则名，跳过）。
String? _ruleTarget(String rule) {
  final parts = rule.split(',').map((e) => e.trim()).toList();
  final type = parts.first.toUpperCase();
  if (type == 'MATCH') return parts[1];
  if (type == 'SUB-RULE') return null;
  if (const ['AND', 'OR', 'NOT', 'DOMAIN-REGEX'].contains(type)) return parts.last;
  return parts.length > 2 ? parts[2] : null;
}

/// 配置合法：规则的出站、代理组成员、dialer-proxy、ts:// DNS 都指向存在的东西，代理组不空。
void _expectValid(Map<String, dynamic> raw, List<dynamic> rules) {
  final targets = _targets(raw);
  final tsNodes = tailscaleNodeNames(raw).toSet();
  for (final r in [...rules, for (final l in (raw['sub-rules'] as Map? ?? {}).values) ...(l as List)]) {
    final t = _ruleTarget(r as String);
    if (t != null) expect(targets, contains(t), reason: r);
  }
  for (final g in raw['proxy-groups'] as List) {
    final members = (g as Map)['proxies'] as List;
    expect(members.isNotEmpty || g['include-all'] == true, isTrue, reason: '${g['name']} 不能是空组');
    for (final m in members) {
      expect(targets, contains(m), reason: '${g['name']} → $m');
    }
  }
  for (final p in raw['proxies'] as List) {
    final d = (p as Map)['dialer-proxy'];
    if (d != null) expect(targets, contains(d));
  }
  final dns = raw['dns'] as Map;
  final servers = [
    ...(dns['nameserver'] as List? ?? const []),
    for (final v in (dns['nameserver-policy'] as Map? ?? {}).values) ...(v is List ? v : [v]),
  ];
  for (final s in servers) {
    final str = s.toString();
    if (str.startsWith('ts://')) expect(tsNodes, contains(str.substring(5)), reason: str);
  }
}

void main() {
  group('三选一', () {
    test('老用户缺省：订阅组网节点照旧开、喵窝关；没有组网节点时是「关闭」', () {
      final old = MeowSettings.fromJson({'po0Enabled': true});
      expect(old.tailscaleNodes, isTrue);
      expect(old.mesh.enabled, isFalse);
      expect(networkingModeOf(old, hasTailscaleNodes: true), NetworkingMode.tailscale);
      expect(networkingModeOf(old, hasTailscaleNodes: false), NetworkingMode.off);
      expect(stripsSubscriptionTailscale(old), isFalse);
    });

    test('喵窝开着一律优先：订阅组网节点算关、生成配置时去掉', () {
      const s = MeowSettings(mesh: MeowMesh(enabled: true));
      expect(networkingModeOf(s, hasTailscaleNodes: true), NetworkingMode.mesh);
      expect(stripsSubscriptionTailscale(s), isTrue);
    });

    test('切换时两边的开关一起改', () {
      const s = MeowSettings();
      final mesh = withNetworkingMode(s, NetworkingMode.mesh);
      expect((mesh.mesh.enabled, mesh.tailscaleNodes), (true, false));
      final ts = withNetworkingMode(mesh, NetworkingMode.tailscale);
      expect((ts.mesh.enabled, ts.tailscaleNodes), (false, true));
      final off = withNetworkingMode(ts, NetworkingMode.off);
      expect((off.mesh.enabled, off.tailscaleNodes), (false, false));
      expect(networkingModeOf(off, hasTailscaleNodes: true), NetworkingMode.off);
      expect(stripsSubscriptionTailscale(off), isTrue);
    });

    test('设置落盘往返：喵窝的字段、订阅组网节点开关', () {
      const s = MeowSettings(
        tailscaleNodes: false,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://ts.example.com:8443', magicDns: 'meowx.internal', routes: ['192.168.1.0/24'], nodeId: 7, panelReason: ''),
      );
      final back = MeowSettings.fromJson(json.decode(json.encode(s.toJson())) as Map<String, Object?>);
      expect(back, s);
    });
  });

  test('设备名规范化', () {
    expect(meshHostname('Pixel 8 Pro'), 'pixel-8-pro');
    expect(meshHostname('DESKTOP-AB12CD'), 'desktop-ab12cd');
    expect(meshHostname('--My__Phone--'), 'my-phone');
    expect(meshHostname('小米手机', fallback: 'meowx-android'), 'meowx-android');
    expect(meshHostname('a' * 80).length, 63);
  });

  group('IPv4 网段', () {
    test('解析与包含', () {
      final c = Ipv4Cidr.parse('192.168.1.77/24')!;
      expect(c.toString(), '192.168.1.0/24');
      expect(c.contains(parseIpv4('192.168.1.5')!), isTrue);
      expect(c.contains(parseIpv4('192.168.2.5')!), isFalse);
      expect(Ipv4Cidr.parse('10.0.0.1')!.prefix, 32);
      expect(Ipv4Cidr.parse('300.1.1.1/8'), isNull);
      expect(Ipv4Cidr.parse('fd00::/8'), isNull);
    });

    test('挖洞：剩下的网段不重叠、不含洞、合起来正好是原网段减去洞', () {
      final base = Ipv4Cidr.parse('192.168.0.0/16')!;
      final hole = Ipv4Cidr.parse('192.168.1.0/24')!;
      final parts = subtractCidr(base, hole);
      expect(parts.map((p) => p.toString()), [
        '192.168.128.0/17',
        '192.168.64.0/18',
        '192.168.32.0/19',
        '192.168.16.0/20',
        '192.168.8.0/21',
        '192.168.4.0/22',
        '192.168.2.0/23',
        '192.168.0.0/24',
      ]);
      var total = 0;
      for (final p in parts) {
        expect(p.overlaps(hole), isFalse);
        expect(base.covers(p), isTrue);
        total += 1 << (32 - p.prefix);
      }
      expect(total, (1 << 16) - (1 << 8));
      expect(subtractCidr(base, Ipv4Cidr.parse('10.0.0.0/8')!), [base]);
      expect(subtractCidr(hole, base), isEmpty);
    });

    test('站点网段和本机所在网络重叠的这次不接入', () {
      expect(meshActiveSites(['192.168.1.0/24', '10.233.0.0/24', 'bad', '192.168.1.0/24'], ['192.168.1.23']), ['10.233.0.0/24']);
      expect(meshActiveSites(['192.168.1.0/24'], const []), ['192.168.1.0/24']);
      expect(
        meshTunRoutes(const MeowMesh(enabled: true, controlUrl: 'https://x', routes: ['192.168.1.0/24']), const []),
        ['100.64.0.0/10', '192.168.1.0/24'],
      );
      expect(meshTunRoutes(const MeowMesh(routes: ['192.168.1.0/24']), const []), isEmpty);
    });

    test('TUN 路由：安卓「绕过私有网络」补进路由，桌面从排除的私网段里挖掉', () {
      // 安卓：只路由公网段（96.0.0.0/4 已盖住 100.64/10，不重复加）
      final android = meshAdjustRoutes(['96.0.0.0/4', '1.0.0.0/8', '2000::/3'], const [], ['100.64.0.0/10', '192.168.1.0/24']);
      expect(android.routeAddress, ['96.0.0.0/4', '1.0.0.0/8', '2000::/3', '192.168.1.0/24']);
      // 桌面：排除私网段时 192.168.0.0/16 挖掉站点那一段，IPv6 原样
      final desktop = meshAdjustRoutes(const [], ['127.0.0.0/8', '192.168.0.0/16', 'fd00::/8'], ['100.64.0.0/10', '192.168.1.0/24']);
      expect(desktop.routeAddress, isEmpty);
      expect(desktop.routeExclude.first, '127.0.0.0/8');
      expect(desktop.routeExclude, contains('fd00::/8'));
      expect(desktop.routeExclude, isNot(contains('192.168.0.0/16')));
      expect(desktop.routeExclude, contains('192.168.0.0/24'));
      final hole = Ipv4Cidr.parse('192.168.1.0/24')!;
      for (final e in desktop.routeExclude) {
        final c = Ipv4Cidr.parse(e);
        if (c != null) expect(c.overlaps(hole), isFalse, reason: e);
      }
      // 不绕过私有网络：不动
      final none = meshAdjustRoutes(const [], const [], ['100.64.0.0/10']);
      expect(none.routeAddress, isEmpty);
      expect(none.routeExclude, isEmpty);
    });
  });

  group('系统代理排除清单', () {
    bool globMatch(String pattern, String host) =>
        RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$').hasMatch(host);
    bool excluded(List<String> list, String host) => list.any((p) => globMatch(p, host));

    test('192.168.* 去掉站点 192.168.1.0/24：其余照旧不走代理，站点那一段走代理（逐个地址核对）', () {
      final list = meshNarrowBypass(['localhost', '127.*', '192.168.*', '*.local'], ['100.64.0.0/10', '192.168.1.0/24']);
      expect(list.take(2), ['localhost', '127.*']);
      expect(list.last, '*.local');
      expect(list, isNot(contains('192.168.*')));
      expect(list.length, 3 + 19);
      for (var c = 0; c < 256; c++) {
        for (final d in const [0, 1, 99, 200, 255]) {
          final host = '192.168.$c.$d';
          expect(excluded(list, host), c != 1, reason: host);
        }
      }
    });

    test('10.* 去掉映射段 10.233.0.0/24：逐个第二、三段核对', () {
      final list = meshNarrowBypass(['10.*'], ['10.233.0.0/24']);
      for (var b = 0; b < 256; b++) {
        for (var c = 0; c < 256; c++) {
          final host = '10.$b.$c.7';
          expect(excluded(list, host), !(b == 233 && c == 0), reason: host);
        }
      }
      expect(list.length, lessThan(60));
    });

    test('没有喵窝网段、条目不重叠、整段都是喵窝的', () {
      const defaults = ['10.*', '172.16.*', '192.168.*'];
      expect(meshNarrowBypass(defaults, const []), defaults);
      expect(meshNarrowBypass(defaults, ['100.64.0.0/10']), defaults);
      expect(meshNarrowBypass(['100.64.*', 'example.com'], ['100.64.0.0/10']), ['example.com']);
      // /23 的站点：第三段两个值都走代理
      final list = meshNarrowBypass(['192.168.*'], ['192.168.4.0/23']);
      for (var c = 0; c < 256; c++) {
        expect(excluded(list, '192.168.$c.1'), c != 4 && c != 5, reason: '$c');
      }
    });
  });

  group('运行配置改写', () {
    test('rewriteRuleTarget 照内核的格子认出站', () {
      const removed = {'家里'};
      expect(rewriteRuleTarget('IP-CIDR,100.64.0.0/10,家里,no-resolve', removed), 'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve');
      expect(rewriteRuleTarget('MATCH,家里', removed), 'MATCH,DIRECT');
      expect(rewriteRuleTarget('AND,((NETWORK,TCP),(DST-PORT,22)),家里', removed), 'AND,((NETWORK,TCP),(DST-PORT,22)),DIRECT');
      expect(rewriteRuleTarget('SUB-RULE,(NETWORK,UDP),家里', removed), 'SUB-RULE,(NETWORK,UDP),家里');
      expect(rewriteRuleTarget('DOMAIN,家里.com,节点A', removed), 'DOMAIN,家里.com,节点A');
    });

    test('去掉订阅组网节点后配置仍合法', () {
      final raw = _subscription();
      final patch = applyMeowNetworking(raw, List<dynamic>.of(_rules), stripTailscale: true);
      expect(patch.subscriptionTailscaleNodes, ['家里']);
      expect(patch.removed, ['家里']);
      expect(raw.containsKey('priority-rules'), isFalse);
      expect(tailscaleNodeNames(raw), isEmpty);
      expect(patch.rules, [
        'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve',
        'DOMAIN-SUFFIX,tail1234.ts.net,DIRECT',
        'AND,((NETWORK,TCP),(DST-PORT,22)),DIRECT',
        r'DOMAIN-REGEX,^nas\.home$,DIRECT',
        'SUB-RULE,(NETWORK,UDP),sub1',
        'GEOIP,CN,DIRECT',
        'MATCH,DIRECT',
      ]);
      final groups = raw['proxy-groups'] as List;
      expect(groups[0]['proxies'], ['节点A', 'DIRECT']);
      expect(groups[1]['proxies'], ['DIRECT']);   // 删空了补 DIRECT
      expect(groups[2]['proxies'], isEmpty);      // include-all 的组不补
      expect((raw['proxies'] as List)[1].containsKey('dialer-proxy'), isFalse);
      final dns = raw['dns'] as Map;
      expect(dns['nameserver'], ['223.5.5.5']);
      expect(dns['nameserver-policy'], {'+.corp.example': ['10.0.0.53'], 'geosite:cn': '223.5.5.5'});
      expect((raw['sub-rules'] as Map)['sub1'], ['IP-CIDR,100.64.0.0/10,DIRECT,no-resolve', 'MATCH,DIRECT']);
      _expectValid(raw, patch.rules);
    });

    test('选 Tailscale：不去掉、不注入', () {
      final raw = _subscription();
      final patch = applyMeowNetworking(raw, List<dynamic>.of(_rules), stripTailscale: false);
      expect(tailscaleNodeNames(raw), ['家里']);
      expect(patch.rules, _rules);
      expect(raw.containsKey('priority-rules'), isFalse);
      expect((raw['proxies'] as List).any((p) => p['name'] == meshOutboundName), isFalse);
      _expectValid(raw, patch.rules);
    });

    test('喵窝：注入节点、DNS 策略与最前面的规则，订阅组网节点与同名节点去掉', () {
      final raw = _subscription(enhancedMode: 'fake-ip');
      (raw['proxies'] as List).add({'name': meshOutboundName, 'type': 'ss', 'server': '9.9.9.9', 'port': 1, 'cipher': 'aes-128-gcm', 'password': 'y'});
      const mesh = MeshInjection(
        controlUrl: 'https://relay.example.com:8443',
        hostname: 'pixel-8',
        magicDns: 'meowx.internal',
        sites: ['192.168.1.0/24', '10.233.0.0/24'],
        authKey: 'hskey-auth-once',
      );
      final patch = applyMeowNetworking(raw, List<dynamic>.of(_rules), stripTailscale: true, mesh: mesh);
      expect(patch.removed.toSet(), {'家里', meshOutboundName});
      final proxies = raw['proxies'] as List;
      expect(proxies.where((p) => p['name'] == meshOutboundName), hasLength(1));
      expect(proxies.last, {
        'name': '喵窝',
        'type': 'tailscale',
        'control-url': 'https://relay.example.com:8443',
        'state-dir': 'meowx-mesh',
        'hostname': 'pixel-8',
        'accept-routes': true,
        'udp': true,
        'auth-key': 'hskey-auth-once',
      });
      // 喵窝的规则进内核的 priority-rules（先于出站模式），订阅规则表里不再重复
      expect(raw['priority-rules'], [
        'IP-CIDR,100.64.0.0/10,喵窝,no-resolve',
        'DOMAIN-SUFFIX,meowx.internal,喵窝',
        'IP-CIDR,192.168.1.0/24,喵窝,no-resolve',
        'IP-CIDR,10.233.0.0/24,喵窝,no-resolve',
      ]);
      final dns = raw['dns'] as Map;
      expect((dns['nameserver-policy'] as Map)['+.meowx.internal'], 'ts://喵窝');
      expect(dns['fake-ip-filter'], ['*.lan', '+.meowx.internal']);
      // 安卓「绕过私有网络」时的路由表：站点网段补进去
      expect(patch.rules.any((r) => r.toString().contains(meshOutboundName)), isFalse);
      _expectValid(raw, [...raw['priority-rules'] as List, ...patch.rules]);
    });

    test('喵窝：登记过的设备不带 key；redir-host 不加 fake-ip-filter；TUN 排除段挖掉站点', () {
      final raw = _subscription();
      (raw['tun'] as Map)['route-exclude-address'] = ['192.168.0.0/16', '10.0.0.0/8'];
      const mesh = MeshInjection(controlUrl: 'https://x', hostname: 'h', sites: ['192.168.1.0/24']);
      applyMeowNetworking(raw, List<dynamic>.of(_rules), stripTailscale: true, mesh: mesh);
      expect((raw['proxies'] as List).last.containsKey('auth-key'), isFalse);
      expect((raw['dns'] as Map).containsKey('fake-ip-filter'), isFalse);
      expect(raw['priority-rules'], ['IP-CIDR,100.64.0.0/10,喵窝,no-resolve', 'IP-CIDR,192.168.1.0/24,喵窝,no-resolve']);
      final exclude = (raw['tun'] as Map)['route-exclude-address'] as List;
      expect(exclude, isNot(contains('192.168.0.0/16')));
      expect(exclude, contains('10.0.0.0/8'));
    });

    test('整张规则表：阻止 QUIC → MeowX 前置规则 → 订阅规则（喵窝的不在这里，在 priority-rules）', () {
      final table = meowRuleTable(
        const MeowSettings(bypassDomains: ['x.com']),
        quicRules: const ['AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'],
        rules: const ['MATCH,DIRECT'],
        debugPo0: false,
      );
      expect(table, [
        'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT',
        'DOMAIN,x.com,DIRECT',
        'MATCH,DIRECT',
      ]);
    });

    test('不可改的规则列表也能改写（不碰传进来的那份）', () {
      final raw = _subscription();
      final patch = applyMeowNetworking(raw, List<dynamic>.unmodifiable(_rules), stripTailscale: true);
      expect(patch.rules.last, 'MATCH,DIRECT');
    });
  });

  group('状态', () {
    String stateFile({String? nodeId}) {
      String b64(String s) => base64.encode(utf8.encode(s));
      return json.encode({
        '_machinekey': b64('privkey:abc'),
        // 实际文件里当前档写的是状态键（profile-xxxx），_profiles 按档 ID 列（2026-11 模拟器上抓的 tsnet 状态文件就是这样）
        '_current-profile': b64('profile-a1b2'),
        '_profiles': b64(json.encode({
          'ffff': {'ID': 'ffff', 'Name': 'u9', 'Key': 'profile-ffff', 'NodeID': '99', 'ControlURL': 'https://y'},
          'a1b2': {'ID': 'a1b2', 'Name': 'u12', 'Key': 'profile-a1b2', 'NodeID': ?nodeId, 'ControlURL': 'https://x'},
        })),
      });
    }

    test('从 tsnet 状态文件取设备编号', () {
      expect(meshNodeIdFromState(stateFile(nodeId: '42')), 42);
      expect(meshNodeIdFromState(stateFile()), isNull);
      expect(meshNodeIdFromState('{"_machinekey":"eA=="}'), isNull);
      expect(meshNodeIdFromState('not json'), isNull);
    });

    test('设备列表：主控出错时不完整（不能据此判断被删）', () {
      final ok = MeshDeviceList.parse({
        'devices': [
          {'id': 3, 'name': 'openwrt', 'ipv4': '100.64.0.3', 'online': true, 'last_seen': '0001-01-01T00:00:00Z', 'routes': ['192.168.1.0/24']},
        ],
        'sites': [
          {'id': 2, 'original': '192.168.1.0/24', 'advertised': '192.168.1.0/24'},
        ],
      });
      expect(ok.complete, isTrue);
      expect(ok.devices.single.lastSeen, isNull);
      expect(ok.sites.single.advertised, '192.168.1.0/24');
      final partial = MeshDeviceList.parse({'devices': [], 'sites': [], 'error': 'headscale down'});
      expect(partial.complete, isFalse);
    });

    test('阶段与「设备被删了」的判断', () {
      final t0 = DateTime(2026, 11, 6, 12);
      const devices = [
        MeshDevice(id: 7, name: 'pixel', ipv4: '100.64.0.7', online: true),
        MeshDevice(id: 3, name: 'openwrt', ipv4: '100.64.0.3', online: true),
        MeshDevice(id: 5, name: 'mac', online: false),
      ];
      var s = MeshState(devices: devices, devicesComplete: true, devicesAt: t0.add(const Duration(seconds: 10)), stateNodeId: 7, stateNodeIdAt: t0);
      expect(meshPhase(enabled: false, running: true, state: s), MeshPhase.off);
      expect(meshPhase(enabled: true, running: false, state: s), MeshPhase.idle);
      expect(meshPhase(enabled: true, running: true, state: s), MeshPhase.connected);
      expect(meshPhaseText(MeshPhase.connected, s), '已连接 · 1 台在线');
      expect(s.stateNodeDeleted, isFalse);

      // 本机不在列表里：列表比看到编号晚 5 秒以上才算被删；刚登记时列表还是旧的不算
      s = MeshState(devices: devices, devicesComplete: true, devicesAt: t0.add(const Duration(seconds: 2)), stateNodeId: 9, stateNodeIdAt: t0);
      expect(s.stateNodeDeleted, isFalse);
      expect(meshPhase(enabled: true, running: true, state: s), MeshPhase.connecting);
      s = s.copyWith(devicesAt: t0.add(const Duration(seconds: 6)));
      expect(s.stateNodeDeleted, isTrue);
      expect(s.copyWith(devicesComplete: false).stateNodeDeleted, isFalse);

      // 没登记 / 正在要 key / 出错
      expect(meshPhase(enabled: true, running: true, state: const MeshState()), MeshPhase.joining);
      expect(meshPhase(enabled: true, running: true, state: const MeshState(enrolling: true)), MeshPhase.enrolling);
      const failed = MeshState(error: '操作太频繁，请稍后再试');
      expect(meshPhase(enabled: true, running: true, state: failed), MeshPhase.failed);
      expect(meshPhaseText(MeshPhase.failed, failed), '失败：操作太频繁，请稍后再试');

      // 问不到主控（App 自己的请求按订阅规则走到了连不上主控的节点上等）：已入网的不算失败，只是状态未知
      const unreachable = MeshState(stateNodeId: 7, panelError: '无法连接主控');
      expect(meshPhase(enabled: true, running: true, state: unreachable), MeshPhase.unreachable);
      expect(meshPhaseText(MeshPhase.unreachable, unreachable), '已入网 · 问不到主控，状态未知');
      expect(meshPhase(enabled: true, running: true, state: unreachable.copyWith(devices: devices)), MeshPhase.connected);
      expect(meshPhase(enabled: true, running: true, state: const MeshState(panelError: 'x')), MeshPhase.joining);

      // 状态文件读不到时用记下的编号认本机
      const noFile = MeshState(devices: devices);
      expect(noFile.selfDevice(7)?.name, 'pixel');
      expect(noFile.onlineOthers(7), 1);
    });

    test('内核状态（meowTailscaleStatus 的回包）', () {
      final r = parseTsStatusResponse(json.encode({
        'status': {
          'state': 'Running',
          'self': {'id': '15', 'name': 'pixel', 'addresses': ['100.69.123.58', 'fd7a::1'], 'online': true},
          'peers': [
            {'id': '3', 'name': 'openwrt', 'addresses': ['100.124.214.252'], 'online': true, 'curAddr': '203.0.113.7:41641', 'relay': 'meowx-1'},
            {'id': '5', 'name': 'mac', 'addresses': ['100.81.135.22'], 'relay': 'meowx-1', 'lastSeen': '2026-11-06T08:00:00Z'},
          ],
        },
      }));
      final st = r.status!;
      expect(r.error, isNull);
      expect((st.running, st.self!.id, st.peers.length), (true, 15, 2));
      expect(st.peerFor(id: 3)!.pathText, '直连');
      expect(st.peerFor(ip: '100.81.135.22')!.pathText, '中继 · meowx-1');
      expect(st.peerFor(id: 99), isNull);
      // 没有这个出站 / 出错 / 旧核心回空 / 回包坏了
      expect(parseTsStatusResponse('{"status":null}').status, isNull);
      expect(parseTsStatusResponse('{"status":null,"error":"context deadline exceeded"}').error, 'context deadline exceeded');
      expect(parseTsStatusResponse(null).status, isNull);
      expect(parseTsStatusResponse('oops').status, isNull);

      // 阶段以内核为准；本机地址取内核的 IPv4；在线几台没有主控列表时数内核对端
      final s = MeshState(engine: st, stateNodeId: 15);
      expect(meshPhase(enabled: true, running: true, state: s), MeshPhase.connected);
      expect(s.selfAddress(null), '100.69.123.58');
      expect(s.onlineOthers(15), 1);
      expect(s.pathOf(const MeshDevice(id: 3, name: 'openwrt'))!.direct, isTrue);
      const login = TsStatus(state: 'NeedsLogin');
      expect(meshPhase(enabled: true, running: true, state: const MeshState(engine: login)), MeshPhase.joining);
      expect(meshPhase(enabled: true, running: true, state: const MeshState(engine: TsStatus(state: 'Starting'))), MeshPhase.connecting);
      // 内核说没上线时，主控列表里还挂着「在线」也不算已连接
      expect(
        meshPhase(enabled: true, running: true, state: const MeshState(engine: login, devices: [MeshDevice(id: 15, name: 'x', online: true)], stateNodeId: 15)),
        MeshPhase.joining,
      );
    });

    test('主控不可用的原因', () {
      expect(meshAvailabilityOf(null), MeshAvailability.unknown);
      expect(meshAvailabilityOf(''), MeshAvailability.available);
      expect(meshAvailabilityOf('not_admin'), MeshAvailability.notAdmin);
      expect(meshAvailabilityOf('disabled'), MeshAvailability.unavailable);
      expect(meshReasonText('disabled', ''), '主控没有开启喵窝');
      expect(meshReasonText('starting', '喵窝正在启动'), '喵窝正在启动');
    });
  });
}
