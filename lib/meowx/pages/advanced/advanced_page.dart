import 'package:bett_box/common/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../me/me_kit.dart';
import 'app/app_settings_page.dart';
import 'app/backup_page.dart';
import 'app/developer_page.dart';
import 'app/language_row.dart';
import 'app/loopback_row.dart';
import 'app/other_settings_page.dart';
import 'config/core_config_page.dart';
import 'tools/requests_page.dart';
import 'tools/resources_page.dart';
import 'tools/scripts_page.dart';

/// 「我的 › 高级」（M3 改版后我们自己的一页，取代 Bettbox 的工具页 `lib/views/tools.dart`）：
/// - 内核：内核配置、覆写脚本、资源、请求记录；
/// - 应用：语言、备份与恢复、其它设置、应用设置、Loopback（Windows）；
/// - 其它：开发者（打开开发者模式后才有）。
/// 原工具页里和 MeowX 自己的页面重复的不再列：连接 / 日志（「动态」）、访问控制（「代理应用」）、快捷键（「我的 › 全局快捷键」）、
/// 主题（「外观」）、关于 / 免责声明（「我的 › 关于」）。原来的设置搜索也不要了（总共十来项）。
class AdvancedPage extends ConsumerWidget {
  const AdvancedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final developer = ref.watch(appSettingProvider.select((s) => s.developerMode));
    final tones = [
      (cs.primaryContainer, cs.onPrimaryContainer),
      (cs.tertiaryContainer, cs.onTertiaryContainer),
      (cs.secondaryContainer, cs.onSecondaryContainer),
      (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    ];
    const shapes = [M3TileShape.circle, M3TileShape.rounded, M3TileShape.leafA, M3TileShape.leafB];
    var n = 0;
    Widget tile(IconData icon) {
      final i = n++;
      final (bg, fg) = tones[i % tones.length];
      return M3IconTile(icon: icon, shape: shapes[i % shapes.length], bg: bg, fg: fg);
    }

    Widget entry(IconData icon, String label, String subtitle, Widget Function() page) => MeRow(
      leading: tile(icon),
      label: label,
      subtitle: subtitle,
      subtitleMaxLines: 1,
      chevron: true,
      onTap: () => mePush(context, page()),
    );

    return MeSubPage.list(
      title: '高级',
      children: [
        MeSection(
          title: '内核',
          children: [
            entry(Icons.tune_rounded, '内核配置', '通用 · DNS · 网络 · 嗅探 · TUN', CoreConfigPage.new),
            entry(Icons.code_rounded, '覆写脚本', '用脚本改写订阅配置', ScriptsPage.new),
            entry(Icons.folder_zip_outlined, '资源', 'GeoIP / GeoSite 等数据文件', ResourcesPage.new),
            entry(Icons.receipt_long_rounded, '请求记录', '最近经过内核的请求', RequestsPage.new),
          ],
        ),
        MeSection(
          title: '应用',
          children: [
            const LanguageRow(),
            entry(Icons.cloud_sync_outlined, '备份与恢复', 'WebDAV · 本地文件', BackupPage.new),
            entry(Icons.settings_suggest_outlined, '其它设置', '内核与网络的其它选项', OtherSettingsPage.new),
            entry(Icons.apps_rounded, '应用设置', '启动、通知与行为', AppSettingsPage.new),
            if (system.isWindows && loopbackManagerExists) const LoopbackRow(),
          ],
        ),
        if (developer)
          MeSection(
            title: '其它',
            children: [entry(Icons.developer_mode_rounded, '开发者', '调试选项', DeveloperPage.new)],
          ),
      ],
    );
  }
}
