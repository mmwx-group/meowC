import 'dart:typed_data';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/dav_client.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';
import 'app_dialogs.dart';

/// 备份与恢复（原 Bettbox「工具 › 备份与恢复」）：WebDAV 远程备份 / 恢复、本地文件导出 / 导入、恢复策略。
/// 读写与原页面相同：WebDAV 账号在 [appDAVSettingProvider]，恢复策略在 [appSettingProvider]，
/// 备份 / 恢复本身走 `globalState.appController` 的同一组方法。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

const _strategyLabels = {RecoveryStrategy.compatible: '兼容', RecoveryStrategy.override: '覆盖'};

class _BackupPageState extends ConsumerState<BackupPage> {
  // 原页面每次 build 都新建一个客户端（每次都重新测一遍连通性）；这里只在 WebDAV 设置变了时重建
  DAV? _clientDav;
  DAVClient? _client;

  DAVClient? _clientFor(DAV? dav) {
    if (dav == null) return _client = _clientDav = null;
    if (_client == null || _clientDav != dav) {
      _clientDav = dav;
      _client = DAVClient(dav);
    }
    return _client;
  }

  void _showSuccess(String title, String text) {
    globalState.showMessage(title: title, message: TextSpan(text: text), cancelable: false);
  }

  Future<void> _editWebDAV(DAV? dav) => showDialog<void>(
    context: context,
    builder: (_) => _WebDAVDialog(dav: dav?.copyWith()),
  );

