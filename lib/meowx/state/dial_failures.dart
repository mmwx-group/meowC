import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'status.dart';

/// 一条拨号失败记录（同 iOS 动态页的「失败：原因 ×N · 时刻」）。
/// 内核没有现成的失败记录接口：mihomo 拨号失败时打一条 warning 日志
/// 「[TCP] dial 出站 (match 规则/参数) 来源 --> 目标 error: 原因」，「记录日志」关着时内核日志也照样订阅（等级 warning），
/// 这里逐条解析。日志等级被手动调到 error / silent 时就收不到。
@immutable
class DialFailure {
  const DialFailure({
    required this.seq,
    required this.network,
    required this.proxy,
    required this.rule,
    required this.payload,
    required this.host,
    required this.port,
    required this.reason,
    required this.at,
    this.count = 1,
  });

  /// 进程内递增的编号（列表的 key、合成连接的 id）
  final int seq;
  final String network, proxy, rule, payload, host, port, reason;

  /// 最后一次失败的时刻
  final DateTime at;

  /// 合并进来的次数
  final int count;

  DialFailure bump(DateTime when) => DialFailure(
    seq: seq,
    network: network,
    proxy: proxy,
    rule: rule,
    payload: payload,
    host: host,
    port: port,
    reason: reason,
    at: when,
    count: count + 1,
  );

  bool _sameAs(DialFailure o) => o.host == host && o.port == port && o.proxy == proxy && o.network == network && o.reason == reason;

  /// 套成一条连接（沿用连接列表的行、搜索与类型筛选）：没有流量，开始时刻 = 最后一次失败。
  TrackerInfo get info {
    final ip = _isIp(host);
    return TrackerInfo(
      id: 'fail:$seq',
      start: at,
      metadata: Metadata(
        network: network.toLowerCase(),
        host: ip ? '' : host,
        destinationIP: ip ? host : '',
        destinationPort: port,
      ),
      chains: [proxy],
      rule: rule,
      rulePayload: payload,
    );
  }
}

bool _isIp(String h) => RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h) || h.contains(':');

/// 拨号失败日志里来源的写法：「IP:端口」「[v6]:端口」后面可能跟「(进程, uid=…)」，内核自己拨的是「Mihomo」。
final _withMatch = RegExp(r'^\[(TCP|UDP)\] dial (.+?) \(match (.+?)/(.*?)\) .+? --> (\S+) error: (.+)$', dotAll: true);
final _noMatch = RegExp(
  r'^\[(TCP|UDP)\] dial (.+?) (?:\d{1,3}(?:\.\d{1,3}){3}:\d+|\[[0-9a-fA-F:.]+\]:\d+|Mihomo)\S*(?: [^>]*)? --> (\S+) error: (.+)$',
  dotAll: true,
);

/// 解析一条内核日志；不是拨号失败就是 null。
@visibleForTesting
DialFailure? parseDialFailure(String payload, DateTime at, {int seq = 0}) {
  if (!payload.contains(' dial ') || !payload.contains(' error: ')) return null;
  String network, proxy, rule = '', rulePayload = '', dst, reason;
  final m = _withMatch.firstMatch(payload);
  if (m != null) {
    network = m[1]!;
    proxy = m[2]!;
    rule = m[3]!;
    rulePayload = m[4]!;
    dst = m[5]!;
    reason = m[6]!;
  } else {
    final n = _noMatch.firstMatch(payload);
    if (n == null) return null;
    network = n[1]!;
    proxy = n[2]!;
    dst = n[3]!;
    reason = n[4]!;
  }
  final colon = dst.lastIndexOf(':');
  if (colon <= 0) return null;
  var host = dst.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
  return DialFailure(
    seq: seq,
    network: network,
    proxy: proxy,
    rule: rule,
    payload: rulePayload,
    host: host,
    port: dst.substring(colon + 1),
    reason: reason.trim(),
    at: at,
  );
}

/// 最近的拨号失败（新的在前，至多 [capacity] 条）：同主机 / 端口 / 出站 / 网络 / 原因在 [mergeWindow] 内连着失败合成一条计次（同 iOS）。
class DialFailureLog {
  static const capacity = 100;
  static const mergeWindow = Duration(seconds: 5);

  List<DialFailure> _items = const [];
  int _seq = 0;

  List<DialFailure> get items => _items;

  /// 记一条；返回记没记（不是拨号失败的日志不记）。
  bool record(String payload, DateTime at) {
    final f = parseDialFailure(payload, at, seq: _seq + 1);
    if (f == null) return false;
    for (final (i, old) in _items.indexed) {
      if (at.difference(old.at) > mergeWindow) break;   // 新的在前：再往后的更旧
      if (old._sameAs(f)) {
        _items = List.unmodifiable([old.bump(at), ..._items.sublist(0, i), ..._items.sublist(i + 1)]);
        return true;
      }
    }
    _seq++;
    final next = [f, ..._items];
    _items = List.unmodifiable(next.length > capacity ? next.sublist(0, capacity) : next);
    return true;
  }

  void clear() => _items = const [];
}

/// 记录器挂在壳上常驻（MeowRoot listen 着）：不在动态页时失败照样记；断开代理、内核重启时清空（同「已关闭」）。
class DialFailuresController extends Notifier<List<DialFailure>> {
  final _log = DialFailureLog();

  @override
  List<DialFailure> build() {
    ref.listen(logsProvider, (prev, next) {
      final list = next.list;
      if (list.isEmpty) return;
      // 日志是逐条追加的（一次一条 microtask）：从尾巴往前找，碰到上一份的最后一条为止
      final prevLast = prev == null || prev.list.isEmpty ? null : prev.list.last;
      var changed = false;
      final now = DateTime.now();
      for (var i = list.length - 1; i >= 0; i--) {
        final l = list[i];
        if (identical(l, prevLast)) break;
        if (l.logLevel == LogLevel.warning && _log.record(l.payload, now)) changed = true;
        if (prevLast == null) break;   // 没有上一份可比：只看最新这条
      }
      if (changed) state = _log.items;
    });
    ref.listen(isRunningProvider, (prev, next) => _clear());
    ref.listen(isRestartingCoreProvider, (prev, next) => _clear());
    return const [];
  }

  void _clear() {
    _log.clear();
    state = const [];
  }
}

final dialFailuresProvider = NotifierProvider<DialFailuresController, List<DialFailure>>(DialFailuresController.new);
