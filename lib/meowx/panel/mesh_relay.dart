import 'dart:io';

import 'client.dart';

// 喵窝设备中继：路径上报 / 读取与中继设置的主控接口（接口稿：主控文档仓库 docs/MEOWX_MESH_PEER_RELAY_API.md，
// 客户端规则：MeowX 仓库 Design/mesh-peer-relay.md §2）。都经加密通道，出错时主控回
// `{"error": "<错误码>", "message": "<中文提示>"}` 并保留 HTTP 状态码，所以走 [PanelClient.rpcWithStatus]。

/// 设备中继接口的出错：带 HTTP 状态码与错误码（invalid_request / invalid_port / invalid_endpoint / invalid_ddns_host /
/// share_not_allowed / device_not_found / device_relay_disabled / rate_limited）。
class MeshRelayApiException extends PanelException {
  const MeshRelayApiException(super.message, {required this.status, this.code = ''});

  final int status;
  final String code;

  /// 主控还没有这个接口（老主控）：404 且不是「设备不存在」，或加密通道的白名单里还没有这个路径
  bool get missingEndpoint => (status == 404 && code != 'device_not_found') || (status == 403 && code == 'path not allowed');

  bool get rateLimited => status == 429 || code == 'rate_limited';

  @override
  String toString() => 'HTTP $status${code.isEmpty ? '' : ' $code'}：$message';
}

