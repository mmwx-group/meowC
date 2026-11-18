import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';
import 'config_kit.dart';

/// 内核配置 › 通用（对应 Bettbox lib/views/config/general.dart，各项读写一一照搬）。
class CoreGeneralPage extends StatelessWidget {
  const CoreGeneralPage({super.key});

  @override
  Widget build(BuildContext context) => MeSubPage.list(
    title: '通用',
    children: [
      MeSection(
        title: '内核',
        children: [
          const _LogLevelRow(),
          const _UaRow(),
          // 原版只在桌面端显示
          if (system.isDesktop) const _KeepAliveRow(),
          const _TestUrlRow(),
          const _OverrideTestUrlRow(),
        ],
      ),
      const MeSection(title: '入站', children: [_PortRow(), _Ipv6Row(), _AllowLanRow()]),
      const MeSection(
        title: '连接',
        children: [_UnifiedDelayRow(), _FindProcessRow(), _TcpConcurrentRow(), _GeodataLoaderRow()],
      ),
      const _ExternalControllerSection(),
    ],
  );
}

PatchClashConfig _patch(WidgetRef ref) => ref.read(patchClashConfigProvider.notifier);

class _LogLevelRow extends ConsumerWidget {
  const _LogLevelRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logLevel = ref.watch(patchClashConfigProvider.select((s) => s.logLevel));
    return CcPickerRow<LogLevel>(
      label: '日志等级',
      value: logLevel,
      values: LogLevel.values,
      text: (v) => v.name,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith(logLevel: v)),
    );
  }
}

/// 全局 UA：默认（不写 global-ua）/ 自定义（输入框，去掉首尾空格后不能为空）。
/// 选「自定义」时输入框预填本页上次见到的自定义值（同 Bettbox 的 `_lastCustomUa`）。
class _UaRow extends ConsumerStatefulWidget {
  const _UaRow();

  @override
  ConsumerState<_UaRow> createState() => _UaRowState();
}

class _UaRowState extends ConsumerState<_UaRow> {
  String _lastCustomUa = '';

  @override
  Widget build(BuildContext context) {
    final globalUa = ref.watch(patchClashConfigProvider.select((s) => s.globalUa));
    final isCustom = globalUa != null;
    if (isCustom) _lastCustomUa = globalUa;
    return CcPickerRow<bool>(
      label: 'UA',
      value: isCustom,
      values: const [false, true],
      text: (v) => v ? '自定义…' : '默认',
      display: isCustom ? '自定义' : '默认',
      onChanged: (custom) async {
        final notifier = _patch(ref);
        if (!custom) {
          notifier.updateState((s) => s.copyWith(globalUa: null));
          return;
        }
        final customUa = await ccInput(
          context,
          title: '自定义',
          initial: _lastCustomUa,
          hint: 'Clash.Meta',
          validator: (v) => (v == null || v.trim().isEmpty) ? ccEmptyTip('UA') : null,
        );
        if (customUa != null && customUa.trim().isNotEmpty) {
          notifier.updateState((s) => s.copyWith(globalUa: customUa.trim()));
        }
      },
    );
  }
}

class _KeepAliveRow extends ConsumerWidget {
  const _KeepAliveRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepAliveInterval = ref.watch(patchClashConfigProvider.select((s) => s.keepAliveInterval));
    return CcInputRow(
      label: 'TCP 保持活动间隔',
      value: '$keepAliveInterval 秒',
      onTap: () async {
        final value = await ccInput(
          context,
          title: 'TCP 保持活动间隔',
          initial: '$keepAliveInterval',
          suffix: '秒',
          resetValue: '$defaultKeepAliveInterval',
          keyboard: TextInputType.number,
          validator: ccInt('间隔'),
        );
        if (value == null) return;
        final intValue = int.parse(value);
        _patch(ref).updateState((s) => s.copyWith(keepAliveInterval: intValue));
      },
    );
  }
}

