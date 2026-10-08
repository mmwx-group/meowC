import 'dart:io';
import 'dart:ui' as ui;

import 'package:bett_box/meowx/pages/me/account_card.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

void main() {
  testWidgets('品牌头像用 256 的小图（浅 / 深色各一张），不解码 1024 的原图，也不让引擎现缩', (tester) async {
    for (final (brightness, asset) in const [
      (Brightness.light, 'assets/images/icon_light_256.png'),
      (Brightness.dark, 'assets/images/icon_256.png'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: meowThemeData(brightness: brightness),
          home: const Column(children: [BrandHead(), BrandHead(size: 60)]),
        ),
      );
      await tester.pumpAndSettle();   // 换主题有过渡动画
      final providers = tester.widgetList<Image>(find.byType(Image)).map((i) => i.image).toList();
      expect(providers, everyElement(isA<AssetImage>().having((a) => a.assetName, 'assetName', asset)));
      expect(tester.getSize(find.byType(BrandHead).first), const Size.square(38));
      expect(tester.getSize(find.byType(BrandHead).last), const Size.square(60));

      // 小图真的是 256×256：够 60dp 在 4 倍屏上不放大，解码后只有原图的 1/16
      final bytes = File(asset).readAsBytesSync();
      final size = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        final size = Size(image.width.toDouble(), image.height.toDouble());
        image.dispose();
        codec.dispose();
        return size;
      });
      expect(size, const Size.square(256), reason: asset);
    }
  });

  testWidgets('账户头像（主控给的网络图）：解码宽度封顶在显示宽度的 4 倍，不限高度，小图不放大', (tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    const account = MeowAccount(host: 'https://panel.example.com', token: 't', nickname: 'n', avatarUrl: 'https://panel.example.com/a.png');
    // 60dp / 52dp × 2 倍屏 × 4
    for (final (compact, width) in const [(false, 480), (true, 416)]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meowSettingProvider.overrideWith(() => _Meow(const MeowSettings(account: account)))],
          child: MaterialApp(
            theme: meowThemeData(brightness: Brightness.light),
            home: Scaffold(body: AccountCard(onError: (_) {}, compact: compact)),
          ),
        ),
      );
      final avatar = tester.widgetList<Image>(find.byType(Image)).map((i) => i.image).whereType<ResizeImage>().singleWhere((i) => i.imageProvider is NetworkImage);
      expect(avatar.width, width, reason: 'compact=$compact');
      expect(avatar.height, isNull);
      expect(avatar.allowUpscaling, isFalse);
    }
  });
}
