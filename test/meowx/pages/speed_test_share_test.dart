import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_share.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测速记录分享图（工单 #1270）与测速源选择（多了 Microsoft，手机宽度下分两排）。
///
/// 字体：测试缺省的字体每个字都是一个方块，量出来的字宽也不对。这里载入仓库里的 HarmonyOS Sans（中文；也挂在圆体回落名
/// 「Noto Sans SC」下，标题那些只回落到圆体的字才不是方块）、JetBrains Mono（等宽）、Twemoji（旗帜），以及 Flutter SDK 自带的
/// Roboto（安卓的正文字体，SDK 里找得到才载）。没指定字族的字（分段里的字）测试里改不了，仍是方块。
/// MEOWX_SHARE_PREVIEW_DIR 设了时把分享图与页面截图存成 PNG。
const _kddi = SpeedTestExit(ip: '203.0.113.8', asn: 2516, org: 'KDDI Corporation', country: 'JP');

SpeedTestRecord _record({
  SpeedTestSource source = SpeedTestSource.apple,
  int connections = 8,
  String outbound = '🇭🇰 香港 IEPL 01',
  String? error,
  SpeedTestExit? exit = _kddi,
}) {
  final hasUpload = source.hasUpload;
  return SpeedTestRecord(
    id: 'r1',
    date: DateTime(2026, 10, 29, 14, 32),
    source: source,
    connections: connections,
    outbound: outbound,
    server: 'speed.example',
    latencyMs: error == null ? 38 : null,
    downloadMbps: error == null ? 486.4 : null,
    downloadPeakMbps: error == null ? 532.9 : null,
    uploadMbps: error == null && hasUpload ? 92.7 : null,
    uploadPeakMbps: error == null && hasUpload ? 101.2 : null,
    downloadSamples: error == null ? const [0, 120, 310, 420, 470, 500, 488, 520, 470, 495, 510, 480, 505, 490, 498] : const [],
    uploadSamples: error == null && hasUpload ? const [0, 40, 80, 95, 88, 99, 92, 101, 90, 94, 96, 93, 97, 95, 92] : const [],
    bytesUsed: 640 * 1024 * 1024,
    error: error,
    exit: exit,
  );
}

String? _previewDir = Platform.environment['MEOWX_SHARE_PREVIEW_DIR'];

void _preview(String name, Uint8List png) {
  final dir = _previewDir;
  if (dir == null || dir.isEmpty) return;
  File('$dir/$name').writeAsBytesSync(png);
}

/// Flutter SDK 里的 Roboto（各字重）与 Material 图标字体；找不到 SDK 就不载
Directory? _materialFonts() {
  final roots = [
    Platform.environment['FLUTTER_ROOT'],
    // flutter_tester 在 <SDK>/bin/cache/artifacts/engine/<平台>/ 下
    File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path,
  ];
  for (final root in roots) {
    if (root == null) continue;
    final dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (dir.existsSync()) return dir;
  }
  return null;
}

Future<void> _loadFonts() async {
  for (final family in ['HarmonyOS_Sans', 'Noto Sans SC']) {
    await (FontLoader(family)..addFont(rootBundle.load('assets/fonts/HarmonyOS_Sans_SC_Regular.ttf'))).load();
  }
  await (FontLoader('monospace')..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'))).load();
  await (FontLoader('Twemoji')..addFont(rootBundle.load('assets/fonts/Twemoji.Mozilla.ttf'))).load();
  final dir = _materialFonts();
  if (dir == null) return;
  Future<ByteData> read(String name) async => ByteData.sublistView(File('${dir.path}/$name').readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']) {
    roboto.addFont(read(name));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(read('MaterialIcons-Regular.otf'))).load();
}

/// App 的主题，中文回落到 HarmonyOS Sans、旗帜回落到 Twemoji（测试里没有系统字体可回落）
ThemeData _theme(Brightness brightness, {MeowLook look = MeowLook.classic}) {
  final theme = meowThemeData(brightness: brightness, look: look);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: const ['HarmonyOS_Sans', 'Twemoji']),
  );
}

/// 安卓正文字体（Roboto）下一段文字的宽度：分段里的字测试里画不出真字，按这个量放不放得下
double _robotoWidth(String text, double fontSize, double textScale) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontFamily: 'Roboto', fontSize: fontSize, fontWeight: FontWeight.w600)),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(textScale),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<Color> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  final i = (y * image.width + x) * 4;
  return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
}

