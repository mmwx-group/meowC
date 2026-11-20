import 'dart:convert';
import 'dart:async';

import 'package:bett_box/meowx/panel/po0.dart';
import 'package:bett_box/meowx/state/po0_reporter.dart';
import 'package:bett_box/models/meow.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// 装配一个全假依赖的 Reporter：计数拉列表 / 上报次数，记录日志，网络事件由测试自己推。
/// 定时间隔缩到几十毫秒，用真实时钟跑（fake_async 不是直接依赖，不为测试改 pubspec）。
class _Harness {
  _Harness({this.enabled = false, this.interval = const Duration(milliseconds: 60), List<ConnectivityResult>? current}) {
    reporter = Po0Reporter(
      isEnabled: () => enabled,
      fetchServers: () async {
        fetches++;
        if (failFetch) throw Exception('boom');
        return servers;
      },
      customServers: () => custom,
      send: (urls) async {
        sends++;
        sentUrls = urls;
        await sendGate?.future;
        if (reply != null) return reply!(urls);
        return '[{"url":"${urls.first}","status":200,"body":"{\\"enabled\\":true,\\"whitelist\\":[{\\"ip\\":\\"1.2.3.4\\",\\"slot\\":1}],\\"limit\\":5,\\"currentIp\\":\\"1.2.3.4\\"}"}]';
      },
      connectivity: () => conn.stream,
      currentConnectivity: current == null ? null : () async => current,
      onDirectHosts: directHosts.add,
      onResults: resultEvents.add,
      onPanelServers: panelEvents.add,
      log: logs.add,
      interval: interval,
      connectivityDebounce: debounce,
    );
  }

  final Duration interval;
  static const debounce = Duration(milliseconds: 20);

  bool enabled;
  late final Po0Reporter reporter;
  final conn = StreamController<List<ConnectivityResult>>.broadcast();
  final logs = <String>[];
  int fetches = 0, sends = 0;
  bool failFetch = false;
  final directHosts = <List<String>>[];
  final resultEvents = <Map<String, Po0Result>>[];
  final panelEvents = <List<Po0Server>>[];

  /// 非空时用它造核心的应答（缺省只回第一个地址的成功应答）
  String Function(List<String> urls)? reply;
  List<String> sentUrls = const [];
  List<Po0Server>? servers = const [
    Po0Server(serverId: 2, name: 'AgentB-Exit', ip: '209.248.57.93', token: 't', url: 'https://209.248.57.93/api/firewall/t/add?slot=1', slot: 1),
  ];

  /// 用户自己添加的条目
  List<Po0CustomServer> custom = const [];

  /// 非空时上报卡在这里，测「在飞」
  Completer<void>? sendGate;

  /// 等一个多定时周期
  Future<void> tick() => Future<void>.delayed(interval + debounce * 2);

  void dispose() {
    reporter.stop(notify: false);
    conn.close();
  }
}

