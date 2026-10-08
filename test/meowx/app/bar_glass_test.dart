import 'dart:ui';

import 'package:bett_box/meowx/app/meow_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' show GlassQuality;
import 'package:liquid_glass_widgets/utils/glass_quality_adapter.dart';

/// [n] 帧光栅耗时都是 [rasterMs] 毫秒的假帧计时。
List<FrameTiming> _frames(int n, int rasterMs) => [
      for (var i = 0; i < n; i++)
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 0,
          rasterStart: 0,
          rasterFinish: rasterMs * 1000,
          rasterFinishWallTime: rasterMs * 1000,
        ),
    ];

/// 与 main.dart 里 wrap() 传的配置同一组取值；[minQuality] 默认是「放开降档」以后要用的 standard，
/// main.dart 目前传的是 premium（只采数据）。
GlassQualityAdapter _adapter(
  List<String> changes, {
  GlassQuality minQuality = GlassQuality.standard,
  void Function(GlassQuality settled, double p75Ms, int frames)? onWarmupComplete,
}) =>
    GlassQualityAdapter(
      minQuality: minQuality,
      maxQuality: GlassQuality.premium,
      targetFrameMs: 16,
      allowStepUp: false,
      onQualityChanged: (from, to) => changes.add('${from.name}→${to.name}'),
      onWarmupComplete: onWarmupComplete,
    );

void main() {
  // main.dart 挂上了库的自适应档位（实验性功能）。这里按 liquid_glass_widgets 1.7.2 的实现把依赖的行为钉住，
  // 升级库时行为变了会先在这里报出来。
  group('自适应档位的前提（库的行为）', () {
    setUp(GlassQualityAdapter.clearSessionCache);
    tearDown(GlassQualityAdapter.clearSessionCache);

    // 目前的接法：只采数据。库量的是整帧光栅耗时，与底栏在不在画无关，没有真机数据前不让它动底栏的观感。
    test('现在的配置（minQuality: premium）：预热再慢、运行中再卡、回前台重测都不降档，预热 P75 照样报出来', () {
      final changes = <String>[];
      final warmups = <String>[];
      final a = _adapter(
        changes,
        minQuality: GlassQuality.premium,
        onWarmupComplete: (settled, p75Ms, frames) => warmups.add('${settled.name} ${p75Ms.round()}ms $frames'),
      );
      a.simulateFrameTimings(_frames(90 + 180, 45));
      a.simulateFrameTimings(_frames(120 * 6, 80));
      a.reset(); // 回前台时库会重跑预热
      a.simulateFrameTimings(_frames(90 + 180, 30));
      expect(a.currentQuality, GlassQuality.premium);
      expect(changes, isEmpty);
      expect(warmups, ['premium 45ms 180', 'premium 30ms 180']);
    });

    // 以下三条是把 minQuality 放开到 standard 以后「底栏观感不会来回变」所依赖的行为。

    test('跑得动：起步 premium，预热（跳过 90 帧 + 实测 180 帧）后仍是 premium', () {
      final changes = <String>[];
      final a = _adapter(changes);
      expect(a.currentQuality, GlassQuality.premium);
      a.simulateFrameTimings(_frames(90 + 180, 6));
      expect(a.currentQuality, GlassQuality.premium);
      // 偶尔一两帧慢不算：P95 没超 24ms
      a.simulateFrameTimings([..._frames(115, 6), ..._frames(5, 40), ..._frames(115, 6), ..._frames(5, 40)]);
      expect(a.currentQuality, GlassQuality.premium);
      expect(changes, isEmpty);
    });

    test('运行中连续两个窗口 P95 > 24ms 才降一档；之后再流畅、回前台重测也不升，再卡也不低于 standard', () {
      final changes = <String>[];
      final a = _adapter(changes);
      a.simulateFrameTimings(_frames(90 + 180, 6));
      a.simulateFrameTimings(_frames(120, 30));
      expect(a.currentQuality, GlassQuality.premium, reason: '只有一个窗口超预算不降');
      a.simulateFrameTimings(_frames(120, 30));
      expect(a.currentQuality, GlassQuality.standard);

      a.simulateFrameTimings(_frames(120 * 30, 3));
      expect(a.currentQuality, GlassQuality.standard, reason: 'allowStepUp: false，进程内只降不升');

      a.reset(); // 回前台时库会重跑预热
      a.simulateFrameTimings(_frames(90 + 180, 3));
      expect(a.currentQuality, GlassQuality.standard, reason: '重测结果再好也不升回去');

      a.simulateFrameTimings(_frames(120 * 4, 80));
      expect(a.currentQuality, GlassQuality.standard, reason: 'minQuality: standard，不会掉到纯模糊');
      expect(changes, ['premium→standard']);
    });

    test('预热就跑不动（P75 ≥ 20ms）：降到 standard，哪怕慢到库想给 minimal 也停在 standard', () {
      for (final rasterMs in [22, 45]) {
        GlassQualityAdapter.clearSessionCache();
        final changes = <String>[];
        final a = _adapter(changes);
        a.simulateFrameTimings(_frames(90 + 180, rasterMs));
        expect(a.currentQuality, GlassQuality.standard, reason: '$rasterMs ms');
        expect(changes, ['premium→standard']);
      }
    });
  });

  test('底栏玻璃：默认参数不变；被自适应档位压到 standard 时按库的归一化口径换算、去掉暗带', () {
    for (final dark in [false, true]) {
      final normal = barGlass(dark);
      final degraded = barGlass(dark, degraded: true);

      // 默认（premium）这一组是调好的观感，不许动
      expect(normal.thickness, 30);
      expect(normal.lightIntensity, 1.0);
      expect(normal.blur, 20);

      // 降档：库对 premium 参数落到轻量着色器时自动做的是 厚度 ×0.4、高光 ×0.6；
      // 档位被显式压成 standard 后库不再做，这里必须自己乘，否则斜面比 Android 8–9 上现在的样子重得多
      expect(degraded.thickness, closeTo(normal.thickness * 0.4, 1e-9));
      expect(degraded.lightIntensity, closeTo(normal.lightIntensity * 0.6, 1e-9));
      expect(degraded.edgeAbsorption, 0, reason: '暗带只在 premium 着色器上好看');

      // 其余（底色、模糊、投影）降档前后一致：仍是同一块玻璃
      expect(degraded.glassColor, normal.glassColor);
      expect(degraded.blur, normal.blur);
      expect(degraded.shadow, normal.shadow);
      expect(degraded.bodyMode, normal.bodyMode);
    }
  });
}
