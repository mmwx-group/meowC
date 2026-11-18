import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/common.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/m3.dart';
import '../../me/me_kit.dart';
import 'app_dialogs.dart';

/// 开发者（原 Bettbox「工具 › 开发者模式」，`DeveloperView`）：开发者模式开关 + 三个调试操作。
class DeveloperPage extends ConsumerWidget {
  const DeveloperPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enable = ref.watch(appSettingProvider.select((s) => s.developerMode));
    return MeSubPage.list(
      title: '开发者',
      children: [
        MeSection(
          children: [
            MeSwitchRow(
              label: '开发者模式',
              value: enable,
              onChanged: (v) => ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(developerMode: v)),
            ),
          ],
        ),
        MeSection(
          title: '选项',
          children: [
            MeRow(label: '消息测试', chevron: true, onTap: () => context.showNotifier('这是一条消息。')),
            MeRow(
              label: '日志测试',
              subtitle: '写入 100 条随机长度的应用日志',
              chevron: true,
              onTap: () {
                for (var i = 0; i < 100; i++) {
                  globalState.appController.addLog(
                    Log.app('[$i]${utils.generateRandomString(maxLength: 200, minLength: 20)}'),
                  );
                }
              },
            ),
            MeRow(
              label: '清除数据',
              subtitle: '重置应用程序',
              subtitleColor: context.cs.error,
              chevron: true,
              onTap: () async {
                final ok = await advConfirm(
                  context,
                  title: '危险操作',
                  message: '此操作将会重置应用程序，请注意备份，确定要继续吗？',
                );
                if (!ok) return;
                await globalState.appController.handleClear();
              },
            ),
          ],
        ),
      ],
    );
  }
}
