import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:lpinyin/lpinyin.dart';

/// 节点排序（节点页「节点视图」菜单 → 排序）。沿用 Bettbox 的 `proxiesStyle.sortType`，托盘的节点菜单也读这一项
/// （托盘仍用 Bettbox 的 getSortProxies，名称排序的细节与这里不同）。
/// 都是稳定排序：比不出先后的保持订阅里的顺序。
extension ProxiesSortTypeLabel on ProxiesSortType {
  String get label => switch (this) {
    ProxiesSortType.none => '默认',
    ProxiesSortType.delay => '延迟',
    ProxiesSortType.name => '名称',
  };
}

/// 按 [sort] 排好的成员；[delayOf] 只在按延迟排时用到。
/// - 延迟：有读数的从低到高，没测过 / 测试中的接在后面，超时（<0 或 ≥100000，同 msStyle）垫底；
/// - 名称：中文按拼音、数字按数值（「节点 2」在「节点 10」前面），不分大小写。
/// Bettbox 自己的名称排序只比第一个字的拼音，同地区的节点之间顺序不定，这里不用它。
List<Proxy> sortNodes(List<Proxy> nodes, ProxiesSortType sort, {int? Function(Proxy p)? delayOf}) {
  if (sort == ProxiesSortType.none || nodes.length < 2) return nodes;
  final order = List<int>.generate(nodes.length, (i) => i);
  switch (sort) {
    case ProxiesSortType.none:
      return nodes;
    case ProxiesSortType.delay:
      final ms = [for (final p in nodes) delayOf?.call(p)];
      order.sort((a, b) {
        final ra = _delayRank(ms[a]), rb = _delayRank(ms[b]);
        if (ra != rb) return ra - rb;
        if (ra == 0 && ms[a] != ms[b]) return ms[a]! - ms[b]!;
        return a - b;
      });
    case ProxiesSortType.name:
      final keys = [for (final p in nodes) _nameKey(p.name)];
      order.sort((a, b) {
        final c = compareNatural(keys[a], keys[b]);
        return c != 0 ? c : a - b;
      });
  }
  return [for (final i in order) nodes[i]];
}

/// 0 = 有读数，1 = 没测过 / 测试中，2 = 超时。
int _delayRank(int? ms) => switch (ms) {
  null || 0 => 1,
  int v when v < 0 || v >= 100000 => 2,
  _ => 0,
};

/// 名称排序用的键：中文换成拼音、转小写。换组 / 重排时同一批名字反复用到，记下来（名字多到离谱就清空重记）。
final _nameKeys = <String, String>{};

String _nameKey(String name) {
  if (_nameKeys.length > 4096) _nameKeys.clear();
  return _nameKeys[name] ??= PinyinHelper.getPinyinE(name, separator: '', defPinyin: '').toLowerCase();
}

/// 自然顺序：连续的数字按数值比（前导 0 不算大小，数值相同时位数少的在前），其余逐个字符比。
int compareNatural(String a, String b) {
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i), cb = b.codeUnitAt(j);
    if (_isDigit(ca) && _isDigit(cb)) {
      final si = i, sj = j;
      while (i < a.length && _isDigit(a.codeUnitAt(i))) {
        i++;
      }
      while (j < b.length && _isDigit(b.codeUnitAt(j))) {
        j++;
      }
      final c = _compareNumber(a.substring(si, i), b.substring(sj, j));
      if (c != 0) return c;
      continue;
    }
    if (ca != cb) return ca - cb;
    i++;
    j++;
  }
  return (a.length - i) - (b.length - j);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

int _compareNumber(String x, String y) {
  final a = x.replaceFirst(_leadingZeros, ''), b = y.replaceFirst(_leadingZeros, '');
  if (a.length != b.length) return a.length - b.length;
  final c = a.compareTo(b);
  return c != 0 ? c : x.length - y.length;
}

final _leadingZeros = RegExp(r'^0+(?=\d)');
