import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Config load(Map<String, Object?> json) => Config.compatibleFromJson(json);

Map<String, Object?> withStack(String stack, {bool? reverted}) => {
      'patchClashConfig': {
        'tun': {'stack': stack},
      },
      if (reverted != null) 'meow': {'tunStackMipsReverted': reverted},
    };

void main() {
  test('新装：默认 mixed', () {
    final c = load({});
    expect(c.patchClashConfig.tun.stack, TunStack.mixed);
    expect(c.meow.tunStackMipsReverted, isTrue);
  });

  test('09-22 被迁到 mips 的老配置 → 改回 mixed 并记标记', () {
    final c = load(withStack('mips'));
    expect(c.patchClashConfig.tun.stack, TunStack.mixed);
    expect(c.meow.tunStackMipsReverted, isTrue);
  });

  test('09-22 迁移留下的旧标记 tunStackMigrated 不影响回退', () {
    final json = withStack('mips');
    json['meow'] = {'tunStackMigrated': true};
    final c = load(json);
    expect(c.patchClashConfig.tun.stack, TunStack.mixed);
    expect(c.meow.tunStackMipsReverted, isTrue);
  });

  test('手选过 mixed / gvisor / system → 保留', () {
    expect(load(withStack('mixed')).patchClashConfig.tun.stack, TunStack.mixed);
    expect(load(withStack('gvisor')).patchClashConfig.tun.stack, TunStack.gvisor);
    expect(load(withStack('system')).patchClashConfig.tun.stack, TunStack.system);
  });

  test('回退过后再手选 mips → 不再改回 mixed', () {
    final c = load(withStack('mips', reverted: true));
    expect(c.patchClashConfig.tun.stack, TunStack.mips);
  });

  test('回退不丢 meow 里的其他设置', () {
    final json = withStack('mips');
    json['meow'] = {'syncIntervalHours': 6};
    final c = load(json);
    expect(c.patchClashConfig.tun.stack, TunStack.mixed);
    expect(c.meow.syncIntervalHours, 6);
  });

  test('回退后的配置存盘再读回：标记与栈都保留', () {
    // 与 preferences 落盘同路径：jsonEncode（深序列化）→ 读回
    final saved = jsonDecode(jsonEncode(load(withStack('mips')))) as Map<String, Object?>;
    final again = load(saved);
    expect(again.patchClashConfig.tun.stack, TunStack.mixed);
    expect(again.meow.tunStackMipsReverted, isTrue);
  });
}
