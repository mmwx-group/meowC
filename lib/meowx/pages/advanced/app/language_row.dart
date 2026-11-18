import 'package:bett_box/common/common.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/providers/config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../me/me_kit.dart';

/// 语言（原 Bettbox「工具」页的 `_LocaleItem`）：选项顺序与名字照原样，写 [appSettingProvider] 的 `locale`。
/// 没设过时显示系统语言。
class LanguageRow extends ConsumerWidget {
  const LanguageRow({super.key});

  static final List<Locale> _options = _ordered();

  static const _nativeNames = {
    'zh_CN': '简体中文',
    'zh_TC': '繁體中文',
    'en': 'English',
    'ru': 'Русский',
    'fa': 'فارسی',
    'ja': '日本語',
    'ko': '한국어',
  };

  static List<Locale> _ordered() {
    const priority = ['zh_CN', 'zh_TC', 'en', 'ru', 'fa', 'ja', 'ko'];
    final locales = List<Locale>.from(AppLocalizations.delegate.supportedLocales);
    locales.sort((a, b) {
      final aKey = a.toString(), bKey = b.toString();
      final aIndex = priority.indexOf(aKey), bIndex = priority.indexOf(bKey);
      if (aIndex != -1 && bIndex != -1) return aIndex.compareTo(bIndex);
      if (aIndex != -1) return -1;
      if (bIndex != -1) return 1;
      return aKey.compareTo(bKey);
    });
    return locales;
  }

  static String _name(Locale locale) => _nativeNames[locale.toString()] ?? locale.toString();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(appSettingProvider.select((s) => s.locale));
    final current = utils.getLocaleForString(locale) ?? utils.getSystemLocale();
    return MePickerRow<Locale>(
      label: '语言',
      value: current,
      values: _options,
      text: _name,
      onChanged: (v) =>
          ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(locale: v.toString())),
    );
  }
}