/// 主控没有这些接口（回 404）后，本次运行先不调，1 小时后再试一次（同一主控的路径 / 中继接口共用）。
class MeshRelayApiGate {
  MeshRelayApiGate({this.retryAfter = const Duration(hours: 1), DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Duration retryAfter;
  final DateTime Function() _now;
  final Map<String, DateTime> _missingAt = {};

  bool allowed(String host) {
    final at = _missingAt[host];
    if (at == null) return true;
    if (_now().difference(at) >= retryAfter) {
      _missingAt.remove(host);
      return true;
    }
    return false;
  }

  void markMissing(String host) => _missingAt[host] = _now();

  /// 调用的结果过一遍：404（接口不存在）就记下
  void observe(String host, Object error) {
    if (error is MeshRelayApiException && error.missingEndpoint) markMissing(host);
  }
}

/// 全进程一份（上报器与页面共用）
final meshRelayApiGate = MeshRelayApiGate();

// ---------------------------------------------------------------------------------------------------------------------
// 路径上报 `POST /user/mesh/paths`

/// 本机到一个对端的路径（上报里的一项）。[path] 是 `peer_relay` / `direct` / `derp`。
class MeshPathPeer {
  const MeshPathPeer({
    required this.ip,
    required this.path,
    this.peerRelay = '',
    this.endpoint = '',
    this.derpRegion = '',
    this.rxBytes = 0,
    this.txBytes = 0,
    this.lastHandshake,
  });

  /// 对端的喵窝 IPv4
  final String ip;
  final String path;
  final String peerRelay;
  final String endpoint;
  final String derpRegion;
  final int rxBytes;
  final int txBytes;
  final DateTime? lastHandshake;

  /// 判断「路径变了」用：类型 + 中继 / 直连地址 / 区域（不含计数）
  String get pathKey => '$path|$peerRelay|$endpoint|$derpRegion';

  Map<String, dynamic> toJson() => {
    'ip': ip,
    'path': path,
    if (peerRelay.isNotEmpty) 'peer_relay': peerRelay,
    if (endpoint.isNotEmpty) 'endpoint': endpoint,
    if (derpRegion.isNotEmpty) 'derp_region': derpRegion,
    'rx_bytes': rxBytes,
    'tx_bytes': txBytes,
    if (lastHandshake != null) 'last_handshake': lastHandshake!.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
  };

  @override
  bool operator ==(Object other) => other is MeshPathPeer && other.pathKey == pathKey && other.ip == ip;

  @override
  int get hashCode => Object.hash(ip, pathKey);
}

/// 拆 `PeerRelay`：官方 tailscaled 写成 `ip:port:vni:12345`（IPv6 `[ip]:port:vni:12345`），自研内核可能写 `ip:port:12345`，
/// 两种都认（同主控 parsePeerRelay）。返回中继的 `ip:port`（与主控 links 的 via_addr 同一写法）与 vni，拆不了为 null。
({String hostPort, int vni})? parseMeshPeerRelay(String s) {
  final i = s.lastIndexOf(':');
  if (i <= 0) return null;
  final vni = int.tryParse(s.substring(i + 1));
  if (vni == null || vni < 0) return null;
  var addr = s.substring(0, i);
  if (addr.endsWith(':vni')) addr = addr.substring(0, addr.length - 4);
  final j = addr.lastIndexOf(':');
  if (j <= 0) return null;
  final port = int.tryParse(addr.substring(j + 1));
  final host = addr.substring(0, j);
  if (port == null || port <= 0 || port > 65535 || host.isEmpty) return null;
  if (host.contains(':') && !(host.startsWith('[') && host.endsWith(']'))) return null;
  return (hostPort: '$host:$port', vni: vni);
}

// ---------------------------------------------------------------------------------------------------------------------
// 读取 `GET /user/mesh/paths`

/// 连接的一端：`device`（本账号或同网络的设备）/ `server`（agent 服务器）/ `other`（其他账号，不给名字）。
class MeshPathEnd {
  const MeshPathEnd({required this.type, this.id, this.name = '', this.ip = ''});

  final String type;
  final int? id;
  final String name;
  final String ip;

  bool get isDevice => type == 'device';
  bool get isOther => type == 'other';

  static MeshPathEnd parse(Object? o) {
    if (o is! Map) return const MeshPathEnd(type: 'other');
    return MeshPathEnd(
      type: o['type']?.toString() ?? 'other',
      id: _int(o['id']),
      name: o['name']?.toString() ?? '',
      ip: o['ip']?.toString() ?? '',
    );
  }

  /// 是这台设备（按编号，主控没给编号时按地址）
  bool matchesDevice({required int id, String ip = ''}) =>
      isDevice && (this.id == id || (this.id == null && ip.isNotEmpty && this.ip == ip));
}

/// 经设备中继时，主控认出的那台中继设备。
class MeshRelayVia {
  const MeshRelayVia({this.deviceId, this.name = '', this.owner = 'self'});

  final int? deviceId;
  final String name;

  /// `self` / `other`（他人的中继）
  final String owner;

  bool get isOther => owner == 'other';

  static MeshRelayVia? parse(Object? o) {
    if (o is! Map) return null;
    return MeshRelayVia(deviceId: _int(o['device_id']), name: o['name']?.toString() ?? '', owner: o['owner']?.toString() ?? 'self');
  }
}

/// 经中继服务器时的区域与服务器名。
class MeshDerpInfo {
  const MeshDerpInfo({this.regionCode = '', this.serverId, this.name = ''});

  final String regionCode;
  final int? serverId;
  final String name;

  static MeshDerpInfo? parse(Object? o) {
    if (o is! Map) return null;
    return MeshDerpInfo(regionCode: o['region_code']?.toString() ?? '', serverId: _int(o['server_id']), name: o['name']?.toString() ?? '');
  }
}

/// 两端之间的一条连接。
class MeshPathLink {
  const MeshPathLink({
    required this.a,
    required this.b,
    required this.path,
    this.via,
    this.viaAddr = '',
    this.derp,
    this.reportedBy = '',
    this.reportedAt,
    this.stale = false,
  });

  final MeshPathEnd a;
  final MeshPathEnd b;

  /// `direct` / `peer_relay` / `derp`（别的值当没有记录）
  final String path;
  final MeshRelayVia? via;

  /// 中继的 `ip:port`（主控对不上是哪台设备时只有它）
  final String viaAddr;
  final MeshDerpInfo? derp;

  /// `a` / `b` / `both`
  final String reportedBy;
  final DateTime? reportedAt;

  /// 最近一次上报超过 3 分钟
  final bool stale;

  static MeshPathLink? parse(Object? o) {
    if (o is! Map) return null;
    return MeshPathLink(
      a: MeshPathEnd.parse(o['a']),
      b: MeshPathEnd.parse(o['b']),
      path: o['path']?.toString() ?? '',
      via: MeshRelayVia.parse(o['via']),
      viaAddr: o['via_addr']?.toString() ?? '',
      derp: MeshDerpInfo.parse(o['derp']),
      reportedBy: o['reported_by']?.toString() ?? '',
      reportedAt: DateTime.tryParse(o['reported_at']?.toString() ?? ''),
      stale: o['stale'] == true,
    );
  }

  /// 另一端（[self] 是其中一端时）
  MeshPathEnd? otherEnd({required int selfId, String selfIp = ''}) {
    if (a.matchesDevice(id: selfId, ip: selfIp)) return b;
    if (b.matchesDevice(id: selfId, ip: selfIp)) return a;
    return null;
  }

  /// 这条连接是不是 [x] 与 [y] 两台设备之间的
  bool between({required int x, String xIp = '', required int y, String yIp = ''}) =>
      (a.matchesDevice(id: x, ip: xIp) && b.matchesDevice(id: y, ip: yIp)) ||
      (a.matchesDevice(id: y, ip: yIp) && b.matchesDevice(id: x, ip: xIp));
}

/// 经某台中继设备的一个会话。
class MeshRelaySession {
  const MeshRelaySession({this.vni, required this.a, required this.b, this.bytes = 0, this.since});

  final int? vni;
  final MeshPathEnd a;
  final MeshPathEnd b;
  final int bytes;
  final DateTime? since;

  static MeshRelaySession? parse(Object? o) {
    if (o is! Map) return null;
    return MeshRelaySession(
      vni: _int(o['vni']),
      a: MeshPathEnd.parse(o['a']),
      b: MeshPathEnd.parse(o['b']),
      bytes: _int(o['bytes']) ?? 0,
      since: DateTime.tryParse(o['since']?.toString() ?? ''),
    );
  }
}

/// 本账号可见的一台中继设备（`paths` 的 `relays[]`）。别人设为共享的只有 id / 名字 / 主人 / 状态，没有会话。
class MeshRelayInfo {
  const MeshRelayInfo({
    required this.deviceId,
    this.name = '',
    this.owner = 'self',
    this.share = '',
    this.state = '',
    this.port,
    this.sessions = const [],
    this.unmatchedSessions = 0,
  });

  final int deviceId;
  final String name;
  final String owner;
  final String share;
  final String state;
  final int? port;
  final List<MeshRelaySession> sessions;
  final int unmatchedSessions;

  bool get mine => owner != 'other';

  static MeshRelayInfo? parse(Object? o) {
    if (o is! Map) return null;
    final id = _int(o['device_id']);
    if (id == null) return null;
    return MeshRelayInfo(
      deviceId: id,
      name: o['name']?.toString() ?? '',
      owner: o['owner']?.toString() ?? 'self',
      share: o['share']?.toString() ?? '',
      state: o['state']?.toString() ?? '',
      port: _int(o['port']),
      sessions: [for (final s in _list(o['sessions'])) ?MeshRelaySession.parse(s)],
      unmatchedSessions: _int(o['unmatched_sessions']) ?? 0,
    );
  }
}

/// `GET /user/mesh/paths` 的应答。
class MeshPathsSnapshot {
  const MeshPathsSnapshot({this.updatedAt, this.links = const [], this.relays = const []});

  final DateTime? updatedAt;
  final List<MeshPathLink> links;
  final List<MeshRelayInfo> relays;

  static MeshPathsSnapshot parse(Map<String, dynamic> r) => MeshPathsSnapshot(
    updatedAt: DateTime.tryParse(r['updated_at']?.toString() ?? ''),
    links: [
      for (final l in _list(r['links']))
        if (MeshPathLink.parse(l) case final link? when const {'direct', 'peer_relay', 'derp'}.contains(link.path)) link,
    ],
    relays: [for (final x in _list(r['relays'])) ?MeshRelayInfo.parse(x)],
  );

  /// 本机 [selfId] 与设备 [deviceId] 之间的连接
  MeshPathLink? linkBetween({required int selfId, String selfIp = '', required int deviceId, String deviceIp = ''}) {
    for (final l in links) {
      if (l.between(x: selfId, xIp: selfIp, y: deviceId, yIp: deviceIp)) return l;
    }
    return null;
  }

  MeshRelayInfo? relayOf(int deviceId) {
    for (final r in relays) {
      if (r.deviceId == deviceId) return r;
    }
    return null;
  }

  /// 按中继地址（`ip:port`）找主控认出的中继设备名
  MeshRelayVia? viaForAddress(String hostPort) {
    if (hostPort.isEmpty) return null;
    for (final l in links) {
      if (l.path == 'peer_relay' && l.via != null && l.viaAddr == hostPort) return l.via;
    }
    return null;
  }

  /// 按中继服务器的区域代码找服务器名
  MeshDerpInfo? derpForRegion(String code) {
    if (code.isEmpty) return null;
    for (final l in links) {
      if (l.derp case final d? when d.regionCode == code && d.name.isNotEmpty) return d;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// 中继设置 `GET /user/mesh/relay[?device_id=]`、`PUT /user/mesh/devices/{id}/relay`

/// 中继设备的状态：disabled / pending / active / version_too_old / error / offline。
abstract final class MeshRelayState {
  static const disabled = 'disabled';
  static const pending = 'pending';
  static const active = 'active';
  static const versionTooOld = 'version_too_old';
  static const error = 'error';
  static const offline = 'offline';
}

/// 一台设备的中继配置与状态。
class MeshRelayConfig {
  const MeshRelayConfig({
    required this.deviceId,
    this.name = '',
    this.enabled = false,
    this.port = defaultPort,
    this.staticEndpoints = const [],
    this.ddnsHost = '',
    this.share = 'self',
    this.state = MeshRelayState.disabled,
    this.message = '',
    this.capable = false,
    this.tailscaleVersion = '',
    this.reportedAt,
  });

  static const defaultPort = 40000;
  static const maxStaticEndpoints = 4;

  final int deviceId;
  final String name;
  final bool enabled;
  final int port;
  final List<String> staticEndpoints;
  final String ddnsHost;

  /// `self` / `all`
  final String share;
  final String state;
  final String message;

  /// 上报过中继能力（装的是支持设备中继的 MeowX：OpenWrt / 飞牛 / Docker）：只对这种设备显示开关
  final bool capable;
  final String tailscaleVersion;
  final DateTime? reportedAt;

  static MeshRelayConfig? parse(Object? o) {
    if (o is! Map) return null;
    final id = _int(o['device_id']);
    if (id == null) return null;
    final port = _int(o['port']);
    return MeshRelayConfig(
      deviceId: id,
      name: o['name']?.toString() ?? '',
      enabled: o['enabled'] == true,
      port: port == null || port == 0 ? defaultPort : port,
      staticEndpoints: [for (final e in _list(o['static_endpoints'])) e.toString()],
      ddnsHost: o['ddns_host']?.toString() ?? '',
      share: o['share']?.toString() == 'all' ? 'all' : 'self',
      state: o['state']?.toString() ?? MeshRelayState.disabled,
      message: o['message']?.toString() ?? '',
      capable: o['capable'] == true,
      tailscaleVersion: o['tailscale_version']?.toString() ?? '',
      reportedAt: DateTime.tryParse(o['reported_at']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toPayload() => {
    'enabled': enabled,
    'port': port,
    'static_endpoints': staticEndpoints,
    'ddns_host': ddnsHost,
    'share': share,
  };

  MeshRelayConfig copyWith({bool? enabled, int? port, List<String>? staticEndpoints, String? ddnsHost, String? share}) =>
      MeshRelayConfig(
        deviceId: deviceId,
        name: name,
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        staticEndpoints: staticEndpoints ?? this.staticEndpoints,
        ddnsHost: ddnsHost ?? this.ddnsHost,
        share: share ?? this.share,
        state: state,
        message: message,
        capable: capable,
        tailscaleVersion: tailscaleVersion,
        reportedAt: reportedAt,
      );
}

/// 本地先查一遍表单（主控还会再查）：返回出错的字段码（同主控错误码）与说明用的参数，null = 通过。
String? validateMeshRelayForm({required int? port, required List<String> staticEndpoints, required String ddnsHost}) {
  if (port == null || port < 1024 || port > 65535) return 'invalid_port';
  if (staticEndpoints.length > MeshRelayConfig.maxStaticEndpoints) return 'invalid_endpoint';
  for (final e in staticEndpoints) {
    if (!isPublicMeshRelayEndpoint(e)) return 'invalid_endpoint';
  }
  if (ddnsHost.isNotEmpty && !_hostRe.hasMatch(ddnsHost)) return 'invalid_ddns_host';
  return null;
}

/// 静态地址：公网 `IPv4:端口` 或 `[IPv6]:端口`（主控拒私网、回环、链路本地与喵窝地址，这里先挡一遍）
bool isPublicMeshRelayEndpoint(String e) {
  final i = e.lastIndexOf(':');
  if (i <= 0) return false;
  final port = int.tryParse(e.substring(i + 1));
  if (port == null || port < 1 || port > 65535) return false;
  final host = e.substring(0, i);
  if (host.startsWith('[') && host.endsWith(']')) {
    final a = InternetAddress.tryParse(host.substring(1, host.length - 1));
    if (a == null || a.type != InternetAddressType.IPv6) return false;
    final b = a.rawAddress;
    // 只认全球单播 2000::/3（排除 ::1、fe80::/10、fc00::/7——喵窝的 fd7a:115c:a1e0::/48 也在其中、文档段 2001:db8::/32 不管）
    return (b[0] & 0xe0) == 0x20;
  }
  final a = InternetAddress.tryParse(host);
  if (a == null || a.type != InternetAddressType.IPv4 || host.contains(':')) return false;
  final b = a.rawAddress;
  if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return false;
  if (b[0] == 169 && b[1] == 254) return false;
  if (b[0] == 172 && b[1] >= 16 && b[1] < 32) return false;
  if (b[0] == 192 && b[1] == 168) return false;
  if (b[0] == 100 && b[1] >= 64 && b[1] < 128) return false; // 100.64.0.0/10：喵窝 / 运营商 NAT
  return true;
}
final _hostRe = RegExp(r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$');

// ---------------------------------------------------------------------------------------------------------------------

/// 设备中继的主控接口。都先过 [meshRelayApiGate]（主控没有这些接口时 1 小时内不再调），出错抛 [MeshRelayApiException]。
extension MeshRelayPanelApi on PanelClient {
  Future<Map<String, dynamic>> _relayRpc(String path, {required String method, required String token, Map<String, dynamic> payload = const {}}) async {
    if (!meshRelayApiGate.allowed(host)) {
      throw const MeshRelayApiException('主控还不支持设备中继', status: 404);
    }
    final r = await rpcWithStatus(path, method: method, token: token, payload: payload);
    final code = r.body['error']?.toString() ?? '';
    final ok = r.status >= 200 && r.status < 300 && code.isEmpty;
    if (ok) return r.body;
    final e = MeshRelayApiException(
      r.body['message']?.toString() ?? (code.isEmpty ? '请求失败（HTTP ${r.status}）' : code),
      status: r.status >= 200 && r.status < 300 ? 400 : r.status,
      code: code,
    );
    meshRelayApiGate.observe(host, e);
    throw e;
  }

  Future<void> meshReportPaths(String token, {required int deviceId, required List<MeshPathPeer> peers}) async {
    await _relayRpc(
      '/user/mesh/paths',
      method: 'POST',
      token: token,
      payload: {'device_id': deviceId, 'peers': [for (final p in peers) p.toJson()]},
    );
  }

  Future<MeshPathsSnapshot> meshPaths(String token, {int? deviceId}) async => MeshPathsSnapshot.parse(
    await _relayRpc(deviceId == null ? '/user/mesh/paths' : '/user/mesh/paths?device_id=$deviceId', method: 'GET', token: token),
  );

  /// 本账号配置过或上报过中继能力的设备
  Future<List<MeshRelayConfig>> meshRelays(String token) async {
    final r = await _relayRpc('/user/mesh/relay', method: 'GET', token: token);
    return [for (final x in _list(r['relays'])) ?MeshRelayConfig.parse(x)];
  }

  Future<MeshRelayConfig?> meshRelay(String token, int deviceId) async =>
      MeshRelayConfig.parse(await _relayRpc('/user/mesh/relay?device_id=$deviceId', method: 'GET', token: token));

  Future<MeshRelayConfig?> meshSetRelay(String token, MeshRelayConfig config) async => MeshRelayConfig.parse(
    await _relayRpc('/user/mesh/devices/${config.deviceId}/relay', method: 'PUT', token: token, payload: config.toPayload()),
  );
}

List<Object?> _list(Object? o) => o is List ? o : const [];

int? _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};
