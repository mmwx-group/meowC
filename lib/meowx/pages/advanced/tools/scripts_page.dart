import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/meowx/pages/editor/editor_page.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/meowx/theme/target_icon.dart' show CommonTargetIcon;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/haptics.dart';
import '../../../theme/m3.dart';
import '../../../theme/m3_kit.dart';
import '../../../theme/morph_menu.dart';
import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';
import 'tools_kit.dart';

/// 覆写脚本（原 Bettbox 的 lib/views/profiles/scripts.dart 按原功能重写成 M3 页）：
/// 脚本列表（同一时间只启用一个）、导入（代码 / URL / 文件）、编辑、自定义选项、同步、导出、删除，
/// 右上角设置进「各配置文件是否使用全局脚本覆写」。读写的 provider 与调用的 controller 方法和原页一致，只换界面。

const Duration _kMinLoadingDuration = Duration(seconds: 1);
const Duration _kCachedMinLoadingDuration = Duration(milliseconds: 500);

/// 正在读脚本的自定义选项（读一次要跑一遍脚本，连点只认第一次）
bool _extractingOptions = false;

/// 脚本返回的 options / icons 整理成开关表与图标表；开关的值以脚本里已存的自定义值为准（只认脚本还声明着的键）
(Map<String, bool>, Map<String, String>) _processScriptData(Map<String, dynamic> data, Script script) {
  final rawOptions = data['options'];
  final rawIcons = data['icons'];

  final options = <String, bool>{};
  if (rawOptions is Map) {
    rawOptions.forEach((k, v) {
      options[k.toString()] = v is bool ? v : true;
    });
  }
  if (script.customOptions != null) {
    script.customOptions!.forEach((k, v) {
      if (options.containsKey(k)) options[k] = v;
    });
  }

  final icons = <String, String>{};
  if (rawIcons is Map) {
    rawIcons.forEach((k, v) {
      if (v != null) icons[k.toString()] = v.toString();
    });
  }
  return (options, icons);
}

/// 读出脚本声明的自定义选项后，整页推入开关页（同原来的 showScriptCustomOptions：最短转圈 1 秒、有缓存 0.5 秒）。
Future<void> showMeowScriptOptions(BuildContext context, {required Script script}) async {
  if (_extractingOptions) return;
  _extractingOptions = true;
  try {
    await globalState.appController.safeRun(silence: false, needLoading: true, () async {
      final stopwatch = Stopwatch()..start();
      final cached = JavaScriptRuntimeManager.getCachedOptions(script.content);
      final data = cached ?? await JavaScriptRuntimeManager.extractScriptOptions(script.content);
      final (options, icons) = _processScriptData(data, script);

      final target = cached != null ? _kCachedMinLoadingDuration : _kMinLoadingDuration;
      final remaining = target.inMilliseconds - stopwatch.elapsedMilliseconds;
      if (remaining > 0) await Future.delayed(Duration(milliseconds: remaining));

      if (!context.mounted) return;
      // 不等页面关掉：safeRun 的转圈在页面推入时就该停
      mePush(context, ScriptOptionsPage(script: script, initialOptions: options, icons: icons));
    });
  } finally {
    _extractingOptions = false;
  }
}

enum _ScriptAction { edit, custom, sync, export, delete }

enum _ImportFrom { code, url, file }

class ScriptsPage extends ConsumerStatefulWidget {
  const ScriptsPage({super.key});

  @override
  ConsumerState<ScriptsPage> createState() => _ScriptsPageState();
}

