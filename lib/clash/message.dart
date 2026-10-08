import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/foundation.dart';

class ClashMessage {
  final controller = StreamController<Map<String, Object?>>.broadcast();

  ClashMessage._() {
    controller.stream.listen((message) {
      if (message.isEmpty) return;
      final m = AppMessage.fromJson(message);
      for (final AppMessageListener listener in _listeners) {
        switch (m.type) {
          case AppMessageType.log:
            listener.onLog(Log.fromJson(m.data));
          case AppMessageType.delay:
            listener.onDelay(Delay.fromJson(m.data));
          case AppMessageType.request:
            listener.onRequest(TrackerInfo.fromJson(m.data));
          case AppMessageType.loaded:
            listener.onLoaded(m.data);
        }
      }
    });
  }

  static final ClashMessage instance = ClashMessage._();

  final ObserverList<AppMessageListener> _listeners =
      ObserverList<AppMessageListener>();

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  void addListener(AppMessageListener listener) {
    _listeners.add(listener);
  }

  void removeListener(AppMessageListener listener) {
    _listeners.remove(listener);
  }

  // MeowX：核心每关一条连接就推一条 request 消息（约 1KB），只有旧「请求」页（我的 → 高级）在用。
  // 以前每条都在 UI 线程解信封、建 TrackerInfo、入库；切节点 / 换网一次关掉几百条连接时，几百条消息挤在一起处理，正好卡在点完节点之后。
  // 现在没人看请求页时只把原文留下（最近 maxLength 条，与请求列表的容量一致），页面打开时再按到达顺序补解：记录不丢，平时不占 UI 线程。

  /// 核心推来的 request 消息的开头。Go 的 encoding/json 按结构体字段的声明顺序输出，所以前缀固定；
  /// 核心哪天改了字段顺序，这里只是不再命中、退回逐条解码的老路，不会出错。
  static const _requestPrefix =
      '{"id":"","method":"message","data":{"type":"request"';

  final _pendingRequests = ListQueue<String>();
  int _requestWatchers = 0;

  /// [raw] 是 request 消息、且现在没有界面在看：留下原文并返回 true，调用方不用再解码。
  bool deferRequest(String raw) {
    if (_requestWatchers > 0 || !raw.startsWith(_requestPrefix)) return false;
    if (_pendingRequests.length >= maxLength) _pendingRequests.removeFirst();
    _pendingRequests.addLast(raw);
    return true;
  }

  /// 请求页打开时调：先把攒下的那些按到达顺序补上，之后的 request 消息照常逐条处理。
  void watchRequests() {
    _requestWatchers++;
    while (_pendingRequests.isNotEmpty) {
      final raw = _pendingRequests.removeFirst();
      try {
        final data = (json.decode(raw) as Map)['data'];
        if (data is Map<String, Object?>) controller.add(data);
      } catch (e) {
        commonPrint.log('replay request message failed: $e');
      }
    }
  }

  /// 请求页关掉时调。
  void unwatchRequests() {
    if (_requestWatchers > 0) _requestWatchers--;
  }

  /// 请求列表被清空时（换配置）连同还没解的一起丢掉。
  void clearPendingRequests() => _pendingRequests.clear();
}

final clashMessage = ClashMessage.instance;
