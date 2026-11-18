import 'package:bett_box/common/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/m3.dart';
import '../../../theme/morph_menu.dart';
import '../../../theme/page_title.dart';
import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';

/// 「内核配置」各页共用的小件：确认框、带校验的输入框、带显示值的选项行、字符串列表 / 键值表编辑页、
/// 网络设置改动后的重载。读写逻辑照搬 Bettbox 的 lib/views/config/，只换成 M3 的样子。

/// 改了网络（TUN / VPN）相关设置后：安卓上 VPN 开着、内核在跑时提示重启 VPN 才生效（带「重启」按钮），
/// 其它情况直接把新配置推给内核。与 Bettbox network.dart 的 `_handleNetworkConfigChange` 一致。
Future<void> handleNetworkConfigChange(WidgetRef ref) async {
  if (system.isAndroid) {
    final isVpnEnabled = ref.read(vpnSettingProvider).enable;
    final isCoreRunning = ref.read(runTimeProvider) != null;
    if (isVpnEnabled && isCoreRunning) {
      globalState.showNotifier(
        '重启 VPN 后生效',
        actionLabel: '重启',
        showCountdown: true,
        onAction: () async {
          await globalState.appController.restartCore();
          globalState.showNotifier('已重启');
        },
      );
      return;
    }
  }
  globalState.appController.updateClashConfig();
}

/// 确认框：点确定返回 true，其余 false。
Future<bool> ccConfirm(
  BuildContext context, {
  String? title,
  required String message,
  String confirmLabel = '确定',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: title == null ? null : Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(confirmLabel)),
      ],
    ),
  );
  return ok == true;
}

/// 「重置」确认（各页右上角的重置钮、NTP、实验性分组末行的重置共用）。
Future<bool> ccConfirmReset(BuildContext context) =>
    ccConfirm(context, title: '重置', message: '确定要重置吗？', confirmLabel: '重置');

/// 页面右上角的「重置」圆钮：先确认，确认了才执行 [onReset]。
class CcResetButton extends StatelessWidget {
  const CcResetButton({super.key, required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => RoundGlassButton(
    icon: Icons.replay_rounded,
    tooltip: '重置',
    onTap: () async {
      if (await ccConfirmReset(context)) onReset();
    },
  );
}

/// 页面右上角的「添加」圆钮。
class CcAddButton extends StatelessWidget {
  const CcAddButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      RoundGlassButton(icon: Icons.add_rounded, filled: true, tooltip: '添加', onTap: onTap);
}

/// 「不能为空」「必须为数字」这类校验文案（与 Bettbox 的中文翻译同词）。
String ccEmptyTip(String label) => '$label不能为空';
String ccNumberTip(String label) => '$label必须为数字';

/// 非空校验。
FormFieldValidator<String> ccNotEmpty(String label) =>
    (v) => (v == null || v.isEmpty) ? ccEmptyTip(label) : null;

/// 非空 + 整数校验。
FormFieldValidator<String> ccInt(String label) => (v) {
  if (v == null || v.isEmpty) return ccEmptyTip(label);
  if (int.tryParse(v) == null) return ccNumberTip(label);
  return null;
};

/// 带校验的单行输入框（对应 Bettbox 的 InputDialog）：校验不过不让确定；
/// [resetValue] 不为 null 且与初值不同时多一个「重置」，点了直接返回 [resetValue]（同 Bettbox）。取消返回 null。
Future<String?> ccInput(
  BuildContext context, {
  required String title,
  required String initial,
  String? label,
  String? hint,
  String? suffix,
  String? resetValue,
  TextInputType? keyboard,
  FormFieldValidator<String>? validator,
}) => showDialog<String>(
  context: context,
  builder: (_) => _InputDialog(
    title: title,
    initial: initial,
    label: label,
    hint: hint,
    suffix: suffix,
    resetValue: resetValue,
    keyboard: keyboard,
    validator: validator,
  ),
);

class _InputDialog extends StatefulWidget {
  const _InputDialog({
    required this.title,
    required this.initial,
    this.label,
    this.hint,
    this.suffix,
    this.resetValue,
    this.keyboard,
    this.validator,
  });

  final String title;
  final String initial;
  final String? label;
  final String? hint;
  final String? suffix;
  final String? resetValue;
  final TextInputType? keyboard;
  final FormFieldValidator<String>? validator;

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  final _form = GlobalKey<FormState>();
  late final _c = TextEditingController(text: widget.initial);

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
    final reset = widget.resetValue;
    return AlertDialog(
      // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
      scrollable: true,
      title: Text(widget.title),
      content: Form(
        key: _form,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: TextFormField(
          controller: _c,
          autofocus: true,
          keyboardType: widget.keyboard,
          validator: widget.validator,
          onFieldSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            suffixText: widget.suffix,
            errorMaxLines: 3,
          ),
        ),
      ),
      actions: [
        if (reset != null && widget.initial != reset)
          TextButton(onPressed: () => Navigator.of(context).pop(reset), child: const Text('重置')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

/// 选项行（同 [MePickerRow]），但行尾显示的值可以与菜单里的文字不同：
/// 「自定义」这类选项在菜单里叫「自定义…」，行尾要显示实际填的值。
class CcPickerRow<T> extends StatelessWidget {
  const CcPickerRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.value,
    required this.values,
    required this.text,
    required this.onChanged,
    this.display,
    this.mono = false,
    this.width = 240,
  });

  final String label;
  final String? subtitle;
  final T value;
  final List<T> values;
  final String Function(T) text;

  /// 行尾显示的值（缺省 = text(value)）
  final String? display;
  final bool mono;
  final double width;

  /// 选中任何一项都会回调，包括当前项（「自定义…」再点一次要能重新输入）
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => MeowMenuButton<T>(
    width: width,
    alignEnd: true,
    anchorWidth: 160,
    fadeTrigger: false,
    fromRadius: 12,
    onSelected: onChanged,
    entries: () => [for (final v in values) MeowMenuItem(v, text(v), checked: v == value)],
    builder: (_, open) =>
        MeRow(label: label, subtitle: subtitle, value: display ?? text(value), mono: mono, chevron: true, onTap: open),
  );
}

/// 输入行：行尾是当前值，点了弹 [ccInput]。
class CcInputRow extends StatelessWidget {
  const CcInputRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onTap,
    this.mono = true,
  });

  final String label;
  final String? subtitle;
  final String value;
  final bool mono;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      MeRow(label: label, subtitle: subtitle, value: value, mono: mono, chevron: true, onTap: onTap);
}

/// 进列表 / 子页的入口行：右侧写条数或摘要。
class CcLinkRow extends StatelessWidget {
  const CcLinkRow({super.key, required this.label, this.subtitle, this.value, required this.onTap});