class _ScriptsPageState extends ConsumerState<ScriptsPage> {
  Future<bool> _confirm(String text, {String ok = '确定', bool danger = false}) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: ctx.cs.error, foregroundColor: ctx.cs.onError)
                : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<void> _alert(String text) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(text),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('好'))],
    ),
  );

  Future<void> _delete(Script script) async {
    if (!await _confirm('确定删除脚本「${script.label}」吗？', ok: '删除', danger: true)) return;
    // 原页按名字删（ScriptState.del 按 label 找）
    ref.read(scriptStateProvider.notifier).del(script.label);
  }

  Future<void> _sync(String id) async {
    await globalState.appController.safeRun(silence: false, () async {
      await ref.read(scriptStateProvider.notifier).syncScript(id);
      globalState.showNotifier('同步成功');
    });
  }

  Future<void> _export(Script script) async {
    final res = await globalState.appController.safeRun<bool>(
      () async {
        final rawName = script.label.trim();
        final fileName = rawName.endsWith('.js') ? rawName : '$rawName.js';
        final value = await picker.saveFile(fileName, utf8.encode(script.content), allowedExtensions: ['js']);
        return value != null;
      },
      needLoading: true,
      title: '提示',
    );
    if (res == true && mounted) globalState.showNotifier('导出成功');
  }

  void _toggle(Script script) {
    MeowHaptics.toggle();
    // 打开 = 选中这个；关掉当前选中的 = 再设一次同一个 id（setId 对同一个 id 是取消选中）
    ref.read(scriptStateProvider.notifier).setId(script.id);
  }

  Future<void> _run(_ScriptAction action, Script script) async {
    switch (action) {
      case _ScriptAction.edit:
        _toEditor(script: script);
      case _ScriptAction.custom:
        await showMeowScriptOptions(context, script: script);
      case _ScriptAction.sync:
        await _sync(script.id);
      case _ScriptAction.export:
        await _export(script);
      case _ScriptAction.delete:
        await _delete(script);
    }
  }

  List<MeowMenuEntry<_ScriptAction>> _menuItems(Script script) => [
    const MeowMenuItem(_ScriptAction.edit, '编辑'),
    if (script.isCompatibleWithBettbox) const MeowMenuItem(_ScriptAction.custom, '自定义选项'),
    if (script.url != null && script.url!.isNotEmpty) const MeowMenuItem(_ScriptAction.sync, '同步'),
    const MeowMenuItem(_ScriptAction.export, '导出文件'),
    MeowMenuItem(_ScriptAction.delete, '删除', color: context.cs.error),
  ];

  // ——— 编辑器（与原页同一套保存 / 返回逻辑） ———

  Future<void> _editorSave(String title, String content, {Script? script, String? url}) async {
    if (script != null && script.content != content) {
      JavaScriptRuntimeManager.invalidateCachedOptions(script.content);
    }
    final notifier = ref.read(scriptStateProvider.notifier);
    var finalLabel = title.trim();
    if (finalLabel.isEmpty) finalLabel = notifier.getAvailableLabel('未命名');
    final newScript =
        script?.copyWith(label: finalLabel, content: content, url: url) ??
        Script.create(label: finalLabel, content: content, url: url);
    if (newScript.label != script?.label && notifier.isExits(newScript.label)) {
      await _alert('名称「${newScript.label}」已存在');
      return;
    }
    notifier.setScript(newScript);
    // 关掉编辑器（它在最上面）
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _editorPop(String title, String content, String raw, {Script? script}) async {
    if (content == raw) return true;
    final save = await _confirm('是否保存更改？', ok: '保存');
    if (save && mounted) {
      _editorSave(title, content, script: script, url: script?.url);
      return false;
    }
    return true;
  }

  Future<void> _toEditor({Script? script, String? initialContent, String? url, bool delayedFocus = false}) async {
    // 编辑器的 Rust 库按需加载（pages/editor.dart），进页面前等它就绪
    await ensureEditorRuntime();
    if (!mounted) return;
    final title = script?.label ?? '';
    final raw = script?.content ?? initialContent ?? scriptTemplate;
    var importedUrl = url ?? script?.url;
    BaseNavigator.push(
      context,
      EditorPage(
        titleEditable: true,
        title: title,
        supportRemoteDownload: true,
        delayedFocus: delayedFocus,
        onUrlImport: (downloadedUrl) => importedUrl = downloadedUrl,
        onSave: (_, title, content) {
          final scriptToSave = script?.copyWith(url: importedUrl);
          _editorSave(title, content, script: scriptToSave, url: importedUrl);
        },
        onPop: (_, title, content) => _editorPop(title, content, raw, script: script),
        languages: const [Language.javaScript],
        content: raw,
      ),
    );
  }

  // ——— 导入 ———

  Future<void> _import(_ImportFrom from) async {
    switch (from) {
      case _ImportFrom.code:
        _toEditor(delayedFocus: true);
      case _ImportFrom.url:
        await _importUrl();
      case _ImportFrom.file:
        await _importFile();
    }
  }

  Future<void> _importUrl() async {
    final url = await showDialog<String>(context: context, builder: (_) => const _UrlDialog());
    if (url == null || url.isEmpty) return;
    try {
      final res = await request.getTextResponseForUrl(url);
      if (mounted) _toEditor(initialContent: res.data, url: url);
    } catch (e) {
      if (mounted) await _alert('导入失败：$e');
    }
  }

  Future<void> _importFile() async {
    final file = await picker.pickerFile();
    final bytes = file?.bytes;
    if (bytes == null) return;
    final content = utf8.decode(bytes);
    if (mounted) _toEditor(initialContent: content);
  }

  @override
  Widget build(BuildContext context) {
    final (currentId, scripts) = ref.watch(scriptStateProvider.select((s) => (s.currentId, s.scripts)));
    final loading = ref.watch(loadingProvider);
    return MeSubPage.list(
      title: '脚本',
      actions: [
        M3IconButton(
          icon: Icons.settings_outlined,
          tooltip: '使用全局脚本覆写',
          onPressed: () => mePush(context, const ScriptOverridePage()),
        ),
        MeowMenuButton<_ImportFrom>(
          width: 220,
          alignEnd: true,
          fromRadius: 24,
          onSelected: _import,
          entries: () => const [
            MeowMenuItem(_ImportFrom.code, '通过代码导入'),
            MeowMenuItem(_ImportFrom.url, '通过 URL 导入'),
            MeowMenuItem(_ImportFrom.file, '通过文件导入'),
          ],
          builder: (_, open) => M3IconButton(icon: Icons.add_rounded, tooltip: '导入脚本', tonal: true, onPressed: open),
        ),
      ],
      children: [
        // 读选项 / 导出时的转圈（原页由 CommonScaffold 顶上的进度条显示 loadingProvider）
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (scripts.isEmpty)
          const ToolsEmptyCard(icon: Icons.code_rounded, text: '暂无脚本 · 点右上角「+」导入')
        else
          M3SegmentedList(
            children: [
              for (final s in scripts)
                _ScriptRow(
                  key: ValueKey(s.id),
                  script: s,
                  selected: s.id == currentId,
                  onToggle: (_) => _toggle(s),
                  menu: MeowMenuButton<_ScriptAction>(
                    width: 200,
                    alignEnd: true,
                    onSelected: (a) => _run(a, s),
                    entries: () => _menuItems(s),
                    builder: (_, open) => IconButton(
                      tooltip: '更多',
                      icon: Icon(Icons.more_vert_rounded, color: context.cs.onSurfaceVariant),
                      onPressed: open,
                    ),
                  ),
                ),
            ],
          ),
        const MeCaption('同一时间只启用一个脚本：加载配置时由它改写配置。各配置文件用不用脚本覆写，在右上角的设置里选。'),
      ],
    );
  }
}