const _customTestUrl = '__CUSTOM_TEST_URL__';

/// 测试链接：预设列表 + 自定义。开着「测试链接覆盖配置」时，改了就重新应用配置（同 Bettbox）。
class _TestUrlRow extends ConsumerWidget {
  const _TestUrlRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final testUrl = ref.watch(appSettingProvider.select((s) => s.testUrl));
    final isPresetUrl = presetTestUrls.contains(testUrl);
    return CcPickerRow<String>(
      label: '测试链接',
      value: isPresetUrl ? testUrl : _customTestUrl,
      values: const [...presetTestUrls, _customTestUrl],
      text: (v) => v == _customTestUrl ? '自定义 URL…' : v,
      display: testUrl,
      mono: true,
      width: 320,
      onChanged: (v) async {
        final notifier = ref.read(appSettingProvider.notifier);
        final overrideTestUrl = ref.read(overrideTestUrlProvider);
        if (v != _customTestUrl) {
          notifier.updateState((s) => s.copyWith(testUrl: v));
          if (overrideTestUrl) globalState.appController.applyProfileDebounce(silence: true);
          return;
        }
        final customUrl = await ccInput(
          context,
          title: '自定义 URL',
          initial: isPresetUrl ? '' : testUrl,
          resetValue: defaultTestUrl,
          keyboard: TextInputType.url,
          validator: (input) {
            if (input == null || input.isEmpty) return ccEmptyTip('测试链接');
            if (!input.isHttpUrl) return '测试链接必须为URL';
            return null;
          },
        );
        if (customUrl != null) {
          notifier.updateState((s) => s.copyWith(testUrl: customUrl));
          if (overrideTestUrl) globalState.appController.applyProfileDebounce(silence: true);
        }
      },
    );
  }
}

/// 原版放在测试链接弹窗里的「覆盖配置」开关：用这里的测试链接替换配置里各组的测试链接。
class _OverrideTestUrlRow extends ConsumerWidget {
  const _OverrideTestUrlRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrideTestUrl = ref.watch(overrideTestUrlProvider);
    return MeSwitchRow(
      label: '测试链接覆盖配置',
      subtitle: '用上面的测试链接替换配置里代理组的测试链接',
      value: overrideTestUrl,
      onChanged: (v) {
        ref.read(overrideTestUrlProvider.notifier).value = v;
        globalState.appController.applyProfileDebounce(silence: true);
      },
    );
  }
}

class _PortRow extends ConsumerWidget {
  const _PortRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mixedPort = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));
    return CcInputRow(
      label: '端口',
      subtitle: '混合端口；HTTP / Socks / Redir / Tproxy 端口在「更多」里',
      value: '$mixedPort',
      onTap: () => showDialog<void>(context: context, builder: (_) => const _PortDialog()),
    );
  }
}

class _Ipv6Row extends ConsumerWidget {
  const _Ipv6Row();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ipv6 = ref.watch(patchClashConfigProvider.select((s) => s.ipv6));
    return MeSwitchRow(
      label: 'IPv6',
      subtitle: '开启后将可以接收 IPv6 流量',
      value: ipv6,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith(ipv6: v)),
    );
  }
}

class _AllowLanRow extends ConsumerWidget {
  const _AllowLanRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowLan = ref.watch(patchClashConfigProvider.select((s) => s.allowLan));
    return MeSwitchRow(
      label: '局域网代理',
      subtitle: '允许通过局域网访问代理',
      value: allowLan,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith(allowLan: v)),
    );
  }
}

class _UnifiedDelayRow extends ConsumerWidget {
  const _UnifiedDelayRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unifiedDelay = ref.watch(patchClashConfigProvider.select((s) => s.unifiedDelay));
    return MeSwitchRow(
      label: '统一延迟',
      subtitle: '去除握手解析等额外延迟',
      value: unifiedDelay,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith(unifiedDelay: v)),
    );
  }
}