  final String label;
  final String? subtitle;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      MeRow(label: label, subtitle: subtitle, value: value, chevron: true, onTap: onTap);
}

/// 条目卡（列表 / 键值表编辑页共用）：每条点了编辑、右侧删除钮与拖动柄，可拖动排序。没有条目时显示「暂无数据」。
class _EditableItemsCard extends StatelessWidget {
  const _EditableItemsCard({
    required this.count,
    required this.title,
    this.subtitle,
    required this.keyOf,
    required this.onTap,
    required this.onDelete,
    required this.onReorder,
    this.canDelete,
  });

  final int count;
  final String Function(int) title;
  final String Function(int)? subtitle;
  final String Function(int) keyOf;
  final void Function(int) onTap;
  final void Function(int) onDelete;
  final void Function(int oldIndex, int newIndex) onReorder;
  final bool Function(int)? canDelete;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final mm = context.mm;
    if (count == 0) {
      return MeSection(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Text(
              '暂无数据，点右上角「+」添加',
              style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
            ),
          ),
        ],
      );
    }
    // 拖动排序要求每条的 key 唯一：配置里偶有重复的条目，按第几次出现区分
    final seen = <String, int>{};
    final keys = [
      for (var i = 0; i < count; i++)
        () {
          final k = keyOf(i);
          final n = seen[k] = (seen[k] ?? 0) + 1;
          return '$k#$n';
        }(),
    ];
    return Material(
      color: cs.card,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: ReorderableListView.builder(
        // 整页由 MeSubPage 的 ListView 滚动；这里只按内容高度排
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: count,
        // onReorderItem 给的 newIndex 已按「先移走再插入」调整过（Bettbox 用旧的 onReorder 自己减一，结果相同）
        onReorderItem: onReorder,
        itemBuilder: (context, i) {
          final deletable = canDelete?.call(i) ?? true;
          final sub = subtitle?.call(i);
          return Material(
            key: ValueKey(keys[i]),
            color: cs.card,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (i > 0) const MeSegmentGap(),
                InkWell(
                  onTap: () => onTap(i),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title(i),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t1),
                              ),
                              if (sub != null)
                                Text(
                                  sub,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: MeowFont.mono(size: MeowFont.footnote, color: mm.t2),
                                ),
                            ],
                          ),
                        ),
                        if (deletable)
                          IconButton(
                            tooltip: '删除',
                            icon: Icon(Icons.close_rounded, size: 18, color: mm.t2),
                            onPressed: () => onDelete(i),
                          ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle_rounded, size: 20, color: mm.t2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 字符串列表编辑页（对应 Bettbox 的 ListInputPage）：添加 / 点按编辑 / 删除 / 拖动排序，值不能为空、不能重复。
/// [watch] 读当前列表（在 build 里调，跟着 provider 刷新），[onChange] 收到整份新列表。
class CcListPage extends ConsumerWidget {
  const CcListPage({
    super.key,
    required this.title,
    required this.watch,
    required this.onChange,
    this.actions = const [],
    this.caption,
    this.hint,
  });

  final String title;
  final List<String> Function(WidgetRef ref) watch;
  final void Function(WidgetRef ref, List<String> items) onChange;

  /// 添加钮之前的额外圆钮（重置等）
  final List<Widget> actions;
  final String? caption;
  final String? hint;

  Future<void> _addOrEdit(BuildContext context, WidgetRef ref, List<String> items, [int? index]) async {
    final current = index == null ? null : items[index];
    final value = await ccInput(
      context,
      title: title,
      initial: current ?? '',
      label: '值',
      hint: hint,
      validator: (v) {
        // 与 Bettbox 一致：先查重（编辑时与自己相同不算），再查空
        if (items.contains(v) && v != current) return '值当前已存在';
        if (v == null || v.isEmpty) return ccEmptyTip('值');
        return null;
      },
    );
    if (value == null) return;
    final next = List<String>.from(items);
    if (index != null) {
      next[index] = value;
    } else {
      next.add(value);
    }
    onChange(ref, next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = watch(ref);
    return MeSubPage.list(
      title: title,
      actions: [
        ...actions,
        CcAddButton(onTap: () => _addOrEdit(context, ref, items)),
      ],
      children: [
        _EditableItemsCard(
          count: items.length,
          title: (i) => items[i],
          keyOf: (i) => items[i],
          onTap: (i) => _addOrEdit(context, ref, items, i),
          onDelete: (i) => onChange(ref, List<String>.from(items)..removeAt(i)),
          onReorder: (o, n) {
            final next = List<String>.from(items);
            next.insert(n, next.removeAt(o));
            onChange(ref, next);
          },
        ),
        if (caption != null) MeCaption(caption!),
      ],
    );
  }
}

/// 键值表编辑页（对应 Bettbox 的 MapInputPage）：键不能为空、不能重复，值不能为空；[canDelete] 返回 false 的条目不给删。
class CcMapPage extends ConsumerWidget {
  const CcMapPage({
    super.key,
    required this.title,
    required this.watch,
    required this.onChange,
    this.canDelete,
    this.caption,
    this.keyHint,
    this.valueHint,
  });

  final String title;
  final Map<String, String> Function(WidgetRef ref) watch;
  final void Function(WidgetRef ref, Map<String, String> map) onChange;
  final bool Function(WidgetRef ref, MapEntry<String, String> entry)? canDelete;
  final String? caption;
  final String? keyHint;
  final String? valueHint;

  Future<void> _addOrEdit(
    BuildContext context,
    WidgetRef ref,
    List<MapEntry<String, String>> items, [
    int? index,
  ]) async {
    final current = index == null ? null : items[index];
    final entry = await showDialog<MapEntry<String, String>>(
      context: context,
      builder: (_) => _KeyValueDialog(
        title: title,
        initialKey: current?.key ?? '',
        initialValue: current?.value ?? '',
        keyHint: keyHint,
        valueHint: valueHint,
        keyExists: (k) => items.any((e) => e.key == k) && current?.key != k,
      ),
    );
    if (entry == null) return;
    final next = List<MapEntry<String, String>>.from(items);
    if (index != null) {
      next[index] = entry;
    } else {
      next.add(entry);
    }
    onChange(ref, Map.fromEntries(next));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = watch(ref).entries.toList();
    return MeSubPage.list(
      title: title,
      actions: [CcAddButton(onTap: () => _addOrEdit(context, ref, items))],
      children: [
        _EditableItemsCard(
          count: items.length,
          title: (i) => items[i].key,
          subtitle: (i) => items[i].value,
          keyOf: (i) => items[i].key,
          canDelete: canDelete == null ? null : (i) => canDelete!(ref, items[i]),
          onTap: (i) => _addOrEdit(context, ref, items, i),
          onDelete: (i) => onChange(ref, Map.fromEntries(List<MapEntry<String, String>>.from(items)..removeAt(i))),
          onReorder: (o, n) {
            final next = List<MapEntry<String, String>>.from(items);
            next.insert(n, next.removeAt(o));
            onChange(ref, Map.fromEntries(next));
          },
        ),
        if (caption != null) MeCaption(caption!),
      ],
    );
  }
}

class _KeyValueDialog extends StatefulWidget {
  const _KeyValueDialog({
    required this.title,
    required this.initialKey,
    required this.initialValue,
    required this.keyExists,
    this.keyHint,
    this.valueHint,
  });

  final String title;
  final String initialKey;
  final String initialValue;
  final bool Function(String key) keyExists;
  final String? keyHint;
  final String? valueHint;

  @override
  State<_KeyValueDialog> createState() => _KeyValueDialogState();
}

class _KeyValueDialogState extends State<_KeyValueDialog> {
  final _form = GlobalKey<FormState>();
  late final _k = TextEditingController(text: widget.initialKey);
  late final _v = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _k.dispose();
    _v.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    Navigator.of(context).pop(MapEntry(_k.text, _v.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: Form(
      key: _form,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _k,
            autofocus: true,
            minLines: 1,
            maxLines: 2,
            decoration: InputDecoration(labelText: '键', hintText: widget.keyHint, errorMaxLines: 3),
            validator: (v) {
              if (widget.keyExists(v ?? '')) return '键当前已存在';
              if (v == null || v.isEmpty) return ccEmptyTip('键');
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _v,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(labelText: '值', hintText: widget.valueHint, errorMaxLines: 3),
            validator: ccNotEmpty('值'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      FilledButton(onPressed: _submit, child: const Text('确定')),
    ],
  );
}
