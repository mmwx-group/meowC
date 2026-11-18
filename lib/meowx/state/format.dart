/// 与 iOS 端一致的数值格式：字节最小 KB（`%.0f KB / %.1f MB / %.2f GB`），速率 = 字节 + "/s"，时长 `Ns / MmSs / HhMm`。
String fmtSize(num bytes) {
  const kb = 1024.0, mb = kb * 1024, gb = mb * 1024;
  if (bytes < mb) return '${(bytes / kb).round()} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(2)} GB';
}

String fmtRate(num bytesPerSecond) => '${fmtSize(bytesPerSecond)}/s';

/// 已运行 HH:MM:SS
String fmtUptime(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return '${two(h)}:${two(m)}:${two(s)}';
}

/// 连接持续：Ns / MmSs / HhMm
String fmtElapsed(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m${d.inSeconds % 60}s';
  return '${d.inHours}h${d.inMinutes % 60}m';
}

/// 订阅到期：`expire ≥ 4102444799`（2099-12-31）视为永久。
const permanentExpireThreshold = 4102444799;

bool isPermanentExpire(int expireUnix) => expireUnix >= permanentExpireThreshold;

String fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前
String fmtRelative(DateTime t, [DateTime? now]) {
  final diff = (now ?? DateTime.now()).difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  return '${diff.inDays} 天前';
}

/// 行首图标块里的字：节点名里有国旗就用那面国旗（🇭🇰，2026-11-17 用户要旗帜、不要 HK 这种字母；Windows 靠主题里的 Twemoji 回落画出来），
/// 没有国旗取名字里的第一个字母 / 数字 / 汉字。
String nodeTileLabel(String name) {
  final runes = name.runes.toList();
  bool flag(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
  for (var i = 0; i + 1 < runes.length; i++) {
    if (flag(runes[i]) && flag(runes[i + 1])) return String.fromCharCodes([runes[i], runes[i + 1]]);
  }
  // 没有国旗：取第一个字母 / 数字 / 汉字，跳过开头的括号与符号（「[AgentB] 节点」→ A）
  final first = RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(name)?.group(0);
  return first == null ? '?' : first.toUpperCase();
}

/// 名字旁边已经有图标块画着它的国旗时，名字里那面国旗不再重复写（2026-11-17 用户要求）：去掉 [nodeTileLabel] 取到的那面国旗
/// 和它后面的空白；名字里没有国旗、或去掉后什么都不剩时原样返回。
String nodeTitleWithoutFlag(String name) {
  final flag = nodeTileLabel(name);
  final runes = flag.runes.toList();
  if (runes.length != 2 || runes.any((r) => r < 0x1F1E6 || r > 0x1F1FF)) return name;
  final i = name.indexOf(flag);
  final rest = (name.substring(0, i) + name.substring(i + flag.length).trimLeft()).trim();
  return rest.isEmpty ? name : rest;
}
