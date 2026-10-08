// Riverpod 没有公开的办法关掉下面这个 debug 钩子，只能碰它标了 @internal 的变量（版本锁在 2.6.x）。
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter_riverpod/src/internals.dart' show debugCanModifyProviders;
import 'package:flutter_test/flutter_test.dart';

/// 让之后的 [expectNoFrameRequested] 看到的是正式包里的情况。要在 ProviderScope 挂上之后调。
///
/// debug 下 Riverpod 每次 provider 变化都会让 ProviderScope 重建一次（只为断言「没有在 build 期间改 provider」），
/// 于是任何一次写入都会要一帧；release 里没有这一下。ProviderScope 挂载时装上这个钩子、卸载时自己清掉，这里把它摘掉。
void useReleaseProviderFrames() => debugCanModifyProviders = null;

/// 断言刚才那些 provider 写入没有让任何东西要帧：没有 widget 重建，Riverpod 也没有排重算 / 回收
/// （它排这两样靠的是让 ProviderScope 重建，一样是一帧）。
Future<void> expectNoFrameRequested(WidgetTester tester, {String? reason}) async {
  // Riverpod 是隔一个微任务才去要帧的。只冲微任务，不能用 runAsync 放真实时间进来：
  // 页面里的资源图（品牌头像）解码是真异步，哪一次落进这个窗口就哪一次 setState 要帧，断言会随机失败。
  await tester.idle();
  expect(tester.binding.hasScheduledFrame, isFalse, reason: reason);
}
