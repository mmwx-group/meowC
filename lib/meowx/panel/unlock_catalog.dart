// 解锁检测的服务目录（与主控 unlock_catalog.go / 前端 unlock-services.ts 一一对应，顺序一致）。
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum UnlockCategory {
  streaming('流媒体'),
  ai('AI'),
  exchange('交易所'),
  other('其他');

  const UnlockCategory(this.label);
  final String label;
}

class UnlockServiceMeta {
  const UnlockServiceMeta(this.key, this.label, this.category, {this.info = false});
  final String key;
  final String label;
  final UnlockCategory category;

  /// 地区 / 信息类（Apple 地区、Steam 货币、CDN 节点…）：status=yes 只表示「测到了」，展示重点是 region
  final bool info;
}

const unlockServices = <UnlockServiceMeta>[
  UnlockServiceMeta('netflix', 'Netflix', UnlockCategory.streaming),
  UnlockServiceMeta('disneyplus', 'Disney+', UnlockCategory.streaming),
  UnlockServiceMeta('youtube_premium', 'YouTube Premium', UnlockCategory.streaming),
  UnlockServiceMeta('prime_video', 'Prime Video', UnlockCategory.streaming),
  UnlockServiceMeta('tvb_anywhere', 'TVB Anywhere+', UnlockCategory.streaming),
  UnlockServiceMeta('iqiyi', 'iQIYI 国际版', UnlockCategory.streaming, info: true),
  UnlockServiceMeta('bing', 'Bing', UnlockCategory.other, info: true),
  UnlockServiceMeta('apple', 'Apple 地区', UnlockCategory.other, info: true),
  UnlockServiceMeta('openai', 'ChatGPT', UnlockCategory.ai),
  UnlockServiceMeta('gemini', 'Gemini', UnlockCategory.ai),
  UnlockServiceMeta('claude', 'Claude', UnlockCategory.ai),
  UnlockServiceMeta('wikipedia', 'Wikipedia 可编辑', UnlockCategory.other),
  UnlockServiceMeta('google_play', 'Google Play', UnlockCategory.other, info: true),
  UnlockServiceMeta('google_search', 'Google 搜索无验证码', UnlockCategory.other),
  UnlockServiceMeta('steam', 'Steam 货币', UnlockCategory.other, info: true),
  UnlockServiceMeta('reddit', 'Reddit', UnlockCategory.other),
  UnlockServiceMeta('dazn', 'DAZN', UnlockCategory.streaming),
  UnlockServiceMeta('onetrust', 'OneTrust 地区', UnlockCategory.other, info: true),
  UnlockServiceMeta('youtube_cdn', 'YouTube CDN', UnlockCategory.streaming, info: true),
  UnlockServiceMeta('netflix_cdn', 'Netflix CDN', UnlockCategory.streaming, info: true),
  UnlockServiceMeta('sdggge', 'SD Gundam G Generation Eternal', UnlockCategory.other),
  // 交易所（主控 2026-11 加的；Spotify 注册同时去掉了）。OKX 的判定会带出它识别到的地区，按信息类展示
  UnlockServiceMeta('bybit', 'Bybit', UnlockCategory.exchange),
  UnlockServiceMeta('binance', 'Binance', UnlockCategory.exchange),
  UnlockServiceMeta('okx', 'OKX', UnlockCategory.exchange, info: true),
];

final _byKey = {for (final s in unlockServices) s.key: s};

UnlockServiceMeta unlockServiceMeta(String key) =>
    _byKey[key] ?? UnlockServiceMeta(key, key, UnlockCategory.other);

/// 结论口径：yes / originals_only / no / banned / failed
enum UnlockTone { ok, partial, bad, banned, muted }

({UnlockTone tone, String label}) unlockStatusMeta(String status) => switch (status) {
  'yes' => (tone: UnlockTone.ok, label: '已解锁'),
  'originals_only' => (tone: UnlockTone.partial, label: '仅自制剧'),
  'no' => (tone: UnlockTone.bad, label: '未解锁'),
  'banned' => (tone: UnlockTone.banned, label: 'IP 被封禁'),
  _ => (tone: UnlockTone.muted, label: '检测失败'),
};

bool isUnlocked(String status) => status == 'yes' || status == 'originals_only';

Color unlockToneColor(UnlockTone tone, MeowTokens mm) => switch (tone) {
  UnlockTone.ok => mm.good,
  UnlockTone.partial => mm.orange,
  UnlockTone.bad => mm.t3,
  UnlockTone.banned => mm.slow,
  UnlockTone.muted => mm.t3,
};

IconData unlockToneIcon(UnlockTone tone) => switch (tone) {
  UnlockTone.ok || UnlockTone.partial => Icons.lock_open_rounded,
  UnlockTone.muted => Icons.help_outline_rounded,
  _ => Icons.lock_rounded,
};
