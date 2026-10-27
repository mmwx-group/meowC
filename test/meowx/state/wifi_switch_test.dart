import 'dart:async';

import 'package:bett_box/meowx/state/wifi_switch.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

const _allGranted = WifiNetworkState(fineLocation: true, backgroundLocation: true, locationEnabled: true);

NetSnapshot _wifi(String? ssid, {SsidIssue? issue}) => NetSnapshot(NetKind.wifi, ssid: ssid, issue: issue);
const _cell = NetSnapshot(NetKind.cellular);
const _none = NetSnapshot(NetKind.none);

/// 全假依赖：网络由测试设置，暂停 / 恢复只改内存里的状态并计数。去抖缩到 10ms，用真实时钟跑。
class _Harness {
  _Harness({
    this.enabled = true,
    List<MeowWifiRule>? rules,
    this.other = MeowWifiAction.connect,
    this.running = true,
  }) : rules = rules ?? const [MeowWifiRule(ssid: 'Home', action: MeowWifiAction.disconnect)] {
    controller = WifiSwitchController(
      config: () => (enabled: enabled, rules: this.rules, other: other),
      readNetwork: (needSsid) async {
        reads++;
        lastNeedSsid = needSsid;
        return net;
      },
      isRunning: () => running,
      isSuspended: () async => suspended,
      suspend: () async {
        suspends++;
        suspended = true;
        running = false;
        // 模拟 runTimeProvider 在暂停过程中同步变化
        controller.observedRunChange();
      },
      resume: () async {
        resumes++;
        suspended = false;
        running = true;
        controller.observedRunChange();
      },
      networkEvents: () => events.stream,
      log: logs.add,
      onStatus: statuses.add,
      debounce: const Duration(milliseconds: 10),
    );
  }

  bool enabled;
  List<MeowWifiRule> rules;
  MeowWifiAction other;
  bool running;
  bool suspended = false;
  NetSnapshot net = _cell;
  int reads = 0, suspends = 0, resumes = 0;
  bool? lastNeedSsid;
  final events = StreamController<void>.broadcast();
  final logs = <String>[];
  final statuses = <WifiSwitchStatus>[];
  late final WifiSwitchController controller;

  /// 换到 [next] 并等去抖 + 决策跑完
  Future<void> moveTo(NetSnapshot next) async {
    net = next;
    events.add(null);
    await settle();
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));
}

