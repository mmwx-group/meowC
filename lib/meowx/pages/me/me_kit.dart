import 'package:flutter/material.dart';

import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';

/// 「我的」页与它的二级页共用的元件：二级页骨架、白卡分组、设置行、胶囊钮、输入对话框。

/// 紧凑行（宽屏三列里的 36 高、13 号字）；不在它下面的行是标准行（二级页里的 52 高、15 号字）。
class MeDense extends InheritedWidget {
  const MeDense({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MeDense>() != null;

  @override
  bool updateShouldNotify(MeDense oldWidget) => false;
}

/// 二级页骨架（设计稿 AApps 的标题行）：返回 + 标题 + 操作钮；正文限宽居中，左右留白由正文自己留。
class MeSubPage extends StatelessWidget {
  const MeSubPage({super.key, required this.title, this.actions = const [], required this.body});

  /// 正文是一列卡片的二级页：整页可滚，卡片间距 12。
  MeSubPage.list({super.key, required this.title, this.actions = const [], required List<Widget> children})
    : body = Builder(
        builder: (context) => ListView.separated(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => children[i],
        ),
      );

  final String title;
  final List<Widget> actions;
  final Widget body;

  static const maxWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Scaffold(
      backgroundColor: mm.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  child: Row(
                    children: [
                      RoundGlassButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        tooltip: '返回',
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: MeowFont.title2,
                            fontWeight: FontWeight.w700,
                            fontFamilyFallback: meowRounded,
                            color: mm.t1,
                          ),
                        ),
                      ),
                      for (final a in actions) ...[const SizedBox(width: 8), a],
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 白卡分组：可选标题行（[accent] = 平台专属分组的粉色标题，[note] 是标题右侧的小字）+ 若干块，块之间 1px 分隔线。
class MeSection extends StatelessWidget {
  const MeSection({super.key, this.title, this.note, this.accent = false, required this.children});

  final String? title;
  final String? note;
  final bool accent;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final dense = MeDense.of(context);
    return Material(
      color: mm.elev,
      borderRadius: BorderRadius.circular(dense ? 20 : 24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 26),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
                  // 标题都很短，按自身宽度排；剩下的给右侧小字，放不下就省略
                  child: Row(
                    children: [
                      Text(
                        title!,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: MeowFont.caption,
                          fontWeight: FontWeight.w600,
                          color: accent ? mm.accent : mm.t2,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          note ?? '',
                          maxLines: 1,
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ...meDivided(context, children, leading: title != null),
          ],
        ),
      ),
    );
  }
}

/// 在相邻两项之间插 1px 分隔线（[leading] = 第一项上面也画）。紧凑行的线左右缩进到与文字对齐。
List<Widget> meDivided(BuildContext context, List<Widget> children, {bool leading = false}) {
  final dense = MeDense.of(context);
  final line = Container(
    height: 1,
    margin: dense ? const EdgeInsets.only(left: 14, right: 12) : EdgeInsets.zero,
    color: context.mm.line,
  );
  return [
    for (final (i, c) in children.indexed) ...[
      if (i > 0 || leading) line,
      c,
    ],
  ];
}

/// 一组设置行：行间 1px 分隔线；[footer] 是组末的小字说明（[onFooterTap] 可点）。
class MeRows extends StatelessWidget {
  const MeRows({super.key, required this.children, this.footer, this.onFooterTap});

  final List<Widget> children;
  final String? footer;
  final VoidCallback? onFooterTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...meDivided(context, children),
        if (footer != null)
          InkWell(
            onTap: onFooterTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 12, 8),
              child: Text(footer!, style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
            ),
          ),
      ],
    );
  }
}

/// 设置行：可选行首图标 + 标题（+ 副标题）+ 右侧的值 / 控件 / 箭头。
class MeRow extends StatelessWidget {
  const MeRow({
    super.key,
    required this.label,
    this.subtitle,
    this.subtitleColor,
    this.leading,
    this.value,
    this.mono = false,
    this.trailing,
    this.chevron = false,
    this.onTap,
  });

