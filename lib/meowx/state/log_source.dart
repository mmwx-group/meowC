import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';

/// 日志来源（同 iOS 动态页日志段的「全部 / MeowX / 引擎」）。
enum LogSource {
  all,
  client,
  engine;

  String get label => switch (this) {
    LogSource.all => '全部',
    LogSource.client => 'MeowX',
    LogSource.engine => '引擎',
  };
}

/// 客户端（MeowX 自己）记的日志：经 commonPrint.log 写进同一份日志、payload 带「[APP] 」前缀；其余是内核的。
const _clientPrefix = '[APP] ';

bool isClientLog(Log l) => l.payload.startsWith(_clientPrefix);

bool logMatchesSource(Log l, LogSource s) => switch (s) {
  LogSource.all => true,
  LogSource.client => isClientLog(l),
  LogSource.engine => !isClientLog(l),
};

/// 列表上显示的消息：客户端日志去掉前缀（来源看筛选，不在每行重复写）。
String logMessage(Log l) => isClientLog(l) ? l.payload.substring(_clientPrefix.length) : l.payload;

/// 记一条客户端事件日志（「MeowX」来源）。
void meowLog(String message) => commonPrint.log(message);

/// 「记录日志」（同 iOS 的含义，2026-11-18）：内核日志一直订阅着（关着也照样看到警告 / 错误与 MeowX 的事件），
/// 开关只决定要不要额外记每条连接的分流与 DNS——也就是内核日志等级：开 = debug（mihomo 的分流行是 info、DNS 是 debug），
/// 关 = warning。「高级 › 通用」里还能单独调等级：调成 info / debug 时开关算开着。
bool logDetailsOn(LogLevel level) => level == LogLevel.debug || level == LogLevel.info;

LogLevel logLevelForDetails(bool on) => on ? LogLevel.debug : LogLevel.warning;