/// 查找进程：开 = always、关 = off（配置里别的取值也显示成关，同 Bettbox）。
class _FindProcessRow extends ConsumerWidget {
  const _FindProcessRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final findProcess = ref.watch(patchClashConfigProvider.select((s) => s.findProcessMode == FindProcessMode.always));
    return MeSwitchRow(
      label: '查找进程',
      subtitle: '开启后可以匹配查找进程',
      value: findProcess,
      onChanged: (v) =>
          _patch(ref).updateState((s) => s.copyWith(findProcessMode: v ? FindProcessMode.always : FindProcessMode.off)),
    );
  }
}

class _TcpConcurrentRow extends ConsumerWidget {
  const _TcpConcurrentRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tcpConcurrent = ref.watch(patchClashConfigProvider.select((s) => s.tcpConcurrent));
    return MeSwitchRow(
      label: 'TCP 并发',
      subtitle: '开启后允许 TCP 并发连接',
      value: tcpConcurrent,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith(tcpConcurrent: v)),
    );
  }
}

/// GEO 节能：开 = memconservative、关 = standard。
class _GeodataLoaderRow extends ConsumerWidget {
  const _GeodataLoaderRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMemconservative = ref.watch(
      patchClashConfigProvider.select((s) => s.geodataLoader == GeodataLoader.memconservative),
    );
    return MeSwitchRow(
      label: 'GEO 节能',
      subtitle: '使用 GEO 低内存加载器',
      value: isMemconservative,
      onChanged: (v) => _patch(
        ref,
      ).updateState((s) => s.copyWith(geodataLoader: v ? GeodataLoader.memconservative : GeodataLoader.standard)),
    );
  }
}

/// 外部控制：打开时生成新密码并重新应用配置，关掉也重新应用；开着时下面一行是控制密码（可改、复制、开在线面板）。
class _ExternalControllerSection extends ConsumerWidget {
  const _ExternalControllerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final hasExternalController = ref.watch(
      patchClashConfigProvider.select((s) => s.externalController == ExternalControllerStatus.open),
    );
    final secret = hasExternalController ? ref.watch(patchClashConfigProvider.select((s) => s.secret)) ?? '' : '';
    return MeSection(
      title: '外部控制',
      children: [
        MeSwitchRow(
          label: '外部控制',
          subtitle: '通过在线端口控制内核（127.0.0.1:9090）',
          value: hasExternalController,
          onChanged: (v) async {
            if (v) {
              final newSecret = utils.generateSecret();
              _patch(
                ref,
              ).updateState((s) => s.copyWith(externalController: ExternalControllerStatus.open, secret: newSecret));
            } else {
              _patch(ref).updateState((s) => s.copyWith(externalController: ExternalControllerStatus.close));
            }
            await globalState.appController.applyProfile();
          },
        ),
        if (hasExternalController)
          MeRow(
            label: '控制密码',
            subtitle: secret.isEmpty ? 'RESTful API 的访问密码' : secret,
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => _SecretDialog(currentSecret: secret),
            ),
            trailing: secret.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.open_in_new_rounded, size: 20, color: mm.t2),
                        tooltip: '在线面板',
                        onPressed: () async {
                          final uri = Uri.parse(
                            'http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090&secret=$secret',
                          );
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          }
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.copy_rounded, size: 20, color: mm.t2),
                        tooltip: '复制',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: secret));
                          globalState.showNotifier('密码已复制到剪贴板');
                        },
                      ),
                    ],
                  ),
          ),
      ],
    );
  }
}

/// 改控制密码：保存后重新应用配置（原版没有校验，留空也能存）。
class _SecretDialog extends ConsumerStatefulWidget {
  const _SecretDialog({required this.currentSecret});

  final String currentSecret;

