import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../glass/liquid_glass.dart';
import '../app/glass_host.dart' show MeowGlassDevice;
import 'droplet_morph.dart';
import 'glass.dart';
import 'motion.dart';
import 'm3.dart';
import 'tokens.dart';

/// 下拉菜单的一项。
sealed class MeowMenuEntry<T> {
  const MeowMenuEntry();
}

/// 可选的一项：[checked] = 当前值（选中块停在这里、右侧打勾）；[color] 改字色（如「删除」用红）。
final class MeowMenuItem<T> extends MeowMenuEntry<T> {
  const MeowMenuItem(this.value, this.label, {this.checked = false, this.color});
  final T value;
  final String label;
  final bool checked;
  final Color? color;
}

/// 小标题（不可点）。
final class MeowMenuCaption<T> extends MeowMenuEntry<T> {
  const MeowMenuCaption(this.text);
  final String text;
}

/// 分隔线：把菜单分成几段，每段各有自己的选中块。
final class MeowMenuDivider<T> extends MeowMenuEntry<T> {
  const MeowMenuDivider();
}

const _itemH = 44.0, _captionH = 28.0, _dividerH = 9.0, _padV = 6.0, _radius = 16.0, _margin = 8.0;

double _entryHeight(MeowMenuEntry<Object?> e) => switch (e) {
  MeowMenuItem() => _itemH,
  MeowMenuCaption() => _captionH,
  MeowMenuDivider() => _dividerH,
};

/// 菜单内容的总高（含上下内边距）。
double meowMenuContentHeight(List<MeowMenuEntry<Object?>> entries) =>
    _padV * 2 + entries.fold(0.0, (h, e) => h + _entryHeight(e));

/// 菜单面板的落点（都是 overlay 坐标）：从按钮顶边往下展开、盖住按钮（按钮就是变成了菜单）；
/// 下面放不下就从按钮底边往上长；再放不下就贴着安全区的底边。左右收进屏幕、离边 8。内容比可用高度高时由调用方滚动。
Rect meowMenuRect({
  required Rect anchor,
  required double contentHeight,
  required double width,
  required bool alignEnd,
  required Size screen,
  required EdgeInsets safe,
}) {
  final w = math.min(width, screen.width - _margin * 2);
  final double left = (alignEnd ? anchor.right - w : anchor.left).clamp(
    _margin,
    math.max(_margin, screen.width - _margin - w),
  );
  final top0 = safe.top + _margin;
  final bottom0 = screen.height - safe.bottom - _margin;
  final h = math.max(0.0, math.min(contentHeight, bottom0 - top0));
  final double top;
  if (math.max(anchor.top, top0) + h <= bottom0) {
    top = math.max(anchor.top, top0);
  } else if (anchor.bottom - h >= top0) {
    top = anchor.bottom - h;
  } else {
    top = bottom0 - h;
  }
  return Rect.fromLTWH(left, top, w, h);
}

/// 菜单按内容该有的宽度：最长一项的字宽 + 行内边距（6 + 10，两侧）+ 勾的位置（8 + 18），夹在 180 到屏宽 − 16 之间。
/// 小标题按它自己的字号量。字号跟系统缩放走（同菜单里的上限 1.3）。
double meowMenuIntrinsicWidth(BuildContext context, List<MeowMenuEntry<Object?>> entries) {
  final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
  double measure(String text, double size, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: size, fontWeight: weight, fontFamilyFallback: linuxTextFallback)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  var widest = 0.0;
  for (final e in entries) {
    final w = switch (e) {
      MeowMenuItem(:final label) => measure(label, MeowFont.subheadline, FontWeight.w600) + (6 + 10) * 2 + 8 + 18,
      MeowMenuCaption(:final text) => measure(text, MeowFont.caption, FontWeight.w400) + 16 * 2,
      MeowMenuDivider() => 0.0,
    };
    widest = math.max(widest, w);
  }
  final screen = MediaQuery.sizeOf(context).width;
  return widest.ceilToDouble().clamp(180.0, math.max(180.0, screen - _margin * 2));
}