  final String label;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? leading;
  final String? value;
  final bool mono;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final dense = MeDense.of(context);
    final valueSize = dense ? MeowFont.caption : MeowFont.footnote;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: dense ? 36 : 52),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, dense ? 4 : 8, 12, dense ? 4 : 8),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: dense ? MeowFont.footnote : MeowFont.subheadline,
                      fontWeight: FontWeight.w500,
                      color: mm.t1,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense ? MeowFont.caption2 : MeowFont.caption,
                        color: subtitleColor ?? mm.t2,
                      ),
                    ),
                ],
              );
              return Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  // 有值的行：标题按自身宽度排（最多占行宽六成），值占剩下的、放不下就省略——
                  // 长选项（如测速地址）和放大字号都不会把标题挤成两行
                  if (value == null)
                    Expanded(child: title)
                  else ...[
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
                      child: title,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        value!,
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: mono
                            ? MeowFont.mono(size: valueSize, color: mm.t2)
                            : TextStyle(fontSize: valueSize, color: mm.t2),
                      ),
                    ),
                  ],
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
                      child: trailing,
                    ),
                  ],
                  if (chevron) ...[
                    const SizedBox(width: 4),
                    MeowIcon(MeowGlyph.chevron, size: dense ? 13 : 15, color: mm.t2),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 开关行：点整行切换；[onChanged] 为 null = 不可用。
class MeSwitchRow extends StatelessWidget {
  const MeSwitchRow({
    super.key,
    required this.label,
    this.subtitle,
    this.subtitleColor,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? subtitle;
  final Color? subtitleColor;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final sw = Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap);
    return MeRow(
      label: label,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      // 紧凑行里把开关缩到设计稿的 42×26
      trailing: MeDense.of(context) ? SizedBox(height: 26, child: FittedBox(child: sw)) : sw,
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

/// 选项行：点开一个带勾选的菜单。
class MePickerRow<T> extends StatelessWidget {
  const MePickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.values,
    required this.text,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T) text;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: '',
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final v in values) CheckedPopupMenuItem(value: v, checked: v == value, child: Text(text(v))),
      ],
      child: MeRow(label: label, value: text(value), chevron: true),
    );
  }
}

/// 胶囊钮：卡片底（[selected] = 墨色实底），用在主卡 / 页面底上。
class MePill extends StatelessWidget {
  const MePill({super.key, required this.label, required this.onTap, this.selected = false, this.height = 44});

  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final double height;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Material(
      color: selected ? mm.t1 : mm.elev,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // 只包住文字，不撑满父级给的宽高
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: MeowFont.footnote,
                  fontWeight: FontWeight.w600,
                  color: selected ? mm.bg : mm.t1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表型二级页（DNS 劫持 / 绕过 / 排除域名）里的一张条目卡：每条右侧一个删除钮；没有条目时显示 [empty]。
class MeItemsCard extends StatelessWidget {
  const MeItemsCard({
    super.key,
    this.title,
    required this.items,
    required this.onDelete,
    this.subtitles,
    this.empty = '暂无',
  });

  final String? title;
  final List<String> items;

  /// 与 [items] 等长的第二行文字（DNS 劫持的 IP）
  final List<String>? subtitles;
  final void Function(int index) onDelete;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return MeSection(
      title: title,
      children: [
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Text(empty, style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2)),
          ),
        for (final (i, item) in items.indexed)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 2, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t1),
                      ),
                      if (subtitles != null)
                        Text(
                          subtitles![i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MeowFont.mono(size: MeowFont.footnote, color: mm.t2),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: Icon(Icons.close_rounded, size: 18, color: mm.t2),
                  onPressed: () => onDelete(i),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 二级页里卡片下方的小字说明。
class MeCaption extends StatelessWidget {
  const MeCaption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: Text(text, style: TextStyle(fontSize: MeowFont.caption, color: context.mm.t2)),
  );
}

/// 单行输入对话框；取消返回 null。
Future<String?> mePrompt(
  BuildContext context,
  String title,
  String initial, {
  TextInputType? keyboard,
  bool obscure = false,
  String? helper,
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
      scrollable: true,
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: keyboard,
        obscureText: obscure,
        decoration: InputDecoration(helperText: helper),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(c.text), child: const Text('确定')),
      ],
    ),
  );
}