void main() {
  test('开关关着：不拉列表、不上报、不起定时器', () async {
    final h = _Harness(enabled: false);
    await h.reporter.refresh(force: true);
    await h.reporter.report();
    expect(h.fetches, 0);
    expect(h.sends, 0);
    expect(h.reporter.isWatching, isFalse);
    expect(h.reporter.servers, isEmpty);
    await h.tick();
    expect(h.sends, 0);
    h.dispose();
  });

  test('打开：立刻拉列表并上报，之后定时重拉重报', () async {
    final h = _Harness(enabled: true);
    await h.reporter.refresh(force: true);
    expect(h.fetches, 1);
    expect(h.sends, 1);
    expect(h.sentUrls, ['https://209.248.57.93/api/firewall/t/add?slot=1']);
    expect(h.logs, ['po0 加白 AgentB-Exit：白名单 1/5，当前 IP 1.2.3.4']);
    expect(h.reporter.isWatching, isTrue);

    // 30s 去重内的普通 refresh 不再拉
    await h.reporter.refresh();
    expect(h.fetches, 1);

    // 定时兜底：到点重拉列表 + 重报
    await h.tick();
    expect(h.fetches, greaterThanOrEqualTo(2));
    expect(h.sends, greaterThanOrEqualTo(2));
    h.dispose();
  });

  test('网络变化：防抖后只报一次、不重拉列表；全 none 不报', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1));
    await h.reporter.refresh(force: true);
    expect(h.sends, 1);

    h.conn.add([ConnectivityResult.wifi]);
    h.conn.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 2);
    expect(h.fetches, 1);

    // 同一组状态反复推（Android onCapabilitiesChanged）不报
    h.conn.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 2);

    h.conn.add([ConnectivityResult.none]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 2);

    // 断网后恢复算变化，报
    h.conn.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 3);
    h.dispose();
  });

  test('网络状态基线：与开始监听时相同的事件不报', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1), current: const [ConnectivityResult.wifi]);
    await h.reporter.refresh(force: true);
    expect(h.sends, 1);
    await Future<void>.delayed(Duration.zero);
    h.conn.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 1);
    h.conn.add([ConnectivityResult.wifi, ConnectivityResult.vpn]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 2);
    h.dispose();
  });

  test('关闭：停表、清空列表、之后定时与网络变化都不再报', () async {
    final h = _Harness(enabled: true);
    await h.reporter.refresh(force: true);
    expect(h.sends, 1);

    h.enabled = false;
    h.reporter.stop();
    expect(h.reporter.isWatching, isFalse);
    expect(h.reporter.servers, isEmpty);

    h.conn.add([ConnectivityResult.wifi]);
    await h.tick();
    expect(h.fetches, 1);
    expect(h.sends, 1);

    // 关着时 refresh 也只是停掉，不拉
    await h.reporter.refresh(force: true);
    expect(h.fetches, 1);
    h.dispose();
  });

  test('拉列表失败沿用上一份照报；未登录（返回 null）则停掉', () async {
    final h = _Harness(enabled: true);
    await h.reporter.refresh(force: true);
    expect(h.sends, 1);

    // 主控暂时拉不到：沿用旧列表仍上报
    h.failFetch = true;
    await h.reporter.refresh(force: true);
    expect(h.fetches, 2);
    expect(h.sends, 2);
    expect(h.logs, contains(startsWith('po0 服务器列表拉取失败')));
    expect(h.reporter.servers, isNotEmpty);

    // 登出：null → 停
    h.failFetch = false;
    h.servers = null;
    await h.reporter.refresh(force: true);
    expect(h.reporter.isWatching, isFalse);
    expect(h.reporter.servers, isEmpty);
    h.dispose();
  });

  test('直连 IP 回调：拿到列表时给 IP、列表不变不重复、列表变空 / 停止时撤掉', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1));
    await h.reporter.refresh(force: true);
    expect(h.directHosts, [
      ['209.248.57.93'],
    ]);

    // 列表没变：不回调
    await h.reporter.refresh(force: true);
    expect(h.directHosts.length, 1);

    // 列表变空：撤掉
    h.servers = const [];
    await h.reporter.refresh(force: true);
    expect(h.directHosts.last, isEmpty);

    // 重新有列表后关开关：stop 撤掉
    h.servers = const [Po0Server(serverId: 1, name: 'v6', ip: '', token: '', url: 'https://[2001:db8::2]/add')];
    await h.reporter.refresh(force: true);
    expect(h.directHosts.last, ['2001:db8::2']);
    h.enabled = false;
    await h.reporter.refresh(force: true); // 关着的 refresh 走 stop
    expect(h.directHosts.last, isEmpty);
    h.dispose();
  });

  test('拉列表失败不撤掉已有直连 IP', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1));
    await h.reporter.refresh(force: true);
    h.failFetch = true;
    await h.reporter.refresh(force: true);
    expect(h.directHosts, [
      ['209.248.57.93'],
    ]);
    h.dispose();
  });

  test('没登录、只有自己添加的条目：照样上报并起定时器，直连规则给自定义主机；条目删光才停', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1))
      ..servers = null
      ..custom = const [Po0CustomServer(address: 'fw.example.com:8443', token: 'pgnfw_abcd1234wxyz@2')];
    await h.reporter.refresh(force: true);
    expect(h.fetches, 1);
    expect(h.sends, 1);
    expect(h.sentUrls, ['https://fw.example.com:8443/api/firewall/pgnfw_abcd1234wxyz/add?slot=2']);
    expect(h.reporter.isWatching, isTrue);
    expect(h.directHosts.last, ['fw.example.com']);
    // 日志里只有脱敏写法
    expect(h.logs, ['po0 加白 fw.example.com:8443（pgnfw_••••wxyz@2）：白名单 1/5，当前 IP 1.2.3.4']);
    expect(h.logs.join(), isNot(contains('abcd1234wxyz')));

    // 网络变化照报
    h.conn.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(_Harness.debounce * 3);
    expect(h.sends, 2);

    // 条目删光、仍没登录：停掉、撤掉直连
    h.custom = const [];
    await h.reporter.refresh(force: true);
    expect(h.reporter.isWatching, isFalse);
    expect(h.reporter.servers, isEmpty);
    expect(h.directHosts.last, isEmpty);
    h.dispose();
  });

  test('已登录：自定义条目追加在主控列表之后、按上报地址去重；增删后 force 立刻按新列表报', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1))
      ..custom = const [Po0CustomServer(address: '209.248.57.93', token: 'pgnfw_abcd1234wxyz')];
    await h.reporter.refresh(force: true);
    expect(h.sentUrls, [
      'https://209.248.57.93/api/firewall/t/add?slot=1',
      'https://209.248.57.93/api/firewall/pgnfw_abcd1234wxyz/add',
    ]);
    expect(h.directHosts.last, ['209.248.57.93']);   // 同一个 IP 只一条

    h.custom = [...h.custom, const Po0CustomServer(address: '[2001:db8::1]', token: 'pgnfw_efgh5678@1')];
    await h.reporter.refresh(force: true);
    expect(h.sends, 2);
    expect(h.sentUrls.last, 'https://[2001:db8::1]/api/firewall/pgnfw_efgh5678/add?slot=1');
    expect(h.directHosts.last, ['209.248.57.93', '2001:db8::1']);
    h.dispose();
  });

  test('上报在飞时再来一次 force：等它结束后补一趟，新加的条目不用等下一个周期', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1))..sendGate = Completer<void>();
    final first = h.reporter.refresh(force: true);
    await Future<void>.delayed(Duration.zero);
    expect(h.sends, 1);

    h.custom = const [Po0CustomServer(address: '1.2.3.4', token: 'pgnfw_abcd')];
    unawaited(h.reporter.refresh(force: true));   // 在飞：先记下
    h.sendGate!.complete();
    h.sendGate = null;
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.fetches, 2);
    expect(h.sends, 2);
    expect(h.sentUrls.last, 'https://1.2.3.4/api/firewall/pgnfw_abcd/add');
    h.dispose();
  });

  group('结果（Design/po0-ggy-results.md）', () {
    test('每台按上报地址记一条结论：成功 / 槽位冲突 / 连不上；主控列表回调给界面', () async {
      final h = _Harness(enabled: true);
      h.custom = const [Po0CustomServer(address: '198.51.100.7', token: 'pgnfw_FAKEtoken00009999')];
      const customUrl = 'https://198.51.100.7/api/firewall/pgnfw_FAKEtoken00009999/add';
      const panelUrl = 'https://209.248.57.93/api/firewall/t/add?slot=1';
      h.reply = (urls) => '[{"url":"$panelUrl","status":403,"body":"{\\"currentIp\\":\\"1.2.3.4\\"}"},'
          '{"url":"$customUrl","error":"Post \\"$customUrl\\": dial tcp: i/o timeout"}]';
      await h.reporter.refresh(force: true);
      expect(h.panelEvents.last.map((s) => s.url), [panelUrl]);
      final r = h.reporter.results;
      expect(r.keys.toSet(), {panelUrl, customUrl});
      expect(r[panelUrl]!.kind, Po0ResultKind.slotConflict);
      expect(r[panelUrl]!.slot, 1);
      expect(r[panelUrl]!.currentIp, '1.2.3.4');
      expect(r[customUrl]!.kind, Po0ResultKind.failed);
      expect(r[customUrl]!.summary, '失败：dial tcp: i/o timeout');
      expect(h.resultEvents.last, r);
      // 日志里也写槽位冲突
      expect(h.logs.any((l) => l.contains('槽位冲突')), isTrue);
      h.dispose();
    });

    test('核心漏回的、核心调用异常：记成失败', () async {
      final h = _Harness(enabled: true);
      h.custom = const [Po0CustomServer(address: '198.51.100.7', token: 'pgnfw_FAKEtoken00009999')];
      await h.reporter.refresh(force: true);
      const customUrl = 'https://198.51.100.7/api/firewall/pgnfw_FAKEtoken00009999/add';
      expect(h.reporter.results[customUrl]!.summary, '失败：核心无响应');
      expect(h.reporter.results.values.first.kind, Po0ResultKind.success);
      h.dispose();
    });

    test('删掉的服务器结论跟着丢；关掉开关清空结论与主控列表', () async {
      final h = _Harness(enabled: true);
      h.custom = const [Po0CustomServer(address: '198.51.100.7', token: 'pgnfw_FAKEtoken00009999')];
      h.reply = (urls) => json.encode([
        for (final u in urls) {'url': u, 'status': 200, 'body': '{"enabled":true,"whitelist":["1.2.3.4"],"limit":5,"currentIp":"1.2.3.4"}'},
      ]);
      await h.reporter.refresh(force: true);
      expect(h.reporter.results.length, 2);
      h.custom = const [];
      await h.reporter.refresh(force: true);
      expect(h.reporter.results.keys, ['https://209.248.57.93/api/firewall/t/add?slot=1']);
      h.enabled = false;
      h.reporter.stop();
      expect(h.reporter.results, isEmpty);
      expect(h.resultEvents.last, isEmpty);
      expect(h.panelEvents.last, isEmpty);
      h.dispose();
    });

    test('上报在飞时删掉服务器：回来的结论不记它', () async {
      final h = _Harness(enabled: true);
      h.custom = const [Po0CustomServer(address: '198.51.100.7', token: 'pgnfw_FAKEtoken00009999')];
      h.reply = (urls) => json.encode([
        for (final u in urls) {'url': u, 'status': 200, 'body': '{"enabled":true,"whitelist":[],"limit":5,"currentIp":"1.2.3.4"}'},
      ]);
      h.sendGate = Completer<void>();
      final first = h.reporter.refresh(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // 在飞期间关掉开关：stop 清空列表
      h.enabled = false;
      h.reporter.stop();
      h.sendGate!.complete();
      await first;
      expect(h.reporter.results, isEmpty);
      h.dispose();
    });
  });
}
