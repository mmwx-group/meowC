import 'dart:async';

import 'package:bett_box/state.dart';

/// 内核 error 级日志 → 给用户看的提示。
///
/// 内核日志从 0.5.5 起一直订阅着（见 log_source.dart），而 Bettbox 的做法是每条 error 日志都原样弹一条提示：
/// 订阅里有几个节点集的地址没填（还是模板里的「订阅链接1」），每次打开 App 就连弹几条
/// `initial proxy provider Airport_01 error: Get "%E8%AE%A2…": unsupported protocol scheme ""`（2026-11-20 用户实报）。
///
/// 这里做两件事：
/// - 节点集 / 规则集加载失败（`initial proxy|rule provider <名字> error: …`）攒一小会儿合成**一条**中文提示；
///   同一批名字在本次运行里只提示一次（重连、换模式重起内核时不再弹），详情仍在「动态 › 日志」里。
/// - 其它 error 日志照旧原样提示，但同一条 [repeatWindow] 内不重复弹。
class CoreErrorNotice {
  CoreErrorNotice({
    required this.show,
    this.collectWindow = const Duration(milliseconds: 800),
    this.repeatWindow = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 弹提示（真实实现是 globalState.showNotifier）
  final void Function(String message) show;

  /// provider 报错攒多久合成一条（内核并发加载，几条报错前后脚到）
  final Duration collectWindow;

  /// 同一条别的报错多久之内不重复提示
  final Duration repeatWindow;
  final DateTime Function() _now;

  static final _provider = RegExp(r'^initial (proxy|rule) provider (.+?) error: (.*)$', dotAll: true);

  final _pending = <ProviderFailure>[];
  Timer? _timer;

  /// 本次运行里已经提示过的那批（种类 + 名字）
  final _told = <String>{};
  final _lastShown = <String, DateTime>{};

  void onError(String payload) {
    final text = payload.trim();
    if (text.isEmpty) return;
    final m = _provider.firstMatch(text);
    if (m != null) {
      _pending.add(ProviderFailure(rule: m.group(1) == 'rule', name: m.group(2)!.trim(), reason: m.group(3)!.trim()));
      _timer ??= Timer(collectWindow, _flush);
      return;
    }
    final now = _now();
    final last = _lastShown[text];
    if (last != null && now.difference(last) < repeatWindow) return;
    _lastShown[text] = now;
    if (_lastShown.length > 64) _lastShown.remove(_lastShown.keys.first);
    show(text);
  }

  void _flush() {
    _timer = null;
    final batch = List<ProviderFailure>.of(_pending);
    _pending.clear();
    for (final rule in [false, true]) {
      final items = batch.where((f) => f.rule == rule).toList()..sort((a, b) => a.name.compareTo(b.name));
      if (items.isEmpty) continue;
      final names = {for (final f in items) f.name}.toList();
      final key = '${rule ? 'rule' : 'proxy'}:${names.join('\u0000')}';
      if (!_told.add(key)) continue;
      show(providerMessage(items, rule: rule));
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  /// 一批 provider 失败合成的那句话。
  /// 地址不是网址（`unsupported protocol scheme`：多半是模板里的占位文字没换）单独说清楚，其余只报名字、指到日志。
  static String providerMessage(List<ProviderFailure> items, {required bool rule}) {
    final kind = rule ? '规则集' : '节点集';
    final names = {for (final f in items) f.name}.toList();
    final shown = names.length <= 3 ? names.join('、') : '${names.take(3).join('、')} 等 ${names.length} 个';
    final unfilled = items.every((f) => f.reason.contains('unsupported protocol scheme'));
    if (unfilled) {
      final sample = placeholderOf(items.first.reason);
      final hint = sample == null ? '' : '（现在是「$sample」）';
      return '订阅里的$kind $shown 没有填有效的链接$hint，已跳过。到订阅配置里把地址换成真实链接';
    }
    return '订阅里的$kind $shown 加载失败，已跳过。详情见「动态 › 日志」';
  }

  /// 从 `Get "%E8%AE%A2…1": unsupported protocol scheme ""` 里取出引号里的地址并解码；取不到 / 太长返回 null。
  static String? placeholderOf(String reason) {
    final m = RegExp(r'"([^"]+)"').firstMatch(reason);
    if (m == null) return null;
    var s = m.group(1)!;
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {
      // 不是合法的百分号编码就原样显示
    }
    s = s.trim();
    return s.isEmpty || s.length > 40 ? null : s;
  }
}

/// 一个节点集 / 规则集的加载失败
class ProviderFailure {
  const ProviderFailure({required this.rule, required this.name, required this.reason});
  final bool rule;
  final String name;
  final String reason;
}

/// 全局那一份：内核日志回调（lib/manager/clash_manager.dart 的 onLog）把 error 级日志交给它
final coreErrorNotice = CoreErrorNotice(show: (message) => globalState.showNotifier(message));
