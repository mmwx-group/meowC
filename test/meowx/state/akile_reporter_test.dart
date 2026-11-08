import 'dart:async';
import 'dart:convert';

import 'package:bett_box/meowx/panel/akile.dart';
import 'package:bett_box/meowx/state/akile_reporter.dart';
import 'package:bett_box/models/meow.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

// 只用假 Key。
const _key = 'ak_TESTkey0000000000AAAA';
const _a = MeowAkileNode(name: '香港', port: 443, ruleId: 1);
const _b = MeowAkileNode(name: '日本', port: 8443, ruleId: 2);

/// 假核心：按参数回一轮结果（定时轮里 skip_ip 等于当前出口 IP 的回 skipped），记下每次的参数。
class _Harness {
  _Harness({
    this.enabled = true,
    this.key = _key,
    List<MeowAkileNode>? nodes,
    this.interval = const Duration(milliseconds: 60),
  }) : nodes = nodes ?? const [_a] {
    reporter = AkileReporter(
      isEnabled: () => enabled,
      apiKey: () => key,
      nodes: () => this.nodes,
      send: (params, timeout) async {
        final p = json.decode(params) as Map<String, dynamic>;
        sends.add(p);
        timeouts.add(timeout);
        await sendGate?.future;
        if (failSend) throw Exception('core gone $_key');
        if (exitIp.isEmpty) {
          return json.encode({
            'ip_error': 'ip.3322.net：超时',
            'results': [
              for (final n in p['nodes'] as List)
                {'rule_id': n['rule_id'], 'kind': 'failed', 'error': '查不到本机直连出口 IPv4'},
            ],
          });
        }
        return json.encode({
          'ip': exitIp,
          'results': [
            for (final n in p['nodes'] as List)
              if (p['timer'] == true && n['skip_ip'] == exitIp)
                {'rule_id': n['rule_id'], 'ok': true, 'kind': 'skipped', 'ip': exitIp}
              else if (reply[n['rule_id']] != null)
                reply[n['rule_id']]!
              else
                {'rule_id': n['rule_id'], 'ok': true, 'kind': 'updated', 'ip': exitIp, 'previous': '198.51.100.1'},
          ],
        });
      },
      connectivity: () => conn.stream,
      log: logs.add,
      onResults: results.add,
      interval: interval,
      connectivityDebounce: debounce,
      foregroundThrottle: const Duration(minutes: 1),
      now: () => clock,
    );
  }

  final Duration interval;
  static const debounce = Duration(milliseconds: 20);

  bool enabled;
  String key;
  List<MeowAkileNode> nodes;
  String exitIp = '203.0.113.10';
  bool failSend = false;
  DateTime clock = DateTime(2026, 11, 8, 9);
  final reply = <int, Map<String, Object?>>{};
  late final AkileReporter reporter;
  final conn = StreamController<List<ConnectivityResult>>.broadcast();
  final logs = <String>[];
  final sends = <Map<String, dynamic>>[];
  final timeouts = <Duration>[];
  final results = <Map<int, AkileResult>>[];

  /// 非空时上报卡在这里，测「在飞」
  Completer<void>? sendGate;

  List<int> ruleIds(int i) => [for (final n in sends[i]['nodes'] as List) n['rule_id'] as int];

  Future<void> tick() => Future<void>.delayed(interval + debounce * 2);

  void dispose() {
    reporter.stop(notify: false);
    conn.close();
  }
}

