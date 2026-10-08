import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('四个 Tab 的顺序与名称', () {
    expect([for (final t in MeowTab.values) t.label], ['首页', '节点', '动态', '我的']);
  });

  test('Bettbox 页面标签映射：配置 / 工具都落到「我的」，非 Tab 页返回 null', () {
    expect(MeowTab.fromPageLabel(PageLabel.dashboard), MeowTab.home);
    expect(MeowTab.fromPageLabel(PageLabel.proxies), MeowTab.proxies);
    expect(MeowTab.fromPageLabel(PageLabel.connections), MeowTab.connections);
    expect(MeowTab.fromPageLabel(PageLabel.profiles), MeowTab.me);
    expect(MeowTab.fromPageLabel(PageLabel.tools), MeowTab.me);
    expect(MeowTab.fromPageLabel(PageLabel.logs), isNull);
  });
}
