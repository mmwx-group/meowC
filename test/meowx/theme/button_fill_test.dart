import 'package:bett_box/meowx/theme/button_fill.dart';
import 'package:bett_box/meowx/theme/m3.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按钮底按 M3 的角色取色：主操作 / 选中 = primary、色调 = secondaryContainer，没有描边', () {
    for (final brightness in Brightness.values) {
      for (final (_, c) in MeowColors.presets) {
        final cs = MeowColors.scheme(Color(c), brightness);
        final mm = MeowTokens.fromScheme(cs);
        expect(mm.buttonFill(MeowButtonFill.prominent), cs.primary);
        expect(mm.buttonFill(MeowButtonFill.selected), cs.primary);
        expect(mm.onProminent, cs.onPrimary);
        expect(mm.onSelected, cs.onPrimary);
        expect(mm.buttonFill(MeowButtonFill.accent), cs.secondaryContainer);
        expect(mm.buttonFill(MeowButtonFill.plain), cs.card);
        expect(mm.buttonFill(MeowButtonFill.secondary), cs.cardInner);
        expect(mm.buttonFill(MeowButtonFill.accent, classic: Colors.red), Colors.red);
        expect(mm.buttonSide, BorderSide.none);
        expect(mm.buttonBorder, isNull);
      }
    }
  });
}