  @override
  ConsumerState<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends ConsumerState<_SecretDialog> {
  late final _c = TextEditingController(text: widget.currentSecret);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _patch(ref).updateState((s) => s.copyWith(secret: _c.text));
    Navigator.of(context).pop();
    await globalState.appController.applyProfile();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('控制密码'),
    content: TextField(
      controller: _c,
      autofocus: true,
      decoration: const InputDecoration(labelText: '控制密码', hintText: 'RESTful API 的访问密码'),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

/// 端口：混合端口常显，「更多」展开 HTTP / Socks / Redir / Tproxy。每个端口 0 = 关闭，否则 1024–49151、且不能与另外四个重复；
/// 「重置」确认后恢复 7890 / 0 / 0 / 0 / 0。与 Bettbox `_PortDialog` 同一套规则。
class _PortDialog extends ConsumerStatefulWidget {
  const _PortDialog();

  @override
  ConsumerState<_PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends ConsumerState<_PortDialog> {
  final _form = GlobalKey<FormState>();
  bool _isMore = false;

  late final TextEditingController _mixed, _http, _socks, _redir, _tproxy;

  @override
  void initState() {
    super.initState();
    final s = ref.read(patchClashConfigProvider);
    _mixed = TextEditingController(text: '${s.mixedPort}');
    _http = TextEditingController(text: '${s.port}');
    _socks = TextEditingController(text: '${s.socksPort}');
    _redir = TextEditingController(text: '${s.redirPort}');
    _tproxy = TextEditingController(text: '${s.tproxyPort}');
  }

  @override
  void dispose() {
    for (final c in [_mixed, _http, _socks, _redir, _tproxy]) {
      c.dispose();
    }
    super.dispose();
  }

  List<TextEditingController> get _all => [_mixed, _http, _socks, _redir, _tproxy];

  FormFieldValidator<String> _validator(String label, TextEditingController self) => (value) {
    if (value == null || value.isEmpty) return ccEmptyTip(label);
    final port = int.tryParse(value);
    if (port == null) return ccNumberTip(label);
    if (port == 0) return null;
    if (port < 1024 || port > 49151) return '$label 必须在 1024 到 49151 之间，0 为关闭';
    final others = [
      for (final c in _all)
        if (c != self) c.text.trim(),
    ];
    if (others.contains(value.trim())) return '请输入不同的端口';
    return null;
  };

  Future<void> _reset() async {
    if (!await ccConfirm(context, message: '确定要重置吗？', confirmLabel: '重置')) return;
    _patch(ref).updateState((s) => s.copyWith(mixedPort: 7890, port: 0, socksPort: 0, redirPort: 0, tproxyPort: 0));
    if (mounted) Navigator.of(context).pop();
  }

  void _submit() {
    if (_form.currentState?.validate() == false) return;
    _patch(ref).updateState(
      (s) => s.copyWith(
        mixedPort: int.parse(_mixed.text),
        port: int.parse(_http.text),
        socksPort: int.parse(_socks.text),
        redirPort: int.parse(_redir.text),
        tproxyPort: int.parse(_tproxy.text),
      ),
    );
    Navigator.of(context).pop();
  }

  Widget _field(String label, TextEditingController c) => TextFormField(
    controller: c,
    keyboardType: TextInputType.number,
    onFieldSubmitted: (_) => _submit(),
    decoration: InputDecoration(labelText: label, errorMaxLines: 3),
    validator: _validator(label, c),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('端口'),
    content: Form(
      key: _form,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutQuad,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            _field('混合端口', _mixed),
            if (_isMore) ...[
              _field('端口', _http),
              _field('Socks 端口', _socks),
              _field('Redir 端口', _redir),
              _field('Tproxy 端口', _tproxy),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => setState(() => _isMore = !_isMore), child: Text(_isMore ? '收起' : '更多')),
      TextButton(onPressed: _reset, child: const Text('重置')),
      FilledButton(onPressed: _submit, child: const Text('提交')),
    ],
  );
}
