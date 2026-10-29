import 'dart:async';
import 'dart:convert';

import 'package:bett_box/meowx/panel/ggy.dart';
import 'package:bett_box/meowx/state/ggy_reporter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

// 只用假 token。
const _a = 'ctecsfw_TESTtoken0000000000AAAA';
const _b = 'ctecsfw_TESTtoken0000000000BBBB';
const _invalidBody = '{"status":400,"msg":"白名单分享链接无效或已失效","data":[]}';

/// 装配一个全假依赖的 Reporter：记下每次交给核心的 url、日志与结论回调，网络事件由测试自己推。
/// 定时间隔缩到几十毫秒，用真实时钟跑（同 po0_reporter_test）。
class _Harness {
  _Harness({this.enabled = true, List<String>? tokens, this.interval = const Duration(milliseconds: 60)})
    : tokens = tokens ?? const [_a] {
    reporter = GgyReporter(
      isEnabled: () => enabled,
      tokens: () => this.tokens,
      send: (urls) async {
        sends.add(urls);
        await sendGate?.future;
        if (failSend) throw Exception('core gone ${urls.first}');
        return json.encode([
          for (final u in urls) {'url': u, 'status': 200, 'body': u.endsWith('BBBB') ? _invalidBody : '{"status":200,"msg":"ok"}'},
        ]);
      },
      connectivity: () => conn.stream,
      log: logs.add,
      onResults: results.add,
      interval: interval,
      connectivityDebounce: debounce,
    );
  }

  final Duration interval;
  static const debounce = Duration(milliseconds: 20);

  bool enabled;
  List<String> tokens;
  bool failSend = false;
  late final GgyReporter reporter;
  final conn = StreamController<List<ConnectivityResult>>.broadcast();
  final logs = <String>[];
  final sends = <List<String>>[];
  final results = <Map<String, GgyResult>>[];

  /// 非空时上报卡在这里，测「在飞」
  Completer<void>? sendGate;

  Future<void> tick() => Future<void>.delayed(interval + debounce * 2);

  void dispose() {
    reporter.stop(notify: false);
    conn.close();
  }
}

void main() {
  test('开关关着 / 没有 token：不报、不起定时器', () async {
    final off = _Harness(enabled: false);
    await off.reporter.sync(reportNow: true);
    await off.reporter.report();
    expect(off.sends, isEmpty);
    expect(off.reporter.isWatching, isFalse);
    await off.tick();
    expect(off.sends, isEmpty);
    off.dispose();

    final empty = _Harness(tokens: const []);
    await empty.reporter.sync(reportNow: true);
    expect(empty.sends, isEmpty);
    expect(empty.reporter.isWatching, isFalse);
    empty.dispose();
  });

  test('打开：每个 token 立刻报一次（GET 地址由 token 拼出），日志只有脱敏写法；之后定时重报', () async {
    final h = _Harness(tokens: const [_a, _b]);
    await h.reporter.sync(reportNow: true);
    expect(h.sends, [
      [ggyReportUrl(_a), ggyReportUrl(_b)],
    ]);
    expect(h.logs, [
      'GGY 加白 ctecsfw_••••AAAA：成功（ok）',
      'GGY 加白 ctecsfw_••••BBBB：失败（白名单分享链接无效或已失效）',
    ]);
    expect(h.logs.join(), isNot(contains('TESTtoken')));
    expect(h.reporter.results[_a]!.ok, isTrue);
    expect(h.reporter.results[_b]!.kind, GgyResultKind.tokenInvalid);
    expect(h.results.length, 1);
    expect(h.reporter.isWatching, isTrue);

    await h.tick();
    expect(h.sends.length, greaterThanOrEqualTo(2));
    h.dispose();
  });

  test('只同步（不立刻报）：起定时器但这一刻不报；删掉的 token 结论一并丢掉', () async {
    final h = _Harness(tokens: const [_a, _b], interval: const Duration(hours: 1));
    await h.reporter.sync(reportNow: true);
    expect(h.sends.length, 1);

    h.tokens = const [_a];
    await h.reporter.sync();
    expect(h.sends.length, 1);
    expect(h.reporter.results.keys, [_a]);
    expect(h.results.last.keys, [_a]);
    h.dispose();
  });

  test('网络变化：防抖后只报一次；同一组状态反复推、全 none 不报', () async {
    final h = _Harness(interval: const Duration(hours: 1));
    await h.reporter.sync(reportNow: true);
    expect(h.sends.length, 1);

    h.conn.add([ConnectivityResult.wifi]);
    h.conn.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends.length, 2);

    h.conn.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends.length, 2);

    h.conn.add([ConnectivityResult.none]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends.length, 2);
    h.dispose();
  });

  test('关掉 / token 删光：停表、清掉结论，之后定时与网络变化都不再报', () async {
    final h = _Harness();
    await h.reporter.sync(reportNow: true);
    expect(h.reporter.results, isNotEmpty);

    h.enabled = false;
    await h.reporter.sync();
    expect(h.reporter.isWatching, isFalse);
    expect(h.reporter.results, isEmpty);
    expect(h.results.last, isEmpty);
    h.conn.add([ConnectivityResult.wifi]);
    await h.tick();
    expect(h.sends.length, 1);

    h.enabled = true;
    await h.reporter.sync(reportNow: true);
    expect(h.sends.length, 2);
    h.tokens = const [];
    await h.reporter.sync();
    expect(h.reporter.isWatching, isFalse);
    await h.tick();
    expect(h.sends.length, 2);
    h.dispose();
  });

  test('上报在飞时再来一次：等它结束后补一趟，新加的 token 不用等下一个周期', () async {
    final h = _Harness(interval: const Duration(hours: 1))..sendGate = Completer<void>();
    final first = h.reporter.sync(reportNow: true);
    await Future<void>.delayed(Duration.zero);
    expect(h.sends.length, 1);

    h.tokens = const [_a, _b];
    unawaited(h.reporter.sync(reportNow: true));
    h.sendGate!.complete();
    h.sendGate = null;
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.sends.length, 2);
    expect(h.sends.last, [ggyReportUrl(_a), ggyReportUrl(_b)]);
    h.dispose();
  });

  test('核心调用异常：一行日志（脱敏），每个 token 记失败', () async {
    final h = _Harness(interval: const Duration(hours: 1))..failSend = true;
    await h.reporter.sync(reportNow: true);
    expect(h.logs, ['GGY 加白失败：核心调用异常 Exception: core gone ${ggyReportUrl('ctecsfw_••••AAAA')}']);
    expect(h.reporter.results[_a]!.summary, '失败：核心调用异常');
    h.dispose();
  });
}