class _ScriptRow extends StatelessWidget {
  const _ScriptRow({
    super.key,
    required this.script,
    required this.selected,
    required this.onToggle,
    required this.menu,
  });

  final Script script;
  final bool selected;
  final ValueChanged<bool> onToggle;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final url = script.url;
    final source = url != null && url.isNotEmpty ? (Uri.tryParse(url)?.host ?? url) : '本地脚本';
    return M3ListRow(
      title: script.label,
      subtitle: script.isCompatibleWithBettbox ? '$source · 可自定义' : source,
      subtitleMaxLines: 1,
      selected: selected,
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      onTap: () => onToggle(!selected),
      leading: M3IconTile(
        icon: Icons.javascript_rounded,
        shape: selected ? M3TileShape.circle : M3TileShape.rounded,
        bg: selected ? cs.primary : cs.surfaceContainerHighest,
        fg: selected ? cs.onPrimary : cs.onSurfaceVariant,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: selected, onChanged: onToggle, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
          menu,
        ],
      ),
    );
  }
}

/// 「通过 URL 导入」的输入框：空的、不是 URL 的不让提交。
class _UrlDialog extends StatefulWidget {
  const _UrlDialog();

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _form = GlobalKey<FormState>();
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    Navigator.of(context).pop(_c.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('通过 URL 导入'),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _c,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL', errorMaxLines: 2),
          onFieldSubmitted: (_) => _submit(),
          validator: (value) {
            if (value == null || value.isEmpty) return '请填写 URL';
            if (!value.isUrl) return '不是有效的 URL';
            return null;
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }
}

/// 各配置文件是否使用全局脚本覆写（原页右上角设置弹出的那张表）。改的是当前配置文件时立刻重载。
class ScriptOverridePage extends ConsumerWidget {
  const ScriptOverridePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final currentProfileId = ref.watch(currentProfileIdProvider);
    return MeSubPage.list(
      title: '使用全局脚本覆写',
      children: [
        if (profiles.isEmpty)
          const ToolsEmptyCard(icon: Icons.description_outlined, text: '没有配置文件，请先添加配置文件')
        else
          MeSection(
            children: [
              for (final p in profiles)
                MeSwitchRow(
                  label: p.label ?? p.id,
                  value: p.useScriptOverride,
                  onChanged: (value) async {
                    ref
                        .read(profilesProvider.notifier)
                        .updateProfile(p.id, (old) => old.copyWith(useScriptOverride: value));
                    if (p.id == currentProfileId) {
                      await globalState.appController.applyProfile(silence: true);
                    }
                  },
                ),
            ],
          ),
        const MeCaption('关掉的配置文件加载时不经过脚本改写。'),
      ],
    );
  }
}