/// 弹出菜单（「按钮变形」）：iOS 27 的水滴变形（见 [DropletMorph]）——按钮缩成一颗圆，菜单从它长出来、先冲过头再弹回，
/// 关闭时缩回按钮成一颗倒水滴。[anchor] 是全局坐标，不给就取 [context] 这个控件的矩形。
/// 点选一项：选中块 snap 弹簧滑过去，220ms 后自动关。
/// [onClosing] 在开始关闭的那一刻调，参数是按钮中心到菜单中心的位移（按钮据此淡回并被「撞」一下）。
/// 返回选中的值，点外面 / 返回键关掉 = null。液态玻璃主题下面板是一块薄玻璃（同气泡），否则是实色卡片；
/// [fromColor] / [fromRadius] 已不用（变形从按钮缩成的圆开始），留着兼容调用方。
Future<T?> showMeowMenu<T>(
  BuildContext context, {
  required List<MeowMenuEntry<T>> entries,
  Rect? anchor,
  double? width,
  bool alignEnd = false,
  Color? fromColor,
  double? fromRadius,
  ValueChanged<Offset>? onClosing,
}) {
  final nav = Navigator.of(context, rootNavigator: true);
  final overlay = nav.overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return Future.value(null);
  Rect global;
  if (anchor != null) {
    global = anchor;
  } else {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Future.value(null);
    global = box.localToGlobal(Offset.zero) & box.size;
  }
  final local = Rect.fromPoints(overlay.globalToLocal(global.topLeft), overlay.globalToLocal(global.bottomRight));
  return nav.push(
    _MeowMenuRoute<T>(
      anchor: local,
      entries: entries,
      // 宽度跟着内容走（同 iOS 的菜单：按最长那一项定），[width] 只当下限
      width: math.max(width ?? 0, meowMenuIntrinsicWidth(context, entries)),
      alignEnd: alignEnd,
      onClosing: onClosing,
      reduce: MeowMotion.reduced(context),
    ),
  );
}

class _MeowMenuRoute<T> extends PopupRoute<T> {
  _MeowMenuRoute({
    required this.anchor,
    required this.entries,
    required this.width,
    required this.alignEnd,
    required this.onClosing,
    required this.reduce,
  });

  final Rect anchor;
  final List<MeowMenuEntry<T>> entries;
  final double width;
  final bool alignEnd;
  final ValueChanged<Offset>? onClosing;
  final bool reduce;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;

  // 背后不挡手势（同 iOS 27）：点外面只关气泡，拖动外面关气泡并照常滚动页面
  /// 在外面拖动时先把气泡藏起来（见 [DropletPassThroughBarrier]）
  final _hidden = ValueNotifier(false);

  @override
  void dispose() {
    _hidden.dispose();
    super.dispose();
  }

  @override
  Widget buildModalBarrier() => DropletPassThroughBarrier(
    onHide: () => _hidden.value = true,
    onDismiss: () {
      if (isCurrent) navigator?.pop();
    },
  );
  @override
  String? get barrierLabel => '关闭菜单';

  // 打开 / 关闭的动画由面板自己的控制器驱动；路由的反向时长只是让面板在关闭动画期间还挂着
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => reduce ? Duration.zero : DropletMorph.closeDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      DropletHideOnDrag(hidden: _hidden, child: _MeowMenuPanel<T>(route: this));
}

class _MeowMenuPanel<T> extends StatefulWidget {
  const _MeowMenuPanel({required this.route});
  final _MeowMenuRoute<T> route;

  @override
  State<_MeowMenuPanel<T>> createState() => _MeowMenuPanelState<T>();
}

class _MeowMenuPanelState<T> extends State<_MeowMenuPanel<T>> with TickerProviderStateMixin {
  _MeowMenuRoute<T> get _route => widget.route;
  List<MeowMenuEntry<T>> get _entries => _route.entries;

  /// 变形的时钟（见 [DropletMorph]）
  late final _morph = DropletMotion(this, settled: _route.reduce);

  /// 菜单此刻的落点（关闭时算按钮被撞的方向）
  Rect? _target;

