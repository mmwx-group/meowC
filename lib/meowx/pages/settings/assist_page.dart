import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/akile.dart';
import '../../panel/ggy.dart';
import '../../state/meow_settings.dart';
import '../me/me_kit.dart';
import 'akile_nodes_page.dart';
import 'ggy_tokens_page.dart';
import 'po0_servers_page.dart';

/// 「辅助功能」：把本机出口 IP 告诉某个防火墙的几项（po0 / GGY / AkileCDN，五端同一份规格：MeowX 仓库
/// Design/akile-whitelist.md §6）。手机上是「我的」里一个入口、点开一张设置卡片；宽屏直接是一个分组。

/// 「加白」一组的标题
const whitelistGroupTitle = '加白';

/// po0 加白的说明（以前写在开关行的副标题里）
const po0Description = '把本机出口 IP 上报到 po0 的加白服务器（主控登记的与自己添加的），每 10 分钟及网络变化时自动加白。';

/// 「加白」组标题旁 ⓘ 里的说明
const whitelistInfo = 'po0 加白：$po0Description\n\nGGY 加白：$ggyDescription\n\n$akileTitle：$akileDescription';

/// 手机入口行右侧的摘要：开着哪几项（都没开 =「未开启」）。
String assistSummary(MeowSettings m) {
  final on = [if (m.po0Enabled) 'po0', if (m.ggyEnabled) 'GGY', if (m.akileEnabled) 'AkileCDN'];
  return on.isEmpty ? '未开启' : '${on.join(' · ')} 加白';
}

/// 加白的开关与入口：po0 加白 / 自定义 po0 服务器 / GGY 加白 / GGY token / AkileCDN 白名单 / AkileCDN 节点。
/// 行里只留开关与入口，说明收在组标题的 ⓘ 里。开关、条目的变化由 MeowRoot 统一处理：打开 / 新增立刻上报，关闭停表清空。
class AssistRows extends ConsumerWidget {
  const AssistRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final po0 = ref.watch(meowSettingProvider.select((s) => s.po0Enabled));
    final po0Custom = ref.watch(meowSettingProvider.select((s) => s.po0Custom.length));
    final ggy = ref.watch(meowSettingProvider.select((s) => s.ggyEnabled));
    final ggyTokens = ref.watch(meowSettingProvider.select((s) => s.ggyTokens.length));
    final akile = ref.watch(meowSettingProvider.select((s) => s.akileEnabled));
    final akileNodes = ref.watch(meowSettingProvider.select((s) => s.akileNodes.length));
    void update(MeowSettings Function(MeowSettings s) f) => ref.read(meowSettingProvider.notifier).updateState(f);
    return MeRows(
      children: [
        MeSwitchRow(
          label: 'po0 加白',
          value: po0,
          onChanged: (v) => update((s) => s.copyWith(po0Enabled: v)),
        ),
        MeRow(
          label: '自定义 po0 服务器',
          value: po0Custom == 0 ? null : '$po0Custom 条',
          chevron: true,
          onTap: () => mePush(context, const Po0ServersPage()),
        ),
        MeSwitchRow(
          label: 'GGY 加白',
          value: ggy,
          onChanged: (v) => update((s) => s.copyWith(ggyEnabled: v)),
        ),
        MeRow(
          label: 'GGY token',
          value: ggyTokens == 0 ? null : '$ggyTokens 个',
          chevron: true,
          onTap: () => mePush(context, const GgyTokensPage()),
        ),
        MeSwitchRow(
          label: akileTitle,
          value: akile,
          onChanged: (v) => update((s) => s.copyWith(akileEnabled: v)),
        ),
        MeRow(
          label: akileNodesTitle,
          value: akileNodes == 0 ? null : '$akileNodes 个',
          chevron: true,
          onTap: () => mePush(context, const AkileNodesPage()),
        ),
      ],
    );
  }
}

/// 手机「我的 › 辅助功能」的设置卡片（宽屏直接铺 [AssistRows]）。
class AssistPage extends StatelessWidget {
  const AssistPage({super.key});

  @override
  Widget build(BuildContext context) => const MeSubPage.list(
    title: '辅助功能',
    children: [
      MeSection(title: whitelistGroupTitle, info: whitelistInfo, children: [AssistRows()]),
    ],
  );
}
