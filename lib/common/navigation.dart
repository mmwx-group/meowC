import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/advanced/advanced_page.dart';
import 'package:bett_box/meowx/pages/advanced/tools/requests_page.dart';
import 'package:bett_box/meowx/pages/advanced/tools/resources_page.dart';
import 'package:bett_box/meowx/pages/advanced/tools/scripts_page.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';

/// Bettbox 内部 toPage(PageLabel) 能去的「非 Tab 页」（2026-11-17 删掉 Bettbox 界面后只剩 MeowX 自己的页面）：
/// 首页 / 节点 / 动态 / 我的是壳的四个 Tab（[MeowTab.fromPageLabel]），这里只列要 push 的几页，见 meow_root 的 _pushBettboxPage。
/// 日志在「动态」页里，不单独成页。
class Navigation {
  static Navigation? _instance;

  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) {
    return [
      NavigationItem(
        icon: const Icon(Icons.view_timeline),
        label: PageLabel.requests,
        builder: (_) => const RequestsPage(),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.storage),
        label: PageLabel.resources,
        builder: (_) => const ResourcesPage(),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.functions),
        label: PageLabel.script,
        builder: (_) => const ScriptsPage(),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.construction),
        label: PageLabel.tools,
        builder: (_) => const AdvancedPage(),
        modes: [NavigationItemMode.more],
      ),
    ];
  }

  Navigation._internal();

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }
}

final navigation = Navigation();
