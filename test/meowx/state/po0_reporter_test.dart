import 'dart:async';

import 'package:bett_box/meowx/panel/po0.dart';
import 'package:bett_box/meowx/state/po0_reporter.dart';
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
      send: (urls) async {
        sends++;
        sentUrls = urls;
        return '[{"url":"${urls.first}","status":200,"body":"{\\"enabled\\":true,\\"whitelist\\":[{\\"ip\\":\\"1.2.3.4\\",\\"slot\\":1}],\\"limit\\":5,\\"currentIp\\":\\"1.2.3.4\\"}"}]';
      },
      connectivity: () => conn.stream,
      currentConnectivity: current == null ? null : () async => current,
      onDirectIps: directIps.add,
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
  final directIps = <List<String>>[];
  List<String> sentUrls = const [];
  List<Po0Server>? servers = const [
    Po0Server(serverId: 2, name: 'AgentB-Exit', ip: '209.248.57.93', token: 't', url: 'https://209.248.57.93/api/firewall/t/add?slot=1', slot: 1),
  ];

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
    expect(h.directIps, [
      ['209.248.57.93'],
    ]);

    // 列表没变：不回调
    await h.reporter.refresh(force: true);
    expect(h.directIps.length, 1);

    // 列表变空：撤掉
    h.servers = const [];
    await h.reporter.refresh(force: true);
    expect(h.directIps.last, isEmpty);

    // 重新有列表后关开关：stop 撤掉
    h.servers = const [Po0Server(serverId: 1, name: 'v6', ip: '', token: '', url: 'https://[2001:db8::2]/add')];
    await h.reporter.refresh(force: true);
    expect(h.directIps.last, ['2001:db8::2']);
    h.enabled = false;
    await h.reporter.refresh(force: true); // 关着的 refresh 走 stop
    expect(h.directIps.last, isEmpty);
    h.dispose();
  });

  test('拉列表失败不撤掉已有直连 IP', () async {
    final h = _Harness(enabled: true, interval: const Duration(hours: 1));
    await h.reporter.refresh(force: true);
    h.failFetch = true;
    await h.reporter.refresh(force: true);
    expect(h.directIps, [
      ['209.248.57.93'],
    ]);
    h.dispose();
  });
}
