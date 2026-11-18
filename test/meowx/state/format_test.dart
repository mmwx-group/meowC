import 'package:bett_box/meowx/state/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('图标块画了国旗时名字里去掉那面国旗；没有国旗、只剩国旗时原样', () {
    expect(nodeTitleWithoutFlag('🇭🇰 香港 01'), '香港 01');
    expect(nodeTitleWithoutFlag('IEPL 🇹🇼 台湾'), 'IEPL 台湾');
    expect(nodeTitleWithoutFlag('🇯🇵日本'), '日本');
    expect(nodeTitleWithoutFlag('香港 01'), '香港 01');
    expect(nodeTitleWithoutFlag('🇺🇸'), '🇺🇸');
  });

  test('图标块的字：名字里有国旗就用国旗（不在开头也认），没有取第一个字', () {
    expect(nodeTileLabel('🇭🇰 香港 01'), '🇭🇰');
    expect(nodeTileLabel('IEPL 🇹🇼 台湾'), '🇹🇼');
    expect(nodeTileLabel('hk-01'), 'H');
    expect(nodeTileLabel('[AgentB] sstest'), 'A');
    expect(nodeTileLabel('香港 01'), '香');
    expect(nodeTileLabel('  '), '?');
  });

  test('fmtSize 最小 KB，MB 一位小数，GB 两位', () {
    expect(fmtSize(0), '0 KB');
    expect(fmtSize(512), '1 KB');
    expect(fmtSize(1024 * 1023), '1023 KB');
    expect(fmtSize(1024 * 1024 * 1.55), '1.6 MB');
    expect(fmtSize(1024 * 1024 * 1024 * 2.345), '2.35 GB');
    expect(fmtRate(2048), '2 KB/s');
  });

  test('fmtUptime / fmtElapsed', () {
    expect(fmtUptime(const Duration(hours: 1, minutes: 2, seconds: 3)), '01:02:03');
    expect(fmtElapsed(const Duration(seconds: 42)), '42s');
    expect(fmtElapsed(const Duration(minutes: 3, seconds: 5)), '3m5s');
    expect(fmtElapsed(const Duration(hours: 2, minutes: 7)), '2h7m');
  });

  test('永久到期阈值', () {
    expect(isPermanentExpire(4102444799), isTrue);
    expect(isPermanentExpire(4102444798), isFalse);
  });

  test('fmtRelative', () {
    final now = DateTime(2026, 9, 20, 12);
    expect(fmtRelative(now.subtract(const Duration(seconds: 20)), now), '刚刚');
    expect(fmtRelative(now.subtract(const Duration(minutes: 5)), now), '5 分钟前');
    expect(fmtRelative(now.subtract(const Duration(hours: 3)), now), '3 小时前');
    expect(fmtRelative(now.subtract(const Duration(days: 2)), now), '2 天前');
  });
}