  /// 菜单项淡入的时钟（线性 0…1，乘总时长是毫秒）
  late final _clock = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: math.max(1, MeowMotion.menuItemsTotal(_entries.length))),
    value: _route.reduce ? 1 : 0,
  );

  /// 关闭时菜单项整体淡出
  late final _out = AnimationController(vsync: this, duration: MeowMotion.menuItemsOut, value: 1);
  late final _items = Listenable.merge([_clock, _out]);

  /// 每一项在内容里的纵向位置（不含上下内边距）与所属段
  late final List<double> _y;
  late final List<int> _section;

  /// 每段的选中块：位置（像素，弹簧驱动）与当前停在哪一项（null = 这段还没有选中项，块不画）
  late final List<AnimationController> _hl;
  late final List<int?> _checked;

  bool _closing = false;
  Timer? _autoClose;
  ScrollController? _scroll;
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    final y = <double>[], section = <int>[];
    var acc = 0.0, s = 0;
    for (final e in _entries) {
      if (e is MeowMenuDivider<T>) s++;
      y.add(acc);
      section.add(s);
      acc += _entryHeight(e);
    }
    _y = y;
    _section = section;
    _checked = List.filled(s + 1, null);
    for (final (i, e) in _entries.indexed) {
      if (e is MeowMenuItem<T> && e.checked) _checked[_section[i]] ??= i;
    }
    _hl = [
      for (var k = 0; k <= s; k++)
        AnimationController.unbounded(vsync: this, value: _checked[k] == null ? 0 : _y[_checked[k]!]),
    ];
    if (!_route.reduce) {
      // 同 iOS 27：水滴从按钮中心弹出来，菜单项一开始就在（跟着面板拉伸、先糊后清），不再逐项错峰淡入
      _clock.value = 1;
      // 菜单的第一帧（p = 0 的水滴）画出来之后再开始计时：第一帧的排版 / 玻璃比较重，算进时间的话一出来就快展开完了
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closing) _morph.open();
      });
    }
    _routeAnimation = _route.animation?..addStatusListener(_onRouteStatus);
  }

  void _onRouteStatus(AnimationStatus status) {
    // 无动画时反向直接到 dismissed，不经过 reverse
    if (_closing || !(status == AnimationStatus.reverse || status == AnimationStatus.dismissed)) return;
    _closing = true;
    _autoClose?.cancel();
    final target = _target;
    _route.onClosing?.call(target == null ? Offset.zero : target.center - _route.anchor.center);
    if (_route.reduce) return;
    _morph.close();
  }

  void _pick(int index) {
    final e = _entries[index];
    if (_closing || _autoClose != null || e is! MeowMenuItem<T>) return;
    final s = _section[index];
    final reduce = _route.reduce;
    if (_checked[s] == null) {
      _hl[s].value = _y[index]; // 这段原来没有选中块：直接出现在点的这一项
    } else {
      MeowMotion.spring(_hl[s], _y[index], MeowMotion.snap, reduce: reduce);
    }
    setState(() => _checked[s] = index);
    _autoClose = Timer(reduce ? Duration.zero : MeowMotion.menuAutoClose, () {
      if (mounted && _route.isCurrent) Navigator.of(context).pop(e.value);
    });
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _autoClose?.cancel();
    _scroll?.dispose();
    _morph.dispose();
    _clock.dispose();
    _out.dispose();
    for (final c in _hl) {
      c.dispose();
    }
    super.dispose();
  }

  double _itemOpacity(int index) =>
      MeowMotion.menuItemIn(index, _clock.value * _clock.duration!.inMilliseconds) * _out.value;

  Widget _entry(int index, MeowTokens mm) {
    final e = _entries[index];
    final Widget body = switch (e) {
      MeowMenuDivider() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Divider(height: 1, thickness: 1, color: mm.line),
      ),
      MeowMenuCaption(:final text) => Container(
        alignment: Alignment.bottomLeft,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
        ),
      ),
      MeowMenuItem(:final label, :final color) => _ItemRow(
        label: label,
        color: color ?? mm.t1,
        checked: _checked[_section[index]] == index,
        onTap: () => _pick(index),
      ),
    };
    return SizedBox(
      height: _entryHeight(e),
      child: AnimatedBuilder(
        animation: _items,
        builder: (_, child) => Opacity(opacity: _itemOpacity(index), child: child),
        child: body,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final route = _route;
    final glass = meowPopupGlassOn(context);
    final contentH = meowMenuContentHeight(_entries);
    final target = meowMenuRect(
      anchor: route.anchor,
      contentHeight: contentH,
      width: route.width,
      alignEnd: route.alignEnd,
      screen: MediaQuery.sizeOf(context),
      safe: MediaQuery.paddingOf(context),
    );

    Widget content = Padding(
      padding: const EdgeInsets.symmetric(vertical: _padV),
      child: Stack(
        children: [
          for (final (s, hl) in _hl.indexed)
            if (_checked[s] != null)
              Positioned(
                left: 6,
                right: 6,
                top: 0,
                height: _itemH,
                child: AnimatedBuilder(
                  animation: Listenable.merge([hl, _items]),
                  builder: (_, child) => Opacity(
                    opacity: _itemOpacity(_checked[s]!),
                    child: Transform.translate(offset: Offset(0, hl.value), child: child),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // 玻璃上直接用淡粉（深色下它本身是半透明的），不垫卡片底
                      color: glass ? mm.soft : Color.alphaBlend(mm.soft, context.cs.surfaceContainer),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (var i = 0; i < _entries.length; i++) _entry(i, mm)],
          ),
        ],
      ),
    );
    if (contentH > target.height) {
      // 放不下：可滚动，打开时让第一个选中项落在可见范围里
      final first = _checked.nonNulls.firstOrNull;
      final initial = first == null
          ? 0.0
          : (_y[first] + _itemH / 2 - target.height / 2).clamp(0.0, contentH - target.height);
      content = SingleChildScrollView(
        controller: _scroll ??= ScrollController(initialScrollOffset: initial),
        child: content,
      );
    }
    content = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Material(type: MaterialType.transparency, child: content),
    );

    _target = target;
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final allowed = Rect.fromLTRB(_margin, safe.top + _margin, screen.width - _margin, screen.height - safe.bottom - _margin);
    final menuStyle = glass ? MeowGlassStyles.popover(context) : null; // 同气泡的薄玻璃（2026-11-18 用户要求）
    final menuRim = glass ? MeowGlassStyles.menuRim(context) : null;
    final shadows = glass ? MeowGlassStyles.menuShadows(context) : const <BoxShadow>[];
    return Stack(
      children: [
        AnimatedBuilder(
          animation: _morph,
          builder: (_, child) {
            final m = _morph;
            // iOS 27 的水滴变形（见 DropletMorph）：按钮缩成的圆长成菜单，关闭时缩回成倒水滴
            final frame = route.reduce
                ? DropletFrame.settled(target, _radius)
                : m.closing
                ? DropletMorph.close(
                    anchor: route.anchor,
                    target: target,
                    finalRadius: _radius,
                    raw: m.raw,
                    elapsed: m.elapsed,
                    closeStart: m.closeStart,
                  )
                : DropletMorph.open(
                    anchor: route.anchor,
                    target: target,
                    finalRadius: _radius,
                    raw: m.raw,
                    elapsed: m.elapsed,
                    allowed: allowed,
                  );
            return DropletSurface(
              frame: frame,
              target: target,
              glassStyle: menuStyle,
              glassRim: menuRim,
              shadows: shadows,
              color: context.cs.surfaceContainer,
              blur: !MeowGlassDevice.lowEnd,
              child: child!,
            );
          },
          // 内容自成一层：变形每帧只改面板的形状和内容的位移，菜单项不跟着重画
          child: RepaintBoundary(child: content),
        ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.label, required this.color, required this.checked, required this.onTap});
  final String label;
  final Color color;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final fade = MeowMotion.of(context, const Duration(milliseconds: 150));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: mm.card2.withValues(alpha: 0.6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: fade,
                  style: TextStyle(
                    fontSize: MeowFont.subheadline,
                    fontWeight: checked ? FontWeight.w600 : FontWeight.w500,
                    fontFamilyFallback: linuxTextFallback, // 这里另起一份样式、不继承主题
                    color: checked ? mm.accent : color,
                  ),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              AnimatedOpacity(
                duration: fade,
                opacity: checked ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.check_rounded, size: 18, color: mm.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 由一个按钮 / 胶囊 / 行触发的下拉菜单（[showMeowMenu] 的「按钮变形」版）：打开时触发控件 120ms 淡出（面板就是它变的），
/// 关闭开始 200ms 后淡回。[builder] 拿到 `open` 回调，交给控件自己的 onTap（保留它的悬停 / 水波 / 读屏语义）。
class MeowMenuButton<T> extends StatefulWidget {
  const MeowMenuButton({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.builder,
    this.width,
    this.alignEnd = false,
    this.fromColor,
    this.fromRadius,
    this.fadeTrigger = true,
    this.anchorWidth,
  });

  /// 打开时才取（当前值在打开那一刻定）
  final List<MeowMenuEntry<T>> Function() entries;
  final ValueChanged<T> onSelected;
  final Widget Function(BuildContext context, VoidCallback open) builder;
  final double? width;
  final bool alignEnd;
  final Color? fromColor;
  final double? fromRadius;

  /// 打开时把触发控件淡出。整行触发（设置行）时关掉：面板只从行尾那一段长出来，行首的标题留着。
  final bool fadeTrigger;

  /// 变形的起点只取触发控件靠 [alignEnd] 那一侧这么宽的一段（缺省 = 整个控件）。
  final double? anchorWidth;

  @override
  State<MeowMenuButton<T>> createState() => _MeowMenuButtonState<T>();
}

class _MeowMenuButtonState<T> extends State<MeowMenuButton<T>> with TickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, value: 1);

  /// 关闭时按钮被「撞」一下的时钟（线性 0…1 = 0…[DropletMorph.recoilDuration]）与方向（按钮中心到菜单中心）
  late final _kick = AnimationController(vsync: this, duration: DropletMorph.recoilDuration)..addListener(_onKick);
  Offset _travel = Offset.zero;
  bool _open = false;

  double get _kickSeconds => _kick.value * DropletMorph.recoilDuration.inMicroseconds / 1e6;

  void _onKick() {
    // 按钮跟着尾巴处那颗圆冒出来（关闭后约 110–230ms）
    if (widget.fadeTrigger) _fade.value = DropletMorph.triggerReturn(_kickSeconds);
  }

  Future<void> _openMenu() async {
    if (_open) return;
    _open = true;
    _kick.stop();
    var closing = false;
    final reduce = MeowMotion.reduced(context);
    Rect? anchor;
    final box = context.findRenderObject() as RenderBox?;
    final w = widget.anchorWidth;
    if (w != null && box != null && box.hasSize) {
      final r = box.localToGlobal(Offset.zero) & box.size;
      final width = math.min(w, r.width);
      anchor = widget.alignEnd
          ? Rect.fromLTRB(r.right - width, r.top, r.right, r.bottom)
          : Rect.fromLTWH(r.left, r.top, width, r.height);
    }
    if (widget.fadeTrigger) {
      if (reduce) {
        _fade.value = 0;
      } else {
        _fade.animateTo(0, duration: MeowMotion.menuTriggerOut);
      }
    }
    final value = await showMeowMenu<T>(
      context,
      anchor: anchor,
      entries: widget.entries(),
      width: widget.width,
      alignEnd: widget.alignEnd,
      fromColor: widget.fromColor,
      fromRadius: widget.fromRadius,
      onClosing: (travel) {
        closing = true;
        if (!mounted) return;
        if (reduce) {
          _fade.value = 1;
        } else {
          _travel = travel;
          _kick.forward(from: 0);
        }
      },
    );
    _open = false;
    if (!mounted) return;
    if (!closing) _fade.value = 1; // 菜单没打开成（拿不到位置）：按钮直接回来
    if (value != null) widget.onSelected(value);
  }

  @override
  void dispose() {
    _kick.dispose();
    _fade.dispose();
    super.dispose();
  }

  // 触发控件是玻璃时用 LiquidGlassFade：普通的半透明会把它变成离屏层，淡出的那一下玻璃读不到背后的画面
  @override
  Widget build(BuildContext context) {
    final body = meowGlassOn(context)
        ? LiquidGlassFade(opacity: _fade, child: widget.builder(context, _openMenu))
        : FadeTransition(opacity: _fade, child: widget.builder(context, _openMenu));
    // 关闭时被撞：往菜单的反方向弹一下、压扁一点（同 iOS 27）
    return AnimatedBuilder(
      animation: _kick,
      builder: (_, child) {
        // 结构不随动画插拔（插拔 Transform 会让按钮整棵重挂）：没在撞时位移 0、缩放 1
        final t = _kick.isAnimating ? _kickSeconds : 0.0;
        return Transform.translate(
          offset: DropletMorph.triggerRecoil(_travel, t),
          child: Transform.scale(scale: DropletMorph.triggerImpact(_travel, t), child: child),
        );
      },
      child: body,
    );
  }
}
