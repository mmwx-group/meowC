// po0 / GGY 加白共用的小工具：备注规范化、「上次上报」的时间写法（五端同一份规格：MeowX 仓库 Design/po0-ggy-results.md）。

/// 备注最多几个字符（按 Unicode 字符数）
const whitelistNoteMax = 40;

/// 还没报过时结果那一行的文字
const whitelistNeverReported = '还没上报';

/// 备注规范化：去掉首尾空白，超过 [whitelistNoteMax] 个字符的截掉后面的；空串 = 没有备注。
String normalizeWhitelistNote(String input) {
  final t = input.trim();
  final runes = t.runes;
  if (runes.length <= whitelistNoteMax) return t;
  return String.fromCharCodes(runes.take(whitelistNoteMax)).trimRight();
}

/// 「上次上报」的时间：一分钟内「刚刚」、一小时内「N 分钟前」、同一天「HH:mm」、跨天「M-d HH:mm」（跨年带年份）。
/// 时间在 [now] 之后（改过系统时钟）也算「刚刚」。
String fmtReportTime(DateTime t, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final diff = n.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  String two(int x) => x.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == n.year && t.month == n.month && t.day == n.day) return hm;
  if (t.year == n.year) return '${t.month}-${t.day} $hm';
  return '${t.year}-${t.month}-${t.day} $hm';
}
