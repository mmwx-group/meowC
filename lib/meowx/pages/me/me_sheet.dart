import 'package:bett_box/common/common.dart';
import 'package:flutter/widgets.dart';

/// 打开「我的」页的一个设置分组（[page] 一般是 [MeSubPage.list]）：M3 改版后整页推入，以前是从底部升起的卡片。
Future<void> showMeSheet(BuildContext context, Widget page) => BaseNavigator.push(context, page);
