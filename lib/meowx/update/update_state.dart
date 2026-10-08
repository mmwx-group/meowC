import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 最近一次检查到的新版本号（如 `v0.1.9`）；没有新版 / 还没查到 = null。
/// 启动时的自动检查与手动检查都会写它，「我的 → 关于」据此提示有新版本（弹窗被点掉以后还找得到）。只在内存里，重启重新查。
final availableUpdateProvider = StateProvider<String?>((ref) => null);