Future<Uint8List?> _capture(WidgetTester tester, Key key) => tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
});

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('分享图的内容', () {
    test('失败的记录不给分享', () {
      final failed = _record(error: '连接超时');
      expect(SpeedTestShareImage.canShare(failed), isFalse);
      expect(SpeedTestShareContent.of(failed), isNull);
      expect(SpeedTestShareImage.canShare(_record()), isTrue);
    });

    test('只测下载的源（Microsoft / Google）：上传是「—」+「此测速源只测下载」', () {
      for (final source in [SpeedTestSource.microsoft, SpeedTestSource.google]) {
        final c = SpeedTestShareContent.of(_record(source: source))!;
        expect(c.upload, isNull, reason: source.name);
        expect(c.uploadNote, '此测速源只测下载');
      }
      final apple = SpeedTestShareContent.of(_record())!;
      expect((apple.upload, apple.uploadNote), ('92.7', '峰值 101 Mbps'));
    });

    test('出口只写 ASN + 运营商（去掉公司后缀），任何一行都不带 IP', () {
      final c = SpeedTestShareContent.of(_record(outbound: kSpeedTestDirect))!;
      expect(c.exit, 'AS2516 KDDI');
      final all = [c.dateTime, c.download, c.downloadPeak, c.upload, c.uploadNote, c.latency, c.sourceLine, c.outbound, c.exit];
      expect(all.where((s) => s != null && s.contains('203.0.113')), isEmpty);
      // 没有 ASN 只有运营商 / 两样都没有（旧记录、没查到）
      expect(
        SpeedTestShareContent.of(_record(exit: const SpeedTestExit(ip: '198.51.100.1', org: 'Example Ltd')))!.exit,
        'Example',
      );
      expect(SpeedTestShareContent.of(_record(exit: const SpeedTestExit(ip: '198.51.100.1')))!.exit, isNull);
      expect(SpeedTestShareContent.of(_record(exit: null))!.exit, isNull);
    });

    test('页头时间、测速源 · 线程、出站（直连写「直连 · 本机网络」）', () {
      final c = SpeedTestShareContent.of(_record(source: SpeedTestSource.microsoft, outbound: kSpeedTestDirect))!;
      expect(c.dateTime, '2026-10-29 14:32');
      expect(c.sourceLine, 'Microsoft · 8 线程');
      expect(c.outbound, '直连 · 本机网络');
      expect((c.download, c.downloadPeak, c.latency), ('486', '峰值 533 Mbps', '38'));
      final single = SpeedTestShareContent.of(_record(connections: 1))!;
      expect(single.sourceLine, 'Apple · 单线程');
      expect(single.outbound, '🇭🇰 香港 IEPL 01');
      expect(SpeedTestShareImage.fileName(_record()), 'MeowX-speedtest-20261029-1432.png');
    });
  });

  group('生成的图：跟着当前外观（主题色 + 深浅）', () {
    final style = _theme(Brightness.light).textTheme.bodyMedium!;
    final textStyle = TextStyle(fontFamily: style.fontFamily, fontFamilyFallback: style.fontFamilyFallback);

    /// 按外观 [look] 画一张图，取 [points] 处的像素；顺带存预览
    Future<List<Color>> sample(
      WidgetTester tester,
      MeowLook look,
      Brightness brightness,
      List<(int, int)> points, {
      SpeedTestRecord? record,
      String? preview,
    }) async {
      final out = await tester.runAsync(() async {
        final png = (await SpeedTestShareImage.render(
          record ?? _record(),
          look: look,
          brightness: brightness,
          textStyle: textStyle,
        ))!;
        final image = await _decode(png);
        expect((image.width, image.height), (1080, 1350));
        final colors = [for (final (x, y) in points) await _pixel(image, x, y)];
        image.dispose();
        if (preview != null) _preview(preview, png);
        return colors;
      });
      return out!;
    }

    // 页面底露出来的地方（左上 / 右下角、左右两边的边距）与主卡里没有字的一块（版式 24 / 78 起、放大 2.4 倍）
    const topLeft = (4, 4), bottomRight = (1075, 1345), card = (80, 230);
    const margins = [(20, 400), (20, 900), (1060, 300), (1060, 1000), (540, 4)];

    /// 页面底的渐层在 (x, y) 处应有的颜色（斜向 = 左上 → 右下，否则自上而下，铺满整张图）
    Color gradientAt(MeowTokens t, int x, int y) {
      final g = t.bgGradient!;
      const w = 1080.0, h = 1350.0;
      final px = x + 0.5, py = y + 0.5;
      final k = t.bgDiagonal ? (px * w + py * h) / (w * w + h * h) : py / h;
      return Color.lerp(g.first, g.last, k)!;
    }

    Matcher near(Color c, {int tolerance = 3}) => predicate<Color>(
      (p) =>
          p.a == 1 &&
          [(p.r, c.r), (p.g, c.g), (p.b, c.b)].every((e) => ((e.$1 - e.$2) * 255).abs() <= tolerance),
      'near $c',
    );

    testWidgets('经典浅色：平涂的浅色页面底 + 白卡；失败的记录不生成', (tester) async {
      final [corner, far, inCard] = await sample(
        tester,
        MeowLook.classic,
        Brightness.light,
        [topLeft, bottomRight, card],
        preview: 'meowc-share-classic-light.png',
      );
      expect((corner, far), (MeowTokens.light.bg, MeowTokens.light.bg));
      expect(inCard, MeowTokens.light.elev);
      final failed = await tester.runAsync(
        () => SpeedTestShareImage.render(
          _record(error: '连接超时'),
          look: MeowLook.classic,
          brightness: Brightness.light,
          textStyle: textStyle,
        ),
      );
      expect(failed, isNull);
      final direct = await tester.runAsync(
        () => SpeedTestShareImage.render(
          _record(source: SpeedTestSource.microsoft, connections: 1, outbound: kSpeedTestDirect),
          look: MeowLook.classic,
          brightness: Brightness.light,
          textStyle: textStyle,
        ),
      );
      _preview('meowc-share-direct.png', direct!);
    });

    testWidgets('经典深色：深色页面底 + 深色卡片', (tester) async {
      final [corner, far, inCard] = await sample(
        tester,
        MeowLook.classic,
        Brightness.dark,
        [topLeft, bottomRight, card],
        preview: 'meowc-share-classic-dark.png',
      );
      expect((corner, far), (MeowTokens.dark.bg, MeowTokens.dark.bg));
      expect(inCard, MeowTokens.dark.elev);
    });

    testWidgets('经典 + 卡片颜色 / 强调色：卡片是所选卡片色，上传那张卡的圆点是所选强调色', (tester) async {
      const look = MeowLook(cardColor: 0xFFFFF6EA, accentColor: 0xFF2F6FD0);
      final t = MeowTokens.resolve(Brightness.light, look);
      expect(t.elevSolid, isNot(MeowTokens.light.elev));
      expect(t.accent, isNot(MeowTokens.light.accent));
      // 上传卡的图例圆点在版式 x = 44（放大后 105.6），沿这一列往下找
      final column = await sample(tester, look, Brightness.light, [card, for (var y = 300; y < 700; y++) (105, y)]);
      expect(column.first, t.elevSolid);
      expect(column.skip(1), contains(t.accent));
      expect(column.skip(1), isNot(contains(MeowTokens.light.accent)));
    });

    for (final brightness in Brightness.values) {
      testWidgets('液态玻璃 + 渐变底色 · ${brightness.name}：页面底是左上 → 右下的渐层，卡片是不透明的实色', (tester) async {
        const look = MeowLook(
          style: MeowThemeStyle.glass,
          bgStyle: MeowBgStyle.gradient,
          gradientFrom: 0xFFCDEBDD,
          gradientTo: 0xFFCFDDF3,
          accentColor: 0xFF2F6FD0,
        );
        final t = MeowTokens.resolve(brightness, look);
        expect(t.bgGradient, isNotNull);
        expect((t.bgDiagonal, t.elev.a < 1), (true, true));
        final points = [topLeft, bottomRight, card, ...margins];
        final [corner, far, inCard, ...rest] = await sample(
          tester,
          look,
          brightness,
          [...points, for (var y = 180; y < 320; y++) (115, y)],
          preview: 'meowc-share-glass-gradient-${brightness.name}.png',
        );
        expect(corner, near(t.bgGradient!.first, tolerance: 4));
        expect(far, near(t.bgGradient!.last, tolerance: 4));
        expect(corner, isNot(far));
        for (final (i, (x, y)) in margins.indexed) {
          expect(rest[i], near(gradientAt(t, x, y)), reason: '($x, $y)');
        }
        // 实色（不透明）；elevSolid 是没取整的浮点色，PNG 里差不到 1 级
        expect(inCard, near(t.elevSolid, tolerance: 1));
        // 下载那条的图例圆点（版式 x = 48）是这份 token 的下载紫
        expect(rest.skip(margins.length), contains(t.down));
      });
    }

    testWidgets('液态玻璃 · 深色（单色底色、光斑）：页面底取底色渐层，不画光斑；深色图标', (tester) async {
      const look = MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFFFEFF4);
      final t = MeowTokens.resolve(Brightness.dark, look);
      final [corner, inCard, ...rest] = await sample(
        tester,
        look,
        Brightness.dark,
        [topLeft, card, ...margins],
        preview: 'meowc-share-glass-dark.png',
      );
      expect(corner, near(t.bgGradient!.first, tolerance: 4));
      for (final (i, (x, y)) in margins.indexed) {
        expect(rest[i], near(gradientAt(t, x, y)), reason: '($x, $y)');
      }
      expect(inCard, near(t.elevSolid, tolerance: 1));
      expect(SpeedTestShareImage.iconAsset(Brightness.dark), 'assets/images/icon_256.png');
      expect(SpeedTestShareImage.iconAsset(Brightness.light), 'assets/images/icon_light_256.png');
    });

    for (final brightness in Brightness.values) {
      testWidgets('液态玻璃 + 插画（自选图片）· ${brightness.name}：不出现照片，页面底就是底色渐层', (tester) async {
        const look = MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art, artImage: 'custom-1');
        final t = MeowTokens.resolve(brightness, look);
        expect(t.backdrop?.pattern, MeowBgPattern.art);
        final [inCard, ...rest] = await sample(
          tester,
          look,
          brightness,
          [card, topLeft, bottomRight, ...margins],
          preview: 'meowc-share-glass-art-${brightness.name}.png',
        );
        expect(inCard, near(t.elevSolid, tolerance: 1));
        for (final (i, (x, y)) in [topLeft, bottomRight, ...margins].indexed) {
          expect(rest[i], near(gradientAt(t, x, y)), reason: '($x, $y)');
        }
      });
    }

    test('配色：液态玻璃不论磨砂调到多少都按缺省 0.5 推；经典就是 App 当前那一份', () {
      List<Color> colors(MeowTokens t) => [t.bg, t.elevSolid, t.t1, t.t2, t.accent, t.down, t.line, ...?t.bgGradient];
      for (final brightness in Brightness.values) {
        expect(SpeedTestShareImage.tokensFor(brightness, MeowLook.classic), same(MeowTokens.resolve(brightness, MeowLook.classic)));
        const custom = MeowLook(cardColor: 0xFFFFF6EA, accentColor: 0xFF2F6FD0);
        expect(colors(SpeedTestShareImage.tokensFor(brightness, custom)), colors(MeowTokens.resolve(brightness, custom)));
        for (final base in const [
          MeowLook(style: MeowThemeStyle.glass),
          MeowLook(style: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient, bgPattern: MeowBgPattern.flat),
          MeowLook(style: MeowThemeStyle.glass, glassTint: MeowGlassTint.tinted, cardColor: 0xFFFFEFF4),
        ]) {
          final want = colors(MeowTokens.resolve(brightness, base));
          for (final frost in [0.0, 0.2, 0.8, 1.0]) {
            final look = base.withGlassFrost(frost);
            expect(colors(SpeedTestShareImage.tokensFor(brightness, look)), want, reason: '${brightness.name} $frost');
          }
          // App 里磨砂 0 的那份确实不一样（卡片几乎透明）
          expect(MeowTokens.resolve(brightness, base.withGlassFrost(0)).elevSolid, isNot(want[1]));
        }
      }
    });

    for (final brightness in Brightness.values) {
      testWidgets('液态玻璃 · 磨砂调到 0 · ${brightness.name}：卡片与页面底的差同磨砂 0.5（整张图一样）', (tester) async {
        const frost0 = MeowLook(style: MeowThemeStyle.glass, glassFrost: 0);
        const frost05 = MeowLook(style: MeowThemeStyle.glass);
        // 主卡里一块、主卡左边紧挨着的页面底，加上四角与边距
        const beside = (20, 230);
        final points = [card, beside, topLeft, bottomRight, ...margins];
        final a = await sample(
          tester,
          frost0,
          brightness,
          points,
          preview: 'meowc-share-glass-frost0-${brightness.name}.png',
        );
        final b = await sample(tester, frost05, brightness, points);
        expect(a, b);
        final t = MeowTokens.resolve(brightness, frost05);
        expect(a[0], near(t.elevSolid, tolerance: 1));
        expect(a[1], near(gradientAt(t, beside.$1, beside.$2)));
        // 卡片与页面底之间的差就是磨砂 0.5 那份的差；按 App 里磨砂 0 的那份画会小得多
        double diff(Color x, Color y) => (x.r - y.r).abs() + (x.g - y.g).abs() + (x.b - y.b).abs();
        final app = MeowTokens.resolve(brightness, frost0);
        expect(diff(a[0], a[1]), closeTo(diff(t.elevSolid, gradientAt(t, beside.$1, beside.$2)), 6 / 255));
        expect(diff(app.elevSolid, gradientAt(app, beside.$1, beside.$2)), lessThan(diff(a[0], a[1])));
      });
    }

    test('图上的字在实色卡片与页面底上都读得清（正文 ≥ 7、次级字与强调色 ≥ 4.5）', () {
      const looks = [
        MeowLook.classic,
        MeowLook(cardColor: 0xFFFFF6EA, accentColor: 0xFF2F6FD0),
        MeowLook(style: MeowThemeStyle.glass),
        MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFFFEFF4, bgPattern: MeowBgPattern.flat),
        MeowLook(style: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient),
        MeowLook(
          style: MeowThemeStyle.glass,
          glassTint: MeowGlassTint.tinted,
          bgStyle: MeowBgStyle.gradient,
          gradientFrom: 0xFFF4EDC4,
          gradientTo: 0xFFCDEBDD,
          accentColor: 0xFFB55A12,
        ),
        MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art, artImage: 'custom-1'),
        MeowLook(style: MeowThemeStyle.glass, glassFrost: 0),
        MeowLook(style: MeowThemeStyle.glass, glassFrost: 1),
      ];
      for (final brightness in Brightness.values) {
        for (final look in looks) {
          final t = SpeedTestShareImage.tokensFor(brightness, look);
          final g = t.bgGradient ?? [t.bg, t.bg];
          final page = [for (var i = 0; i <= 8; i++) Color.lerp(g.first, g.last, i / 8)!];
          final reason = '${brightness.name} ${look.style.name} ${look.bgStyle.name} ${look.bgPattern.name} ${look.glassFrost}';
          for (final (c, min, surfaces) in [
            (t.t1, 7.0, [t.elevSolid, ...page]),
            (t.t2, 4.5, [t.elevSolid, ...page]),
            (t.accent, 4.5, [t.elevSolid]),
            (t.down, 4.5, [t.elevSolid]),
          ]) {
            for (final s in surfaces) {
              expect(MeowTokens.contrast(c, s), greaterThanOrEqualTo(min), reason: '$reason: $c on $s');
            }
          }
        }
      }
    });
  });

  group('记录详情页的分享图（安卓「分享」/ Windows「保存分享图」）', () {
    Future<void> pumpRecord(WidgetTester tester, Brightness brightness, SpeedTestRecord record,
        {bool systemShare = false, SpeedTestSaveFile? save, SpeedTestShareFile? share, MeowLook look = MeowLook.classic}) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(360 * 3, 1060 * 3);
      addTearDown(tester.view.reset);
      final c = SpeedTestController(call: (_, _) async => '');
      c.history.add(record);
      await tester.pumpWidget(
        ProviderScope(
          // 分享图按 App 当前的外观画（见 SpeedTestShareAction.run）
          overrides: [meowLookProvider.overrideWithValue(look)],
          child: RepaintBoundary(
            key: const ValueKey('page'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(brightness, look: look),
              home: SpeedTestRecordPage(
                controller: c,
                id: record.id,
                systemShare: systemShare,
                saveFile: save ?? (_, _) async => null,
                shareFile: share ?? (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 真的去画图要在真实的事件循环里跑：直接调按钮的回调，等 [done] 拿到交出去的文件名与 PNG，回（文件名, 宽, 高, 左上角像素）；
    /// [card] 给了时把主卡里 (80, 230) 那一点存进去
    Future<(String, int, int, Color)?> tapAndDecode(
        WidgetTester tester, String label, Completer<(String, Uint8List)> Function() done, {List<Color>? card}) {
      final ink = tester.widget<InkWell>(find.ancestor(of: find.text(label), matching: find.byType(InkWell)));
      return tester.runAsync(() async {
        final completer = done();
        ink.onTap!();
        final (name, bytes) = await completer.future.timeout(const Duration(seconds: 20));
        final image = await _decode(bytes);
        final info = (name, image.width, image.height, await _pixel(image, 4, 4));
        card?.add(await _pixel(image, 80, 230));
        image.dispose();
        return info;
      });
    }

    for (final systemShare in [false, true]) {
      testWidgets('${systemShare ? '安卓' : 'Windows'}：失败的记录没有这个按钮', (tester) async {
        await pumpRecord(tester, Brightness.light, _record(error: '连接超时'), systemShare: systemShare);
        expect(find.text('保存分享图'), findsNothing);
        expect(find.text('分享'), findsNothing);
        expect(find.text('用同样设置再测一次'), findsOneWidget);
      });
    }

    for (final brightness in Brightness.values) {
      testWidgets('Windows · ${brightness.name}：点了生成 PNG 交给保存（文件名 .png），图跟着 App 的深浅色', (tester) async {
        // Completer 要在真实的事件循环里建（建在测试的假时钟里的话，完成的回调要等 pump 才跑）
        late Completer<(String, Uint8List)> saved;
        var shareCalls = 0;
        await pumpRecord(
          tester,
          brightness,
          _record(source: SpeedTestSource.microsoft),
          save: (name, bytes) async {
            saved.complete((name, bytes));
            return '/storage/$name';
          },
          share: (_, _) async => shareCalls++,
        );
        expect(find.text('保存分享图'), findsOneWidget);
        expect(find.text('分享'), findsNothing);
        final page = await _capture(tester, const ValueKey('page'));
        _preview(brightness == Brightness.light ? 'meowc-record.png' : 'meowc-record-dark.png', page!);

        final out = await tapAndDecode(tester, '保存分享图', () => saved = Completer());
        final bg = brightness == Brightness.dark ? MeowTokens.dark.bg : MeowTokens.light.bg;
        expect(out, ('MeowX-speedtest-20261029-1432.png', 1080, 1350, bg));
        expect(shareCalls, 0);
        await tester.pumpAndSettle();
      });
    }

    for (final brightness in Brightness.values) {
      testWidgets('液态玻璃 · ${brightness.name}、磨砂调到 0 的 App 里点分享：图用 App 当前的外观与深浅，卡片按磨砂 0.5', (tester) async {
        const look = MeowLook(
          style: MeowThemeStyle.glass,
          bgStyle: MeowBgStyle.gradient,
          bgPattern: MeowBgPattern.flat,
          glassFrost: 0,
        );
        late Completer<(String, Uint8List)> shared;
        await pumpRecord(
          tester,
          brightness,
          _record(),
          systemShare: true,
          look: look,
          share: (name, bytes) async => shared.complete((name, bytes)),
        );
        final card = <Color>[];
        final out = await tapAndDecode(tester, '分享', () => shared = Completer(), card: card);
        final want = MeowTokens.resolve(brightness, look.withGlassFrost(0.5));
        bool near(Color p, Color c, int tolerance) =>
            [(p.r, c.r), (p.g, c.g), (p.b, c.b)].every((e) => ((e.$1 - e.$2) * 255).abs() <= tolerance);
        final corner = out!.$4, first = want.bgGradient!.first;
        expect(near(corner, first, 4), isTrue, reason: '$corner vs $first');
        expect(near(card.single, want.elevSolid, 1), isTrue, reason: '${card.single} vs ${want.elevSolid}');
        // 不是 App 里磨砂 0 的那份卡片色
        expect(near(card.single, MeowTokens.resolve(brightness, look).elevSolid, 1), isFalse);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('安卓：按钮是「分享」，点了把 PNG 交给系统分享（文件名 .png），不存文件', (tester) async {
      late Completer<(String, Uint8List)> shared;
      var saveCalls = 0;
      await pumpRecord(
        tester,
        Brightness.light,
        _record(source: SpeedTestSource.microsoft),
        systemShare: true,
        save: (_, _) async {
          saveCalls++;
          return null;
        },
        share: (name, bytes) async => shared.complete((name, bytes)),
      );
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('保存分享图'), findsNothing);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      final page = await _capture(tester, const ValueKey('page'));
      _preview('meowc-record-android.png', page!);

      final out = await tapAndDecode(tester, '分享', () => shared = Completer());
      expect(out, ('MeowX-speedtest-20261029-1432.png', 1080, 1350, MeowTokens.light.bg));
      expect(saveCalls, 0);
      await tester.pumpAndSettle();
    });
  });

  group('测速页页头：分享这次测速结果（「测速记录」左边）', () {
    const downloading = '{"runID":1,"phase":"download","source":"apple","via":"香港 01","currentMbps":200}';
    const done = '{"runID":1,"phase":"done","source":"apple","via":"香港 01","latencyMs":38,"downloadMbps":486.4,'
        '"uploadMbps":92.7,"downloadSamples":[0,120,310,420],"uploadSamples":[0,40,80,95]}';
    const failed = '{"runID":1,"phase":"failed","error":"连不上"}';

    /// 核心依次回 [statuses] 里的进度（最后一个一直回）；测试中途可以改这个列表换下一次的进度
    SpeedTestController fake(List<String> statuses) => SpeedTestController(
      call: (method, data) async => switch (method) {
        ActionMethod.meowSpeedTestStatus => statuses.length > 1 ? statuses.removeAt(0) : statuses.first,
        _ => '',
      },
    );

    Future<void> pumpPage(WidgetTester tester, SpeedTestController c,
        {required bool systemShare, SpeedTestSaveFile? save, SpeedTestShareFile? share}) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(360 * 3, 900 * 3);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isRunningProvider.overrideWithValue(true),
            currentGroupsStateProvider.overrideWithValue(
              GroupsState(
                value: [
                  Group(
                    name: '节点选择',
                    type: GroupType.Selector,
                    now: '香港 01',
                    all: const [Proxy(name: '香港 01', type: 'Vless')],
                  ),
                ],
              ),
            ),
            currentNodeProvider.overrideWithValue(CurrentNode(group: '节点选择', path: const ['节点选择'], leaf: '香港 01')),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            home: SpeedTestPage(
              controller: c,
              systemShare: systemShare,
              saveFile: save ?? (_, _) async => null,
              shareFile: share ?? (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// 开测并走完（先「下载中」，300ms 后拿到下一个进度）
    Future<void> runToEnd(WidgetTester tester, SpeedTestController c) async {
      unawaited(c.start('香港 01'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    InkWell inkOf(WidgetTester tester, Finder button) =>
        tester.widget<InkWell>(find.descendant(of: button, matching: find.byType(InkWell)));

    testWidgets('安卓：测完出现「分享」、在「测速记录」左边；点了把 1080 × 1350 的 PNG 交给系统分享，分享中再点不响应',
        (tester) async {
      var shareCalls = 0, saveCalls = 0;
      late Completer<(String, Uint8List)> shared;
      late Completer<void> release;
      final c = fake([downloading, done]);
      await pumpPage(
        tester,
        c,
        systemShare: true,
        share: (name, bytes) async {
          shareCalls++;
          shared.complete((name, bytes));
          await release.future; // 分享面板开着
        },
        save: (_, _) async {
          saveCalls++;
          return null;
        },
      );
      expect(find.byTooltip('测速记录'), findsOneWidget);
      expect(find.byTooltip('分享'), findsNothing); // 还没测过

      unawaited(c.start('香港 01'));
      await tester.pump();
      expect(c.isRunning, isTrue);
      expect(find.byTooltip('分享'), findsNothing); // 正在测
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(c.progress.phase, 'done');

      final button = find.byTooltip('分享'), history = find.byTooltip('测速记录');
      expect(button, findsOneWidget);
      expect(find.byTooltip('保存分享图'), findsNothing);
      expect(find.descendant(of: button, matching: find.byIcon(Icons.share_outlined)), findsOneWidget);
      expect(tester.getCenter(button).dx, lessThan(tester.getCenter(history).dx));
      expect(tester.getCenter(button).dy, tester.getCenter(history).dy);

      final record = c.history.records.single;
      final out = await tester.runAsync(() async {
        // Completer 要在真实的事件循环里建（见上面记录详情页的用例）
        shared = Completer();
        release = Completer();
        inkOf(tester, button).onTap!();
        final (name, bytes) = await shared.future.timeout(const Duration(seconds: 20));
        final image = await _decode(bytes);
        final info = (name, image.width, image.height, await _pixel(image, 4, 4));
        image.dispose();
        return info;
      });
      expect(out, (SpeedTestShareImage.fileName(record), 1080, 1350, MeowTokens.light.bg));
      expect(out!.$1, matches(RegExp(r'^MeowX-speedtest-\d{8}-\d{4}\.png$')));

      // 分享面板还开着：按钮转圈、不响应
      await tester.pump();
      expect(find.descendant(of: button, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(inkOf(tester, button).onTap, isNull);
      await tester.runAsync(() async {
        release.complete();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(inkOf(tester, button).onTap, isNotNull);
      expect((shareCalls, saveCalls), (1, 0));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Windows：按钮是「保存分享图」，点了把 PNG 交给保存（同一个文件名），不走系统分享', (tester) async {
      var shareCalls = 0;
      late Completer<(String, Uint8List)> saved;
      final c = fake([downloading, done]);
      await pumpPage(
        tester,
        c,
        systemShare: false,
        save: (name, bytes) async {
          saved.complete((name, bytes));
          return '/storage/$name';
        },
        share: (_, _) async => shareCalls++,
      );
      await runToEnd(tester, c);

      final button = find.byTooltip('保存分享图');
      expect(button, findsOneWidget);
      expect(find.byTooltip('分享'), findsNothing);
      expect(find.descendant(of: button, matching: find.byIcon(Icons.image_outlined)), findsOneWidget);
      expect(tester.getCenter(button).dx, lessThan(tester.getCenter(find.byTooltip('测速记录')).dx));

      final record = c.history.records.single;
      final out = await tester.runAsync(() async {
        saved = Completer();
        inkOf(tester, button).onTap!();
        final (name, bytes) = await saved.future.timeout(const Duration(seconds: 20));
        final image = await _decode(bytes);
        final info = (name, image.width, image.height);
        image.dispose();
        await Future<void>.delayed(Duration.zero);
        return info;
      });
      expect(out, (SpeedTestShareImage.fileName(record), 1080, 1350));
      expect(shareCalls, 0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('失败了、停掉了、那条记录被删了都不出现；重新开测立刻消失', (tester) async {
      final statuses = [downloading, failed];
      final c = fake(statuses);
      void next(List<String> list) => statuses
        ..clear()
        ..addAll(list);
      await pumpPage(tester, c, systemShare: true);

      // 失败：记了一条，但不出现
      await runToEnd(tester, c);
      expect(c.progress.phase, 'failed');
      expect(c.history.records.single.failed, isTrue);
      expect(find.byTooltip('分享'), findsNothing);

      // 测完：出现；再开测：立刻消失
      next([downloading, done]);
      await runToEnd(tester, c);
      expect(find.byTooltip('分享'), findsOneWidget);
      next([downloading]);
      unawaited(c.start('香港 01'));
      await tester.pump();
      expect(c.isRunning, isTrue);
      expect(find.byTooltip('分享'), findsNothing);

      // 中途停掉：不出现
      await tester.tap(find.text('停止'));
      await tester.pump();
      expect(c.progress.phase, 'cancelled');
      expect(find.byTooltip('分享'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));

      // 测完后把这条记录删了：不出现
      next([downloading, done]);
      await runToEnd(tester, c);
      expect(find.byTooltip('分享'), findsOneWidget);
      c.history.delete(c.history.records.first.id);
      await tester.pump();
      expect(find.byTooltip('分享'), findsNothing);
      expect(find.byTooltip('测速记录'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('测速源选择', () {
    Future<SpeedTestController> pumpPage(WidgetTester tester, double width, {double textScale = 1}) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = Size(width * 3, 900 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = SpeedTestController(call: (_, _) async => '');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isRunningProvider.overrideWithValue(true),
            currentGroupsStateProvider.overrideWithValue(
              GroupsState(
                value: [
                  Group(
                    name: '节点选择',
                    type: GroupType.Selector,
                    now: '香港 01',
                    all: const [Proxy(name: '香港 01', type: 'Vless')],
                  ),
                ],
              ),
            ),
            currentNodeProvider.overrideWithValue(CurrentNode(group: '节点选择', path: const ['节点选择'], leaf: '香港 01')),
          ],
          child: RepaintBoundary(
            key: const ValueKey('page'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.light),
              home: SpeedTestPage(controller: c),
            ),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    /// 每段的宽（段 = 分段里一格，Expanded 给的宽）放得下 Roboto 下的名字；段都在屏幕里
    void expectAllFit(WidgetTester tester, double textScale) {
      final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      for (final s in SpeedTestSource.values) {
        final cell = tester.getRect(find.ancestor(of: find.text(s.title), matching: find.byType(GestureDetector)).first);
        expect(_robotoWidth(s.title, 13, textScale), lessThanOrEqualTo(cell.width - 8), reason: '${s.title} 放不下');
        expect(cell.right, lessThanOrEqualTo(screen));
      }
    }

    testWidgets('手机宽度（360）：五个源分两排（Google / Microsoft 一排），每段放得下；点另一排的段选中换过去', (tester) async {
      final c = await pumpPage(tester, 360);
      final segments = find.byType(MeowSegment<SpeedTestSource>);
      expect(segments, findsNWidgets(2));
      expect(tester.widget<MeowSegment<SpeedTestSource>>(segments.first).items.map((e) => e.$2), ['Google', 'Microsoft']);
      expect(tester.widget<MeowSegment<SpeedTestSource>>(segments.last).items.map((e) => e.$2),
          ['Apple', 'Speedtest', 'Cloudflare']);
      expectAllFit(tester, 1);
      // 五段一排的话每段只有约 55，「Cloudflare」放不下（所以才分两排）
      expect(_robotoWidth('Cloudflare', 13, 1), greaterThan((360 - 32 - 32 - 6 - 12) / 5 - 8));

      expect(c.source, SpeedTestSource.google);
      await tester.tap(find.text('Cloudflare'));
      await tester.pumpAndSettle();
      expect(c.source, SpeedTestSource.cloudflare);
      expect(tester.widget<MeowSegment<SpeedTestSource>>(segments.last).value, SpeedTestSource.cloudflare);
      await tester.tap(find.text('Microsoft'));
      await tester.pumpAndSettle();
      expect(c.source, SpeedTestSource.microsoft);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('系统字号 1.3 倍的 360 宽、320 宽的小屏也放得下', (tester) async {
      await pumpPage(tester, 360, textScale: 1.3);
      expectAllFit(tester, 1.3);
      await pumpPage(tester, 320);
      expectAllFit(tester, 1);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