void main() {
  group('纯函数', () {
    test('SSID 规范化：去空白与引号', () {
      expect(normalizeSsid('  Home '), 'Home');
      expect(normalizeSsid('"Home 5G"'), 'Home 5G');
      expect(normalizeSsid('"'), '"');
      expect(normalizeSsid('   '), '');
    });

    test('有 SSID 规则才需要读名称', () {
      expect(wifiRulesNeedSsid(const []), isFalse);
      expect(wifiRulesNeedSsid(const [MeowWifiRule(ssid: '  ')]), isFalse);
      expect(wifiRulesNeedSsid(const [MeowWifiRule(ssid: 'A')]), isTrue);
    });

    test('同名规则原地改动作，不重复加', () {
      const a = MeowWifiRule(ssid: 'A');
      const b = MeowWifiRule(ssid: 'B', action: MeowWifiAction.connect);
      final list = upsertWifiRule(upsertWifiRule(const [], a), b);
      expect(list.map((r) => r.ssid), ['A', 'B']);
      final changed = upsertWifiRule(list, const MeowWifiRule(ssid: 'A', action: MeowWifiAction.connect));
      expect(changed.length, 2);
      expect(changed.first.action, MeowWifiAction.connect);
    });

    test('拼快照：Wi-Fi 读到名称', () {
      final s = composeNetSnapshot(const WifiNetworkState(wifi: true, cellular: true, fineLocation: true, backgroundLocation: true, locationEnabled: true), needSsid: true, ssid: '"Home"');
      expect(s.kind, NetKind.wifi);
      expect(s.ssid, 'Home');
      expect(s.ssidUnknown, isFalse);
      expect(s.key, 'wifi|Home');
    });

    test('拼快照：读不到名称时按原因分', () {
      SsidIssue? issue(WifiNetworkState st) => composeNetSnapshot(st, needSsid: true).issue;
      expect(issue(const WifiNetworkState(wifi: true)), SsidIssue.noPermission);
      expect(issue(const WifiNetworkState(wifi: true, fineLocation: true)), SsidIssue.locationOff);
      expect(issue(const WifiNetworkState(wifi: true, fineLocation: true, locationEnabled: true)), SsidIssue.background);
      expect(
        issue(const WifiNetworkState(wifi: true, fineLocation: true, locationEnabled: true, backgroundLocation: true)),
        SsidIssue.unreadable,
      );
    });

    test('拼快照：没有 SSID 规则时不需要名称；蜂窝 / 有线 / 无网络', () {
      expect(composeNetSnapshot(const WifiNetworkState(wifi: true), needSsid: false).ssidUnknown, isFalse);
      expect(composeNetSnapshot(const WifiNetworkState(cellular: true), needSsid: true).kind, NetKind.cellular);
      expect(composeNetSnapshot(const WifiNetworkState(cellular: true, ethernet: true), needSsid: true).kind, NetKind.ethernet);
      expect(composeNetSnapshot(_allGranted, needSsid: true).kind, NetKind.none);
    });

    test('规则判定：第一条命中、其它网络、读不到名称不动作', () {
      const rules = [
        MeowWifiRule(ssid: 'Home', action: MeowWifiAction.disconnect),
        MeowWifiRule(ssid: 'Office', action: MeowWifiAction.connect),
        MeowWifiRule(ssid: 'Home', action: MeowWifiAction.connect),
      ];
      const other = MeowWifiAction.connect;
      final home = decideWifiAction(rules, other, _wifi('Home'));
      expect(home.action, MeowWifiAction.disconnect);
      expect(home.rule, rules.first);
      expect(decideWifiAction(rules, other, _wifi('Office')).action, MeowWifiAction.connect);
      // 区分大小写（与系统显示的名称一致）
      expect(decideWifiAction(rules, MeowWifiAction.ignore, _wifi('home')).action, MeowWifiAction.ignore);
      expect(decideWifiAction(rules, other, _wifi('Cafe')).rule, isNull);
      expect(decideWifiAction(rules, other, _cell).action, MeowWifiAction.connect);
      expect(decideWifiAction(rules, other, _none).action, MeowWifiAction.ignore);
      expect(decideWifiAction(rules, other, _wifi(null, issue: SsidIssue.background)).action, MeowWifiAction.ignore);
    });
  });

  group('控制器', () {
    test('回家暂停、同一网络不重复、离开恢复', () async {
      final h = _Harness()..net = _wifi('Home');
      h.controller.start();
      await h.settle();
      expect(h.suspends, 1);
      expect(h.suspended, isTrue);
      expect(h.lastNeedSsid, isTrue);

      await h.moveTo(_wifi('Home'));
      expect(h.suspends, 1);

      await h.moveTo(_cell);
      expect(h.resumes, 1);
      expect(h.suspended, isFalse);
      expect(h.running, isTrue);
      expect(h.controller.status.manualOverride, isFalse, reason: '自己的暂停 / 恢复不算手动');
    });

    test('去抖：短时间内的多次网络变化只读一次', () async {
      final h = _Harness()..net = _cell;
      h.controller.start();
      for (var i = 0; i < 5; i++) {
        h.events.add(null);
      }
      await h.settle();
      expect(h.reads, 1);
    });

    test('手动恢复后同一网络不再断开，换网后照常', () async {
      final h = _Harness()..net = _wifi('Home');
      h.controller.start();
      await h.settle();
      expect(h.suspended, isTrue);

      await h.controller.resumeManually();
      expect(h.suspended, isFalse);
      expect(h.controller.status.manualOverride, isTrue);

      // 同一网络的重复事件、规则修改、没网空档、读不到名称都不打断手动覆盖
      await h.moveTo(_wifi('Home'));
      await h.controller.reevaluate();
      await h.moveTo(_none);
      await h.moveTo(_wifi(null, issue: SsidIssue.background));
      await h.moveTo(_wifi('Home'));
      expect(h.suspends, 1);
      expect(h.controller.status.manualOverride, isTrue);

      await h.moveTo(_cell);
      expect(h.controller.status.manualOverride, isFalse);
      await h.moveTo(_wifi('Home'));
      expect(h.suspends, 2);
    });

    test('用户手动开关（磁贴 / 电源键）记为手动覆盖；规则自己引起的不算', () async {
      final h = _Harness(running: false)..net = _wifi('Home');
      h.controller.start();
      await h.settle();
      expect(h.suspends, 0, reason: '代理没开，断开无事可做');

      // 规则判过这个网络之后用户手动打开：到换网前不暂停
      h.running = true;
      h.controller.observedRunChange();
      expect(h.controller.status.manualOverride, isTrue);
      await h.moveTo(_wifi('Home'));
      expect(h.suspends, 0);
    });

    test('「连接」只恢复规则暂停的代理，不打开用户关掉的', () async {
      final h = _Harness(running: false)..net = _cell;
      h.controller.start();
      await h.settle();
      expect(h.resumes, 0);
      expect(h.running, isFalse);
    });

    test('读不到名称：不切换，给出原因，之后读到了照常决策', () async {
      final h = _Harness()..net = _wifi(null, issue: SsidIssue.noPermission);
      h.controller.start();
      await h.settle();
      expect(h.suspends, 0);
      expect(h.controller.status.note, contains('没有定位权限'));
      expect(h.controller.lastKey, isNull);
      expect(h.logs.any((l) => l.contains('没有定位权限')), isTrue);

      h.net = _wifi('Home');
      await h.controller.refresh();
      expect(h.suspends, 1);
    });

    test('规则改了立即对当前网络重新决策', () async {
      final h = _Harness(rules: const [])..net = _wifi('Home');
      h.controller.start();
      await h.settle();
      expect(h.suspends, 0);
      expect(h.lastNeedSsid, isFalse, reason: '没有 SSID 规则时不读名称');

      h.rules = const [MeowWifiRule(ssid: 'Home')];
      await h.controller.reevaluate();
      expect(h.suspends, 1);
    });

    test('总开关关着不读网络；打开即按当前网络决策；关掉恢复暂停的代理', () async {
      final h = _Harness(enabled: false)..net = _wifi('Home');
      h.controller.start();
      await h.settle();
      expect(h.reads, 0);

      h.enabled = true;
      await h.controller.enabled();
      expect(h.suspends, 1);

      h.enabled = false;
      await h.controller.disabled();
      expect(h.resumes, 1);
      expect(h.suspended, isFalse);
    });

    test('其它网络 = 不变：离开不恢复', () async {
      final h = _Harness(other: MeowWifiAction.ignore)..net = _wifi('Home');
      h.controller.start();
      await h.settle();
      await h.moveTo(_cell);
      expect(h.suspended, isTrue);
      expect(h.resumes, 0);
    });

    test('其它网络 = 断开：蜂窝上暂停，命中「连接」的 Wi-Fi 恢复', () async {
      final h = _Harness(
        rules: const [MeowWifiRule(ssid: 'Office', action: MeowWifiAction.connect)],
        other: MeowWifiAction.disconnect,
      )..net = _cell;
      h.controller.start();
      await h.settle();
      expect(h.suspended, isTrue);
      await h.moveTo(_wifi('Office'));
      expect(h.suspended, isFalse);
      expect(h.resumes, 1);
    });
  });
}