  /// 恢复前先选恢复范围（只恢复配置文件 / 全部数据）；取消返回 null。
  Future<RecoveryOption?> _pickRecoveryOption() => showDialog<RecoveryOption>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('恢复'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(RecoveryOption.onlyProfiles),
          child: const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('仅恢复配置文件')),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(RecoveryOption.all),
          child: const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('恢复所有数据')),
        ),
      ],
    ),
  );

  Future<void> _backupOnWebDAV(DAVClient client) async {
    final res = await globalState.appController.safeRun<bool>(
      () async {
        final backupData = await globalState.appController.backupData();
        return await client.backup(Uint8List.fromList(backupData));
      },
      needLoading: true,
      title: '备份',
    );
    if (res != true) return;
    _showSuccess('备份', '备份成功');
  }

  Future<void> _recoveryOnWebDAV(DAVClient client) async {
    final option = await _pickRecoveryOption();
    if (option == null || !mounted) return;
    final res = await globalState.appController.safeRun<bool>(
      () async {
        final data = await client.recovery();
        await globalState.appController.recoveryData(data, option);
        return true;
      },
      needLoading: true,
      title: '恢复',
    );
    if (res != true) return;
    _showSuccess('恢复', '恢复成功');
  }

  Future<void> _backupOnLocal() async {
    final res = await globalState.appController.safeRun<bool>(() async {
      final backupData = await globalState.appController.backupData();
      final value = await picker.saveFile(utils.getBackupFileName(), Uint8List.fromList(backupData));
      if (value == null) return false;
      return true;
    }, title: '备份');
    if (res != true) return;
    _showSuccess('备份', '备份成功');
  }

  Future<void> _recoveryOnLocal() async {
    final option = await _pickRecoveryOption();
    if (option == null || !mounted) return;
    final file = await picker.pickerFile(withData: false);
    final path = file?.path;
    final res = await globalState.appController.safeRun<bool>(
      () async {
        if (path != null) {
          await globalState.appController.recoveryDataFromFile(path, option);
        } else if (file?.bytes != null) {
          await globalState.appController.recoveryData(List<int>.from(file!.bytes!), option);
        } else {
          return false;
        }
        return true;
      },
      needLoading: true,
      title: '恢复',
    );
    if (res != true) return;
    _showSuccess('恢复', '恢复成功');
  }

  Future<void> _editFileName(DAV dav) async {
    final value = await advPrompt(context, title: '文件', initial: dav.fileName, resetValue: defaultDavFileName);
    if (value == null) return;
    ref.read(appDAVSettingProvider.notifier).updateState((state) => state?.copyWith(fileName: value));
  }

  @override
  Widget build(BuildContext context) {
    final dav = ref.watch(appDAVSettingProvider);
    final client = _clientFor(dav);
    final strategy = ref.watch(appSettingProvider.select((s) => s.recoveryStrategy));
    return MeSubPage.list(
      title: '备份与恢复',
      children: [
        MeSection(
          title: 'WebDAV',
          children: [
            if (dav == null || client == null)
              MeRow(
                label: '暂无信息',
                subtitle: '请绑定 WebDAV',
                trailing: FilledButton.tonal(onPressed: () => _editWebDAV(dav), child: const Text('绑定')),
              )
            else ...[
              _AccountRow(dav: dav, client: client, onEdit: () => _editWebDAV(dav)),
              MeRow(label: '文件', value: dav.fileName, mono: true, chevron: true, onTap: () => _editFileName(dav)),
              MeRow(label: '备份', subtitle: '备份数据到 WebDAV', chevron: true, onTap: () => _backupOnWebDAV(client)),
              MeRow(label: '恢复', subtitle: '通过 WebDAV 恢复数据', chevron: true, onTap: () => _recoveryOnWebDAV(client)),
            ],
          ],
        ),
        MeSection(
          title: '本地',
          children: [
            MeRow(label: '备份', subtitle: '备份数据到本地', chevron: true, onTap: _backupOnLocal),
            MeRow(label: '恢复', subtitle: '通过文件恢复数据', chevron: true, onTap: _recoveryOnLocal),
          ],
        ),
        MeSection(
          title: '选项',
          children: [
            MePickerRow<RecoveryStrategy>(
              label: '恢复策略',
              value: strategy,
              values: RecoveryStrategy.values,
              text: (v) => _strategyLabels[v]!,
              onChanged: (v) =>
                  ref.read(appSettingProvider.notifier).updateState((state) => state.copyWith(recoveryStrategy: v)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 已绑定的 WebDAV 账号：用户名 + 连通性（检测中 / 正常 / 连不上），行尾「编辑」。
class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.dav, required this.client, required this.onEdit});

  final DAV dav;
  final DAVClient client;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return FutureBuilder<bool>(
      future: client.pingCompleter.future,
      builder: (_, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final ok = snapshot.data == true;
        return MeRow(
          label: dav.user,
          subtitle: !done ? '连通性：检测中…' : (ok ? '连通性：正常' : '连通性：连不上'),
          subtitleColor: !done ? null : (ok ? mm.good : mm.down),
          trailing: FilledButton.tonal(onPressed: onEdit, child: const Text('编辑')),
        );
      },
    );
  }
}

/// WebDAV 配置：地址 / 账号 / 密码，保存时写 [appDAVSettingProvider]；已绑定时多一个「删除」（清空绑定）。
class _WebDAVDialog extends ConsumerStatefulWidget {
  const _WebDAVDialog({this.dav});

  final DAV? dav;

  @override
  ConsumerState<_WebDAVDialog> createState() => _WebDAVDialogState();
}

class _WebDAVDialogState extends ConsumerState<_WebDAVDialog> {
  late final _uri = TextEditingController(text: widget.dav?.uri);
  late final _user = TextEditingController(text: widget.dav?.user);
  late final _password = TextEditingController(text: widget.dav?.password);
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void dispose() {
    _uri.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(appDAVSettingProvider.notifier).value = DAV(
      uri: _uri.text,
      user: _user.text,
      password: _password.text,
    );
    Navigator.pop(context);
  }

  void _delete() {
    ref.read(appDAVSettingProvider.notifier).value = null;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('WebDAV 配置'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _uri,
              maxLines: 5,
              minLines: 1,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.link_rounded),
                labelText: '地址',
                helperText: 'WebDAV 服务器地址',
              ),
              validator: (v) => v == null || v.isEmpty || !v.isHttpUrl ? '请输入有效的 WebDAV 地址' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.account_circle_outlined), labelText: '账号'),
              validator: (v) => v == null || v.isEmpty ? '账号不能为空' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.password_rounded),
                labelText: '密码',
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => v == null || v.isEmpty ? '密码不能为空' : null,
            ),
          ],
        ),
      ),
      actions: [
        if (widget.dav != null) TextButton(onPressed: _delete, child: const Text('删除')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
