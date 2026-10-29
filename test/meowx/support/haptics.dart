import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 接住发给系统的震动，按顺序记下类型（HapticFeedback.vibrate 的参数，如 `HapticFeedbackType.lightImpact`）。
/// 平台通道上的其它调用一律当作成功、不记；用例结束时撤掉。
List<String> recordHaptics() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add('${call.arguments}');
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

const kLight = 'HapticFeedbackType.lightImpact';
const kMedium = 'HapticFeedbackType.mediumImpact';
const kHeavy = 'HapticFeedbackType.heavyImpact';
const kSelection = 'HapticFeedbackType.selectionClick';
const kSuccess = 'HapticFeedbackType.successNotification';
const kError = 'HapticFeedbackType.errorNotification';
