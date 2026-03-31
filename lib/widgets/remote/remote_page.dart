import 'dart:async';

import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/remote/remote_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class RemotePage extends StatefulWidget {
  static const routeName = '/remote';

  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with FeedbackMixin {
  bool _busy = false;

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) {
    return AvesScaffold(
      appBar: AppBar(
        title: Text(_tr(context, 'Remote Media', '远程媒体')),
        actions: [
          IconButton(
            onPressed: _busy ? null : _showEditor,
            icon: const Icon(AIcons.add),
            tooltip: _tr(context, 'Add', '添加'),
          ),
        ],
      ),
      body: SafeArea(
        child: Selector<Settings, List<RemoteServer>>(
          selector: (context, s) => s.remoteServers,
          builder: (context, servers, child) {
            if (servers.isEmpty) {
              return EmptyContent(
                icon: AIcons.storageMain,
                text: _tr(context, 'No remote server yet, tap + to add one', '还没有远程连接，点击右上角添加'),
              );
            }
            return ListView.builder(
              itemCount: servers.length,
              itemBuilder: (context, index) {
                final server = servers[index];
                return ListTile(
                  leading: const Icon(AIcons.storageMain),
                  title: Text(server.name),
                  subtitle: Text(_subtitle(server)),
                  onTap: () {
                    Navigator.maybeOf(context)?.push(
                      MaterialPageRoute(
                        settings: const RouteSettings(name: RemoteBrowserPage.routeName),
                        builder: (_) => RemoteBrowserPage(server: server),
                      ),
                    );
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => _onServerAction(server, action),
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'edit', child: Text(_tr(context, 'Edit', '编辑'))),
                      PopupMenuItem(value: 'test', child: Text(_tr(context, 'Test Connection', '测试连接'))),
                      PopupMenuItem(value: 'delete', child: Text(_tr(context, 'Delete', '删除'))),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _subtitle(RemoteServer server) {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return 'WebDAV: ${server.webdavUrl ?? ''}';
      case RemoteProtocol.ftp:
        return 'FTP: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
      case RemoteProtocol.sftp:
        return 'SFTP: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
      case RemoteProtocol.smb:
        return 'SMB: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
    }
  }

  Future<void> _onServerAction(RemoteServer server, String action) async {
    switch (action) {
      case 'edit':
        await _showEditor(initial: server);
      case 'test':
        setState(() => _busy = true);
        final result = await remoteMediaService.testConnection(server);
        await remoteMediaLogService.log('remote_load', 'manual connection test', data: {'server': server.name, 'protocol': server.protocol.id, 'success': result.success});
        if (mounted) {
          final message = '${result.message}${result.latencyMillis != null ? ' (${result.latencyMillis}ms)' : ''}';
          showFeedback(context, result.success ? FeedbackType.info : FeedbackType.warn, message);
        }
        setState(() => _busy = false);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_tr(context, 'Delete remote server?', '删除远程连接？')),
            content: Text(_tr(context, 'This will remove the server and pinned folders.', '将移除此连接及其固定目录。')),
            actions: [
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(true), child: Text(MaterialLocalizations.of(context).okButtonLabel)),
            ],
          ),
        );
        if (ok == true) {
          settings.remoteServers = settings.remoteServers.where((v) => v.id != server.id).toList();
          settings.remotePinnedFolders = settings.remotePinnedFolders.where((v) => v.serverId != server.id).toList();
          await remoteMediaLogService.log('remote_load', 'deleted server', data: {'server': server.name});
        }
    }
  }

  Future<void> _showEditor({RemoteServer? initial}) async {
    final edited = await showDialog<RemoteServer>(
      context: context,
      builder: (context) => _RemoteServerEditorDialog(initial: initial),
    );
    if (edited == null) return;
    final all = settings.remoteServers;
    final idx = all.indexWhere((v) => v.id == edited.id);
    if (idx == -1) {
      settings.remoteServers = [...all, edited];
    } else {
      final next = [...all];
      next[idx] = edited;
      settings.remoteServers = next;
    }
    await remoteMediaLogService.log('remote_load', 'saved server', data: {'server': edited.name, 'protocol': edited.protocol.id});
  }
}

class _RemoteServerEditorDialog extends StatefulWidget {
  final RemoteServer? initial;

  const _RemoteServerEditorDialog({this.initial});

  @override
  State<_RemoteServerEditorDialog> createState() => _RemoteServerEditorDialogState();
}

class _RemoteServerEditorDialogState extends State<_RemoteServerEditorDialog> {
  final _nameController = TextEditingController();
  final _webdavUrlController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _basePathController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _smbDomainController = TextEditingController();
  final _sftpPrivateKeyController = TextEditingController();
  final _sftpPassphraseController = TextEditingController();
  final _sftpAdvancedController = TextEditingController();

  late RemoteProtocol _protocol;
  bool _ftpAnonymous = false;
  bool _ftpPassive = true;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _protocol = s?.protocol ?? RemoteProtocol.webdav;
    _nameController.text = s?.name ?? '';
    _webdavUrlController.text = s?.webdavUrl ?? '';
    _hostController.text = s?.host ?? '';
    _portController.text = s?.port?.toString() ?? '';
    _basePathController.text = s?.basePath ?? '';
    _usernameController.text = s?.username ?? '';
    _passwordController.text = s?.password ?? '';
    _ftpAnonymous = s?.ftpAnonymous ?? false;
    _ftpPassive = s?.ftpPassiveMode ?? true;
    _smbDomainController.text = s?.smbDomain ?? '';
    _sftpPrivateKeyController.text = s?.sftpPrivateKey ?? '';
    _sftpPassphraseController.text = s?.sftpPassphrase ?? '';
    _sftpAdvancedController.text = s?.sftpAdvancedJson ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _webdavUrlController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _basePathController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _smbDomainController.dispose();
    _sftpPrivateKeyController.dispose();
    _sftpPassphraseController.dispose();
    _sftpAdvancedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add Remote Server' : 'Edit Remote Server'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<RemoteProtocol>(
              initialValue: _protocol,
              decoration: const InputDecoration(labelText: 'Protocol'),
              items: RemoteProtocol.values
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text(v.name.toUpperCase()),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _protocol = v);
              },
            ),
            const SizedBox(height: 8),
            if (_protocol == RemoteProtocol.webdav) ...[
              TextField(
                controller: _webdavUrlController,
                decoration: const InputDecoration(labelText: 'WebDAV URL'),
              ),
              const SizedBox(height: 8),
            ] else ...[
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _portController,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _basePathController,
              decoration: const InputDecoration(labelText: 'Base path'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            if (_protocol == RemoteProtocol.ftp) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Anonymous login'),
                value: _ftpAnonymous,
                onChanged: (v) => setState(() => _ftpAnonymous = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Passive mode'),
                value: _ftpPassive,
                onChanged: (v) => setState(() => _ftpPassive = v),
              ),
            ],
            if (_protocol == RemoteProtocol.smb) ...[
              TextField(
                controller: _smbDomainController,
                decoration: const InputDecoration(labelText: 'SMB domain'),
              ),
            ],
            if (_protocol == RemoteProtocol.sftp) ...[
              TextField(
                controller: _sftpPrivateKeyController,
                decoration: const InputDecoration(labelText: 'SFTP private key'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sftpPassphraseController,
                decoration: const InputDecoration(labelText: 'SFTP passphrase'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sftpAdvancedController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'SFTP advanced config (JSON)'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(), child: Text(l10n.cancelButtonLabel)),
        TextButton(onPressed: _submit, child: Text(l10n.okButtonLabel)),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final webdavUrl = _webdavUrlController.text.trim();
    final host = _hostController.text.trim();
    final parsedPort = int.tryParse(_portController.text.trim());
    final server = RemoteServer(
      id: widget.initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      protocol: _protocol,
      webdavUrl: webdavUrl.isNotEmpty ? webdavUrl : null,
      host: host.isNotEmpty ? host : null,
      port: _protocol == RemoteProtocol.webdav ? null : parsedPort,
      basePath: _basePathController.text.trim().isNotEmpty ? _basePathController.text.trim() : null,
      username: _usernameController.text.trim().isNotEmpty ? _usernameController.text.trim() : null,
      password: _passwordController.text.trim().isNotEmpty ? _passwordController.text.trim() : null,
      ftpAnonymous: _ftpAnonymous,
      ftpPassiveMode: _ftpPassive,
      smbDomain: _smbDomainController.text.trim().isNotEmpty ? _smbDomainController.text.trim() : null,
      sftpPrivateKey: _sftpPrivateKeyController.text.trim().isNotEmpty ? _sftpPrivateKeyController.text.trim() : null,
      sftpPassphrase: _sftpPassphraseController.text.trim().isNotEmpty ? _sftpPassphraseController.text.trim() : null,
      sftpAdvancedJson: _sftpAdvancedController.text.trim().isNotEmpty ? _sftpAdvancedController.text.trim() : null,
    );
    Navigator.maybeOf(context)?.pop(server);
  }
}
