import 'package:bett_box/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 首页网速折线的数据：最近 [SpeedHistoryBuffer.capacity] 秒的上下行速率 + 只增不减的样本序号。
///
/// 为什么不直接用 Bettbox 的 `trafficsProvider`：它只留 30 个点（`FixedList(30)`），而折线按 60 秒一屏画（与 iOS 一致），
/// 30 个点只够画到中间；满了之后长度也不再变，折线认不出「刚来了一个新点」。这里跟着它每秒的推送自己攒 60 个点
/// （网速卡在 widget 层监听后喂进来，见 [speedHistoryBufferProvider]），序号让折线知道新点什么时候到、该从哪里开始画
/// （见 `speed_card.dart` 的 `_SpeedChart`）。
@immutable
class SpeedHistoryState {
  const SpeedHistoryState(this.up, this.down, this.sequence);

  static const empty = SpeedHistoryState([], [], 0);

  final List<double> up, down;

  /// 攒过的样本总数（断开清空时归零）：最新一个点的绝对序号是 sequence − 1。
  final int sequence;
}

/// 纯逻辑：从 Bettbox 的 30 点定长列表里认出新样本、攒成 60 点（单测直接测它）。
class SpeedHistoryBuffer {
  static const capacity = 60;

  final _up = <double>[];
  final _down = <double>[];
  int _sequence = 0;
  Object? _lastSeen;

  SpeedHistoryState get state => SpeedHistoryState(List.unmodifiable(_up), List.unmodifiable(_down), _sequence);

  /// 喂一次 Bettbox 的当前列表。新样本 = 上次见过的最后一个对象之后的那些（按对象身份认：每秒推送都是新对象，
  /// 速率相同也分得清）；找不到它（列表被清空过、或离开太久整份都换了）就整份当新的。列表空了 = 断开，清零。
  /// 返回是否有变化。
  bool ingest<T>(List<T> list, double Function(T) up, double Function(T) down) {
    if (list.isEmpty) {
      if (_sequence == 0 && _up.isEmpty) return false;
      _up.clear();
      _down.clear();
      _sequence = 0;
      _lastSeen = null;
      return true;
    }
    if (identical(list.last, _lastSeen)) return false;
    var start = 0;
    for (var i = list.length - 1; i >= 0; i--) {
      if (identical(list[i], _lastSeen)) {
        start = i + 1;
        break;
      }
    }
    for (var i = start; i < list.length; i++) {
      _up.add(up(list[i]));
      _down.add(down(list[i]));
    }
    _sequence += list.length - start;
    final overflow = _up.length - capacity;
    if (overflow > 0) {
      _up.removeRange(0, overflow);
      _down.removeRange(0, overflow);
    }
    _lastSeen = list.last;
    return true;
  }
}

/// 网速卡用的那一份缓冲（全局一份，切 Tab 页面重建也不丢）。
///
/// 不做成随数据变化的 provider：provider 里 `ref.listen(trafficsProvider)` 每秒都会让 Riverpod 排一次重算、要一帧，
/// 不在首页也照样要（`dashboard_page_test` 的「不在首页不要帧」锁住了这一条）。改成网速卡在 widget 层监听、
/// 把每次推送喂进来：不在首页时监听回调只往这里追加，不重建也不要帧；切回首页那次重建直接拿到最新的 60 秒。
final speedHistoryBufferProvider = Provider<SpeedHistoryBuffer>((ref) => SpeedHistoryBuffer());

extension SpeedHistoryFeed on SpeedHistoryBuffer {
  /// 喂一次 Bettbox 的 traffics 列表。
  bool feed(List<Traffic> list) => ingest(list, (t) => t.up.value.toDouble(), (t) => t.down.value.toDouble());
}