void main() {
  test('开关关着 / Key 不合法 / 没有节点：不报、不起定时器', () async {
    for (final h in [
      _Harness(enabled: false),
      _Harness(key: 'ak_short'),
      _Harness(key: ''),
      _Harness(nodes: const []),
    ]) {
      await h.reporter.sync(reportNow: true);
      await h.reporter.report();
      h.reporter.onForeground();
      expect(h.sends, isEmpty);
      expect(h.reporter.isWatching, isFalse);
      await h.tick();
      expect(h.sends, isEmpty);
      h.dispose();
    }
  });

  test('打开：全部节点立刻报一次（不是定时轮）；日志每个节点一行、不含 Key；结论按规则 ID', () async {
    final h = _Harness(nodes: const [_a, _b]);
    await h.reporter.sync(reportNow: true);
    expect(h.sends, hasLength(1));
    expect(h.sends.single['op'], 'report');
    expect(h.sends.single['key'], _key);
    expect(h.sends.single['timer'], isFalse);
    expect(h.ruleIds(0), [1, 2]);
    expect((h.sends.single['nodes'] as List).first, {'rule_id': 1, 'name': '香港'});
    expect(h.timeouts.single, const Duration(seconds: 30));
    expect(h.logs, [
      'AkileCDN 白名单 香港（规则 #1）：已更新 198.51.100.1 → 203.0.113.10',
      'AkileCDN 白名单 日本（规则 #2）：已更新 198.51.100.1 → 203.0.113.10',
    ]);
    expect(h.reporter.results.keys, [1, 2]);
    expect(h.reporter.results[1]!.okIp, '203.0.113.10');
    expect(h.reporter.isWatching, isTrue);
    h.dispose();
  });

  test('定时轮：带上每个节点上一次成功写入的 IP，IP 没变的跳过（结论与时间不变、不记日志）；上次失败的照样写', () async {
    final h = _Harness(nodes: const [_a, _b]);
    h.reply[2] = {'rule_id': 2, 'ok': false, 'kind': 'not_found', 'error': '规则不存在（已删除，或不属于这个 API Key 的账号）'};
    await h.reporter.sync(reportNow: true);
    final first = h.reporter.results[1]!;
    expect(h.reporter.results[2]!.ok, isFalse);
    h.logs.clear();

    h.clock = h.clock.add(const Duration(minutes: 10));
    await h.tick();
    expect(h.sends.length, greaterThanOrEqualTo(2));
    final timer = h.sends[1];
    expect(timer['timer'], isTrue);
    expect(timer['nodes'], [
      {'rule_id': 1, 'name': '香港', 'skip_ip': '203.0.113.10'},
      {'rule_id': 2, 'name': '日本'}, // 上次失败：不带 skip_ip，一定写
    ]);
    expect(h.reporter.results[1], first);
    expect(h.logs.where((l) => l.contains('香港')), isEmpty);
    expect(h.logs.where((l) => l.contains('日本')), isNotEmpty);

    // IP 变了：定时轮照写
    h.exitIp = '198.51.100.7';
    final before = h.sends.length;
    await h.tick();
    expect(h.sends.length, greaterThan(before));
    expect(h.reporter.results[1]!.ip, '198.51.100.7');
    h.dispose();
  });

  test('新加节点只报它自己；删节点不报、结论跟着丢', () async {
    final h = _Harness();
    await h.reporter.sync(reportNow: true);
    h.nodes = const [_a, _b];
    await h.reporter.sync(reportNow: true, only: {2});
    expect(h.ruleIds(1), [2]);
    expect(h.reporter.results.keys.toSet(), {1, 2});

    h.nodes = const [_b];
    await h.reporter.sync();
    expect(h.sends, hasLength(2));
    expect(h.reporter.results.keys, [2]);
    h.dispose();
  });

  test('网络变化（防抖、同一组状态不重报）与回前台（节流）都是全部报、不是定时轮', () async {
    final h = _Harness(interval: const Duration(seconds: 30));
    await h.reporter.sync();
    expect(h.sends, isEmpty);
    h.conn.add([ConnectivityResult.wifi]);
    h.conn.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, hasLength(1));
    expect(h.sends.last['timer'], isFalse);
    h.conn.add([ConnectivityResult.none]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, hasLength(1));
    h.conn.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, hasLength(2));

    h.reporter.onForeground();
    await Future<void>.delayed(Duration.zero);
    expect(h.sends, hasLength(3));
    expect(h.sends.last['timer'], isFalse);
    h.clock = h.clock.add(const Duration(seconds: 20));
    h.reporter.onForeground();
    await Future<void>.delayed(Duration.zero);
    expect(h.sends, hasLength(3));
    h.clock = h.clock.add(const Duration(minutes: 1));
    h.reporter.onForeground();
    await Future<void>.delayed(Duration.zero);
    expect(h.sends, hasLength(4));
    h.dispose();
  });

  test('在飞时又要报：合并成一次；有一次要全部就全部、全是定时轮才算定时轮', () async {
    final h = _Harness(nodes: const [_a, _b], interval: const Duration(seconds: 30));
    await h.reporter.sync();
    h.sendGate = Completer<void>();
    final first = h.reporter.report(only: {1});
    await Future<void>.delayed(Duration.zero);
    unawaited(h.reporter.report(timer: true, only: {2}));
    unawaited(h.reporter.report(timer: true));
    h.sendGate!.complete();
    h.sendGate = null;
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.sends, hasLength(2));
    expect(h.ruleIds(1), [1, 2]);
    expect(h.sends[1]['timer'], isTrue);

    h.sendGate = Completer<void>();
    final again = h.reporter.report(timer: true);
    await Future<void>.delayed(Duration.zero);
    unawaited(h.reporter.report(timer: true));
    unawaited(h.reporter.report());
    h.sendGate!.complete();
    h.sendGate = null;
    await again;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.sends, hasLength(4));
    expect(h.sends[3]['timer'], isFalse);
    h.dispose();
  });

  test('查不到出口 IP：一行日志带原因，全部节点记失败；核心调用异常也记失败，日志不含 Key', () async {
    final h = _Harness(nodes: const [_a, _b]);
    h.exitIp = '';
    await h.reporter.sync(reportNow: true);
    expect(h.logs, ['AkileCDN 白名单：查不到本机直连出口 IPv4（ip.3322.net：超时）']);
    expect(h.reporter.results.values.map((r) => r.error), ['查不到本机直连出口 IPv4', '查不到本机直连出口 IPv4']);

    h.failSend = true;
    h.logs.clear();
    await h.reporter.report();
    expect(h.logs.single, startsWith('AkileCDN 白名单失败：核心调用异常'));
    expect(h.logs.single, contains('ak_••••AAAA'));
    expect(h.logs.single, isNot(contains('TESTkey')));
    expect(h.reporter.results.values.every((r) => r.error == '核心调用异常'), isTrue);
    h.dispose();
  });

  test('关掉：停表、清结论、回调空表', () async {
    final h = _Harness();
    await h.reporter.sync(reportNow: true);
    expect(h.results.last.keys, [1]);
    h.enabled = false;
    await h.reporter.sync(reportNow: true);
    expect(h.reporter.isWatching, isFalse);
    expect(h.reporter.results, isEmpty);
    expect(h.results.last, isEmpty);
    final n = h.sends.length;
    await h.tick();
    expect(h.sends, hasLength(n));
    h.dispose();
  });
}
