import 'package:bett_box/models/meow.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../panel/ggy.dart';
import '../panel/po0.dart';
import 'ggy_reporter.dart';
import 'meow_settings.dart';
import 'po0_reporter.dart';

/// 仅 debug 生效的截图示例：`--dart-define=MEOWX_WHITELIST_DEMO=true` 时 po0 / GGY 两个上报器不发请求，
/// 两页填上示例的服务器、token、备注与各种结果（全是假 token、文档保留地址）。release 包里恒为 false。
const whitelistDemo = kDebugMode && bool.fromEnvironment('MEOWX_WHITELIST_DEMO');

const _panelA = 'https://203.0.113.9/api/firewall/pgnfw_DEMOpanel0001111/add?slot=2';
const _panelB = 'https://203.0.113.20:8443/api/firewall/pgnfw_DEMOpanel0002222/add';
const _customA = Po0CustomServer(address: '198.51.100.7:8443', token: 'pgnfw_DEMOcustom0003333', note: '洛杉矶 po0');
const _customB = Po0CustomServer(address: 'fw.example.com', token: 'pgnfw_DEMOcustom0004444@1');
const _ggyA = 'ctecsfw_DEMOtoken000000000AAAA';
const _ggyB = 'ctecsfw_DEMOtoken000000000BBBB';
const _ggyC = 'ctecsfw_DEMOtoken000000000CCCC';

/// 填示例数据（MeowRoot 在核心起来之后调一次）。
void applyWhitelistDemo(WidgetRef ref) {
  if (!whitelistDemo) return;
  ref
      .read(meowSettingProvider.notifier)
      .updateState(
        (s) => s.copyWith(
          po0Enabled: true,
          po0Custom: const [_customA, _customB],
          ggyEnabled: true,
          ggyTokens: const [_ggyA, _ggyB, _ggyC],
          ggyTokenNotes: const {_ggyA: '香港 ECS'},
        ),
      );
  final now = DateTime.now();
  ref.read(po0PanelServersProvider.notifier).state = const [
    Po0Server(serverId: 1, name: 'AgentB-Exit', ip: '203.0.113.9', token: '', url: _panelA, slot: 2),
    Po0Server(serverId: 2, name: '东京 IEPL 入口', ip: '203.0.113.20', token: '', url: _panelB),
  ];
  ref.read(po0ResultsProvider.notifier).state = {
    _panelA: Po0Result(
      kind: Po0ResultKind.success,
      date: now.subtract(const Duration(minutes: 3)),
      enabled: true,
      limit: 5,
      currentIp: '192.0.2.0/24',
      entries: const [
        Po0WhitelistEntry(ip: '198.51.100.23', slot: 1),
        Po0WhitelistEntry(ip: '192.0.2.0/24', slot: 2),
        Po0WhitelistEntry(ip: '203.0.113.77'),
      ],
      slot: 2,
    ),
    _panelB: Po0Result(
      kind: Po0ResultKind.notApplied,
      date: now.subtract(const Duration(minutes: 3)),
      enabled: true,
      limit: 5,
      currentIp: '192.0.2.44',
      entries: const [
        Po0WhitelistEntry(ip: '198.51.100.1'),
        Po0WhitelistEntry(ip: '198.51.100.2'),
        Po0WhitelistEntry(ip: '198.51.100.3'),
        Po0WhitelistEntry(ip: '198.51.100.4'),
        Po0WhitelistEntry(ip: '198.51.100.5'),
      ],
    ),
    po0CustomTarget(_customA)!.url: Po0Result(
      kind: Po0ResultKind.slotConflict,
      message: po0SlotConflictMessage,
      date: now.subtract(const Duration(minutes: 3)),
    ),
    po0CustomTarget(_customB)!.url: Po0Result(
      kind: Po0ResultKind.failed,
      message: 'dial tcp 198.51.100.9:443: i/o timeout',
      date: now.subtract(const Duration(hours: 5)),
      slot: 1,
    ),
  };
  ref.read(ggyResultsProvider.notifier).state = {
    _ggyA: GgyResult(kind: GgyResultKind.ok, reason: '白名单添加成功', at: now.subtract(const Duration(minutes: 2))),
    _ggyB: GgyResult(
      kind: GgyResultKind.tokenInvalid,
      reason: '白名单分享链接无效或已失效',
      at: now.subtract(const Duration(minutes: 2)),
    ),
  };
}