/// 脚本的自定义选项（脚本里写了 Compatible_With_Bettbox 才有）：逐项开关，保存后写回脚本；
/// 改的是当前启用的脚本时重载配置。有没保存的改动时返回要先确认。
class ScriptOptionsPage extends ConsumerStatefulWidget {
  const ScriptOptionsPage({super.key, required this.script, required this.initialOptions, required this.icons});

  final Script script;
  final Map<String, bool> initialOptions;
  final Map<String, String> icons;

  @override
  ConsumerState<ScriptOptionsPage> createState() => _ScriptOptionsPageState();
}

class _ScriptOptionsPageState extends ConsumerState<ScriptOptionsPage> {
  late final Map<String, bool> _options = Map<String, bool>.from(widget.initialOptions);
  bool _dirty = false;
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    final scripts = ref.read(scriptStateProvider).scripts;
    final index = scripts.indexWhere((item) => item.id == widget.script.id);
    if (index == -1) {
      setState(() => _dirty = false);
      return;
    }
    final updated = scripts[index].copyWith(customOptions: Map<String, bool>.from(_options));
    ref.read(scriptStateProvider.notifier).setScript(updated);
    _dirty = false;
    if (mounted) setState(() => _saving = true);
    try {
      final apply = ref.read(scriptStateProvider).currentId == widget.script.id
          ? globalState.appController.applyProfile(silence: true)
          : Future<void>.value();
      await Future.wait([apply, Future<void>.delayed(_kMinLoadingDuration)]);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        Navigator.of(context).pop();
      }
    }
  }

  /// 返回时：没改动直接走；有改动问一句，「保存」= 保存后自己关页，「不保存」= 丢掉改动关页，点外面 = 留下。
  Future<void> _onBack() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('是否保存更改？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('不保存')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('保存')),
        ],
      ),
    );
    if (!mounted) return;
    if (res == true) {
      await _save();
    } else if (res == false) {
      Navigator.of(context).pop();
    }
  }

  static bool _isValidIconUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('data:image/');
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final keys = _options.keys.toList();
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: AbsorbPointer(
        absorbing: _saving,
        child: MeSubPage.list(
          title: '自定义选项',
          actions: [
            M3IconButton(
              icon: Icons.save_outlined,
              tooltip: '保存',
              tonal: _dirty,
              onPressed: _dirty && !_saving ? _save : null,
            ),
          ],
          children: [
            if (_saving) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                widget.script.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w700, color: cs.primary),
              ),
            ),
            if (keys.isEmpty)
              const ToolsEmptyCard(icon: Icons.tune_rounded, text: '这个脚本没有读到可自定义的选项')
            else
              MeSection(
                children: [
                  for (final key in keys)
                    MeSwitchRow(
                      leading: SizedBox.square(
                        dimension: 24,
                        child: _isValidIconUrl(widget.icons[key])
                            ? CommonTargetIcon(src: widget.icons[key]!, size: 24)
                            : Icon(Icons.alt_route_rounded, size: 22, color: cs.onSurfaceVariant),
                      ),
                      label: key,
                      value: _options[key] ?? true,
                      onChanged: (v) => setState(() {
                        _options[key] = v;
                        _dirty = true;
                      }),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
