import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_share.dart';
import 'package:bett_box/meowx/state/connection.dart';
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
ThemeData _theme(Brightness brightness) {
  final theme = meowThemeData(brightness: brightness);
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

  testWidgets('生成的图：1080 × 1350 的 PNG，浅色经典的底色与白卡；失败的记录不生成', (tester) async {
    final style = _theme(Brightness.light).textTheme.bodyMedium!;
    final textStyle = TextStyle(fontFamily: style.fontFamily, fontFamilyFallback: style.fontFamilyFallback);
    final result = await tester.runAsync(() async {
      final png = (await SpeedTestShareImage.render(_record(), textStyle: textStyle))!;
      final direct = (await SpeedTestShareImage.render(
        _record(source: SpeedTestSource.microsoft, connections: 1, outbound: kSpeedTestDirect),
        textStyle: textStyle,
      ))!;
      final failed = await SpeedTestShareImage.render(_record(error: '连接超时'), textStyle: textStyle);
      final image = await _decode(png);
      final size = (image.width, image.height);
      final corner = await _pixel(image, 4, 4);
      // 主卡左上角（版式 24 / 82 起、放大 2.4 倍）往里一点：白卡
      final card = await _pixel(image, 80, 230);
      image.dispose();
      return (png, direct, failed, size, corner, card);
    });
    final (png, direct, failed, size, corner, card) = result!;
    expect(size, (SpeedTestShareImage.width, SpeedTestShareImage.height));
    expect(size, (1080, 1350));
    expect(corner, MeowTokens.light.bg);
    expect(card, MeowTokens.light.elev);
    expect(failed, isNull);
    _preview('meowc-share.png', png);
    _preview('meowc-share-direct.png', direct);
  });

  group('记录详情页的分享图（安卓「分享」/ Windows「保存分享图」）', () {
    Future<void> pumpRecord(WidgetTester tester, Brightness brightness, SpeedTestRecord record,
        {bool systemShare = false, SpeedTestSaveFile? save, SpeedTestShareFile? share}) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(360 * 3, 1060 * 3);
      addTearDown(tester.view.reset);
      final c = SpeedTestController(call: (_, _) async => '');
      c.history.add(record);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('page'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(brightness),
            home: SpeedTestRecordPage(
              controller: c,
              id: record.id,
              systemShare: systemShare,
              saveFile: save ?? (_, _) async => null,
              shareFile: share ?? (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 真的去画图要在真实的事件循环里跑：直接调按钮的回调，等 [done] 拿到交出去的文件名与 PNG，回（文件名, 宽, 高, 左上角像素）
    Future<(String, int, int, Color)?> tapAndDecode(
        WidgetTester tester, String label, Completer<(String, Uint8List)> Function() done) {
      final ink = tester.widget<InkWell>(find.ancestor(of: find.text(label), matching: find.byType(InkWell)));
      return tester.runAsync(() async {
        final completer = done();
        ink.onTap!();
        final (name, bytes) = await completer.future.timeout(const Duration(seconds: 20));
        final image = await _decode(bytes);
        final info = (name, image.width, image.height, await _pixel(image, 4, 4));
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
      testWidgets('Windows · ${brightness.name}：点了生成 PNG 交给保存（文件名 .png），图一样是浅色', (tester) async {
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
        expect(out, ('MeowX-speedtest-20261029-1432.png', 1080, 1350, MeowTokens.light.bg));
        expect(shareCalls, 0);
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
