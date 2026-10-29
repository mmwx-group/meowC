import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';

import '../theme/backdrop.dart';
import '../theme/card_surface.dart';
import '../theme/glass_art.dart';
import '../theme/tokens.dart';

/// 液态玻璃主题的背景宿主（包在 Navigator 外面，见 glass_host.dart）：外观（[MeowTokens.backdrop]）、屏幕尺寸、像素比变了时，
/// 防抖之后一次性渲染两张图——清晰背景（页面底用，[sharpScaleFor]）与按磨砂强度模糊并提饱和的背景（玻璃卡片按位置裁它当底，
/// 分辨率跟着模糊走，见 [MeowBackdrop.frostScaleFor]）。两张都不超过 [pixelBudget]。
/// 渲染在 raster 线程上异步做（Picture.toImage），不卡界面；滚动、转场时不重新模糊。刚启动 / 换设置时先显示底色渐层，图出来后再换上。
///
/// 卡片的取样位置跟着卡片在屏幕上的实际位置走：滚动时立刻让玻璃卡片重画（[MeowFrostBox.markAllMoved]），
/// 其它让卡片挪了位置的情况（转场、展开、平推）由卡片自己每帧核对一次（见 card_surface.dart）。
class MeowBackdropHost extends StatefulWidget {
  const MeowBackdropHost({super.key, required this.child});

  final Widget child;

  /// 换设置 / 改窗口尺寸时的防抖
  static const debounce = Duration(milliseconds: 120);

  /// 清晰背景每 dp 几个像素：插画按屏幕像素比（1:1 物理像素才看得清，同 MeowX iOS）；光斑 / 平涂本身就糊，半个像素够了。
  /// 以前两种都是物理分辨率的一半：插画不够清楚，光斑又白占内存（1080×2400 的屏一张 2.6MB，现在 0.3MB）
  static double sharpScaleFor(MeowBgPattern pattern, double dpr) => pattern == MeowBgPattern.art ? dpr : 0.5;

  /// 一张图最多这么多像素（RGBA 约 16MB）：手机、平板都在这以内；大屏高分屏的桌面窗口整窗按像素比画太占内存，超出就整体降一点分辨率
  static const pixelBudget = 4.2e6;

  static double capped(double scale, Size screen) => math.min(scale, math.sqrt(pixelBudget / (screen.width * screen.height)));

  @override
  State<MeowBackdropHost> createState() => _MeowBackdropHostState();
}

class _MeowBackdropHostState extends State<MeowBackdropHost> {
  MeowBackdropImages? _images;
  ({MeowBackdrop spec, Size screen, double dpr})? _want;
  Timer? _timer;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final spec = context.mm.backdrop;
    if (spec == null) {
      _timer?.cancel();
      _want = null;
      if (_images != null) _swap(null);
      return;
    }
    final want = (spec: spec, screen: MediaQuery.sizeOf(context), dpr: MediaQuery.devicePixelRatioOf(context));
    if (want == _want || want.screen.isEmpty) return;
    _want = want;
    _timer?.cancel();
    // 第一次立刻画（启动时不让页面底空着），之后防抖
    if (_images == null) {
      unawaited(_render(want));
    } else {
      _timer = Timer(MeowBackdropHost.debounce, () => unawaited(_render(want)));
    }
  }

  Future<void> _render(({MeowBackdrop spec, Size screen, double dpr}) want) async {
    final generation = ++_generation;
    final started = DateTime.now();
    final spec = want.spec, screen = want.screen;
    final sharpScale = MeowBackdropHost.capped(MeowBackdropHost.sharpScaleFor(spec.pattern, want.dpr), screen);
    final frostScale = MeowBackdropHost.capped(MeowBackdrop.frostScaleFor(spec.blurSigma, want.dpr), screen);
    // 插画：只解码到清晰图 cover 铺满（再外扩）要的大小，两张图画完就释放，不常驻内存
    final id = spec.artImage;
    ui.Image? art;
    if (spec.pattern == MeowBgPattern.art && id != null) {
      art = await MeowGlassArt.load(id, screen * sharpScale * (1 + 2 * MeowBackdrop.artBleed));
      if (art == null) commonPrint.log('backdrop art $id missing');
    }
    if (!mounted || generation != _generation) {
      art?.dispose();
      return;
    }

    Future<ui.Image> draw(double scale) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(scale);
      spec.paint(canvas, screen, art: art);
      final picture = recorder.endRecording();
      final image = picture.toImage((screen.width * scale).ceil(), (screen.height * scale).ceil());
      return image.whenComplete(picture.dispose);
    }

    final sharp = await draw(sharpScale);
    final small = await draw(frostScale);
    art?.dispose();
    // 磨砂：小图上模糊 + 提饱和（边缘按夹边延伸，四周不发暗）
    final w = small.width, h = small.height;
    final sigma = spec.blurSigma * frostScale;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      small,
      Offset.zero,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp)
        ..colorFilter = ColorFilter.matrix(MeowBackdrop.saturateMatrix(spec.saturation))
        ..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final frost = await picture.toImage(w, h);
    picture.dispose();
    small.dispose();
    if (!mounted || generation != _generation) {
      sharp.dispose();
      frost.dispose();
      return;
    }
    // 一次渲染一行（换设置 / 改尺寸才有）：看两张图多大、花了多久
    commonPrint.log(
      'backdrop ${spec.pattern.name} frost=${spec.frost.toStringAsFixed(2)} '
      'sharp ${sharp.width}x${sharp.height} frost ${frost.width}x${frost.height} '
      'in ${DateTime.now().difference(started).inMilliseconds}ms',
    );
    _swap(MeowBackdropImages(
      spec: spec,
      screen: screen,
      sharp: sharp,
      sharpScale: sharpScale,
      frost: frost,
      frostScale: frostScale,
    ));
  }

  void _swap(MeowBackdropImages? next) {
    final old = _images;
    setState(() => _images = next);
    // 旧图等这一帧画完（页面与卡片都换成新图）再释放
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _images?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (_) {
        if (_images != null) MeowFrostBox.markAllMoved();
        return false;
      },
      child: MeowBackdropScope(images: _images, child: widget.child),
    );
  }
}
