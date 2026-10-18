import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/app.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/meowx/app/page_route.dart';
import 'package:flutter/material.dart';

class BaseNavigator {
  static Future<T?> push<T>(
    BuildContext context,
    Widget child, {
    bool maintainState = true,
  }) async {
    if (globalState.appState.viewMode != ViewMode.mobile) {
      return await Navigator.of(
        context,
      ).push<T>(
        CommonDesktopRoute(
          builder: (context) => child,
          maintainState: maintainState,
        ),
      );
    }
    // MeowX：手机上进二级页用 FlClash 0.9.1 的共享轴转场（见 lib/meowx/app/page_route.dart），
    // 以前是 CupertinoPageRoute（500ms、旧页视差 + 边缘阴影），转场时要多合成一层阴影、首帧慢时开头被吞掉
    return await Navigator.of(
      context,
    ).push<T>(
      MeowPageRoute(
        builder: (context) => child,
        maintainState: maintainState,
      ),
    );
  }
}

class CommonDesktopRoute<T> extends PageRoute<T> {
  final Widget Function(BuildContext context) builder;

  CommonDesktopRoute({
    required this.builder,
    this.maintainState = true,
  });

  @override
  final bool maintainState;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final Widget result = builder(context);
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: FadeTransition(opacity: animation, child: result),
    );
  }

  @override
  Duration get transitionDuration => Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => Duration(milliseconds: 200);
}
