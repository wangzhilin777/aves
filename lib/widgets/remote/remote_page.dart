import 'dart:async';
import 'dart:convert';

import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/utils/file_utils.dart';
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
  final Map<String, int> _cacheBytesByServer = {};
  final Map<String, int> _cacheBytesByPinnedFolder = {};
  final Set<String> _loadingCacheBytes = {};
  final Set<String> _loadingPinnedFolderCacheBytes = {};

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  void initState() {
    super.initState();
    unawaited(remoteMediaService.syncCacheMediaScanPolicy());
    unawaited(_refreshAllCacheBytes());
  }

  @override
  Widget build(BuildContext context) {
    return AvesScaffold(
      appBar: AppBar(
        title: Text(_tr(context, 'Remote Media Manager', '远程媒体管理')),
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
                _ensureCacheBytes(server.id);
                final bytes = _cacheBytesByServer[server.id] ?? 0;
                final cacheText = formatFileSize(context.locale, bytes, round: 1);
                final pinnedFolders = settings.remotePinnedFolders.where((v) => v.serverId == server.id).toList()..sort((a, b) => a.path.compareTo(b.path));
                return ExpansionTile(
                  leading: const Icon(AIcons.storageMain),
                  title: Text(server.name),
                  subtitle: Text('${_subtitle(context, server)}\n${_tr(context, 'Cache', '缓存')}: $cacheText'),
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  children: [
                    ListTile(
                      leading: const Icon(AIcons.folder),
                      title: Text(_tr(context, 'Browse / Manage', '浏览与管理')),
                      onTap: () {
                        Navigator.maybeOf(context)?.push(
                          MaterialPageRoute(
                            settings: const RouteSettings(name: RemoteBrowserPage.routeName),
                            builder: (_) => RemoteBrowserPage(server: server),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(AIcons.pin),
                      title: Text(_tr(context, 'Select folder for albums', '选择文件夹加入相册')),
                      onTap: () => _onServerAction(server, 'select_folder'),
                    ),
                    ListTile(
                      leading: const Icon(AIcons.image),
                      title: Text(_tr(context, 'Remote album list (${0})', '远程相册列表（${0}）').replaceFirst('{0}', '${pinnedFolders.length}')),
                      subtitle: Text(_tr(context, 'Connection -> Folder -> Actions', '连接 -> 目录 -> 操作')),
                    ),
                    if (pinnedFolders.isEmpty)
                      ListTile(
                        dense: true,
                        leading: const SizedBox(width: 20),
                        title: Text(_tr(context, 'No pinned folder', '暂无已加入目录')),
                      ),
                    ...pinnedFolders.map((folder) => _buildPinnedFolderTile(server, folder)),
                    ListTile(
                      leading: const Icon(AIcons.more),
                      title: Text(_tr(context, 'More connection actions', '连接更多操作')),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) => _onServerAction(server, action),
                        itemBuilder: (context) => [
                          PopupMenuItem(value: 'edit', child: Text(_tr(context, 'Edit', '编辑'))),
                          PopupMenuItem(value: 'test', child: Text(_tr(context, 'Test Connection', '测试连接'))),
                          PopupMenuItem(value: 'clear_cache', child: Text(_tr(context, 'Clear Cache', '清理缓存'))),
                          PopupMenuItem(value: 'delete', child: Text(_tr(context, 'Delete', '删除'))),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _subtitle(BuildContext context, RemoteServer server) {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return '${_tr(context, 'WebDAV address', 'WebDAV 地址')}: ${server.webdavUrl ?? ''}';
      case RemoteProtocol.ftp:
        return '${_tr(context, 'FTP host', 'FTP 主机')}: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
      case RemoteProtocol.sftp:
        return '${_tr(context, 'SFTP host', 'SFTP 主机')}: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
      case RemoteProtocol.smb:
        return '${_tr(context, 'SMB host', 'SMB 主机')}: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
    }
  }

  Future<void> _onServerAction(RemoteServer server, String action) async {
    switch (action) {
      case 'edit':
        await _showEditor(initial: server);
      case 'select_folder':
        await Navigator.maybeOf(context)?.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: RemoteBrowserPage.routeName),
            builder: (_) => RemoteBrowserPage(server: server, albumSelectionMode: true),
          ),
        );
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
          await remoteMediaService.clearConnectionCache(server.id);
          settings.remoteServers = settings.remoteServers.where((v) => v.id != server.id).toList();
          settings.remotePinnedFolders = settings.remotePinnedFolders.where((v) => v.serverId != server.id).toList();
          _cacheBytesByServer.remove(server.id);
          _cacheBytesByPinnedFolder.removeWhere((k, _) => k.startsWith('${server.id}|'));
          await remoteMediaLogService.log('remote_load', 'deleted server', data: {'server': server.name});
          if (mounted) {
            setState(() {});
          }
        }
      case 'clear_cache':
        final bytes = await remoteMediaService.getConnectionCacheBytes(server.id);
        final hint = formatFileSize(context.locale, bytes, round: 1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_tr(context, 'Clear remote cache?', '清理远程缓存？')),
            content: Text(_tr(context, 'Current cache size: $hint', '当前缓存大小：$hint')),
            actions: [
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(true), child: Text(MaterialLocalizations.of(context).okButtonLabel)),
            ],
          ),
        );
        if (ok == true) {
          final cleared = await remoteMediaService.clearConnectionCache(server.id);
          if (cleared) {
            _cacheBytesByServer[server.id] = 0;
            _setPinnedFolderCacheBytesForServer(server.id, 0);
          }
          if (mounted) {
            showFeedback(
              context,
              cleared ? FeedbackType.info : FeedbackType.warn,
              cleared ? _tr(context, 'Cache cleared', '缓存已清理') : _tr(context, 'Failed to clear cache', '清理缓存失败'),
            );
            setState(() {});
          }
        }
    }
  }

  Future<void> _refreshAllCacheBytes() async {
    for (final server in settings.remoteServers) {
      _ensureCacheBytes(server.id, force: true);
    }
  }

  Widget _buildPinnedFolderTile(RemoteServer server, RemotePinnedFolder folder) {
    final key = '${server.id}|${folder.path}';
    final cacheBytes = _cacheBytesByPinnedFolder[key];
    final cacheText = cacheBytes == null ? _tr(context, 'Tap refresh to check cache size', '点击刷新后再检查缓存大小') : formatFileSize(context.locale, cacheBytes, round: 1);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 20),
      child: ListTile(
        dense: true,
        leading: const Icon(AIcons.folder),
        title: Text(_leafName(folder.path)),
        subtitle: Text('${folder.path}\n${_tr(context, 'Cache', '缓存')}: $cacheText'),
        isThreeLine: true,
        onTap: () => _onPinnedFolderAction(server, folder, 'open'),
        onLongPress: () => _showPinnedFolderActionSheet(server, folder),
        trailing: PopupMenuButton<String>(
          onSelected: (action) => _onPinnedFolderAction(server, folder, action),
          itemBuilder: (context) => [
            PopupMenuItem(value: 'open', child: Text(_tr(context, 'Open folder', '打开目录'))),
            PopupMenuItem(value: 'refresh_cache', child: Text(_tr(context, 'Refresh cache size', '刷新缓存大小'))),
            PopupMenuItem(value: 'clear_cache', child: Text(_tr(context, 'Clear folder cache', '清理目录缓存'))),
            PopupMenuItem(value: 'remove', child: Text(_tr(context, 'Remove from albums', '从相册移除'))),
          ],
        ),
      ),
    );
  }

  Future<void> _showPinnedFolderActionSheet(RemoteServer server, RemotePinnedFolder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(AIcons.folder),
              title: Text(_tr(context, 'Open folder', '打开目录')),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('open'),
            ),
            ListTile(
              leading: const Icon(AIcons.refresh),
              title: Text(_tr(context, 'Refresh cache size', '刷新缓存大小')),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('refresh_cache'),
            ),
            ListTile(
              leading: const Icon(AIcons.clear),
              title: Text(_tr(context, 'Clear folder cache', '清理目录缓存')),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('clear_cache'),
            ),
            ListTile(
              leading: const Icon(AIcons.unpin),
              title: Text(_tr(context, 'Remove from albums', '从相册移除')),
              subtitle: Text(_tr(context, 'Auto clear folder cache', '自动清理目录缓存')),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    await _onPinnedFolderAction(server, folder, action);
  }

  Future<void> _onPinnedFolderAction(RemoteServer server, RemotePinnedFolder folder, String action) async {
    switch (action) {
      case 'open':
        await Navigator.maybeOf(context)?.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: RemoteBrowserPage.routeName),
            builder: (_) => RemoteBrowserPage(
              server: server,
              initialPath: folder.path,
              albumSelectionMode: true,
            ),
          ),
        );
      case 'refresh_cache':
        await _refreshPinnedFolderCacheBytes(server: server, folderPath: folder.path, force: true);
        if (mounted) setState(() {});
      case 'clear_cache':
        final cleared = await remoteMediaService.clearPinnedFolderCache(server: server, folderPath: folder.path);
        if (cleared) {
          _cacheBytesByPinnedFolder['${server.id}|${folder.path}'] = 0;
          _ensureCacheBytes(server.id, force: true);
        }
        if (mounted) {
          showFeedback(
            context,
            cleared ? FeedbackType.info : FeedbackType.warn,
            cleared ? _tr(context, 'Folder cache cleared', '目录缓存已清理') : _tr(context, 'Failed to clear folder cache', '目录缓存清理失败'),
          );
          setState(() {});
        }
      case 'remove':
        final cleared = await remoteMediaService.clearPinnedFolderCache(server: server, folderPath: folder.path);
        settings.remotePinnedFolders = settings.remotePinnedFolders.where((v) => !(v.serverId == server.id && v.path == folder.path)).toList();
        _cacheBytesByPinnedFolder.remove('${server.id}|${folder.path}');
        _ensureCacheBytes(server.id, force: true);
        if (mounted) {
          showFeedback(
            context,
            FeedbackType.info,
            cleared ? _tr(context, 'Removed and cache cleared', '已移除并清理缓存') : _tr(context, 'Removed from albums', '已从相册移除'),
          );
          setState(() {});
        }
    }
  }

  Future<void> _refreshPinnedFolderCacheBytes({
    required RemoteServer server,
    required String folderPath,
    bool force = false,
  }) async {
    final key = '${server.id}|$folderPath';
    if (!force && _cacheBytesByPinnedFolder.containsKey(key)) return;
    if (_loadingPinnedFolderCacheBytes.contains(key)) return;
    _loadingPinnedFolderCacheBytes.add(key);
    try {
      final bytes = await remoteMediaService.getPinnedFolderCacheBytes(
        server: server,
        folderPath: folderPath,
      );
      if (!mounted) return;
      _cacheBytesByPinnedFolder[key] = bytes;
    } finally {
      _loadingPinnedFolderCacheBytes.remove(key);
    }
  }

  String _leafName(String path) {
    final parts = path.split('/').where((v) => v.isNotEmpty).toList();
    return parts.isEmpty ? '/' : parts.last;
  }

  void _setPinnedFolderCacheBytesForServer(String serverId, int bytes) {
    final prefix = '$serverId|';
    final keys = _cacheBytesByPinnedFolder.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      _cacheBytesByPinnedFolder[key] = bytes;
    }
  }

  void _ensureCacheBytes(String serverId, {bool force = false}) {
    if (!force && _cacheBytesByServer.containsKey(serverId)) return;
    if (_loadingCacheBytes.contains(serverId)) return;
    _loadingCacheBytes.add(serverId);
    unawaited(() async {
      try {
        final bytes = await remoteMediaService.getConnectionCacheBytes(serverId);
        if (!mounted) return;
        setState(() => _cacheBytesByServer[serverId] = bytes);
      } finally {
        _loadingCacheBytes.remove(serverId);
      }
    }());
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
  String? _validationError;

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

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
      title: Text(widget.initial == null ? _tr(context, 'Add Remote Server', '新增远程连接') : _tr(context, 'Edit Remote Server', '编辑远程连接')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_validationError != null) ...[
              Text(
                _validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _nameController,
              decoration: InputDecoration(labelText: _tr(context, 'Display name', '显示名称')),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<RemoteProtocol>(
              initialValue: _protocol,
              decoration: InputDecoration(labelText: _tr(context, 'Protocol', '协议')),
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
                decoration: InputDecoration(labelText: _tr(context, 'WebDAV URL', 'WebDAV 地址')),
              ),
              const SizedBox(height: 8),
            ] else ...[
              TextField(
                controller: _hostController,
                decoration: InputDecoration(labelText: _tr(context, 'Host', '主机')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _portController,
                decoration: InputDecoration(labelText: _tr(context, 'Port', '端口')),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _basePathController,
              decoration: InputDecoration(labelText: _tr(context, 'Base path', '基础路径')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(labelText: _tr(context, 'Username', '用户名')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(labelText: _tr(context, 'Password', '密码')),
            ),
            if (_protocol == RemoteProtocol.ftp) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_tr(context, 'Anonymous login', '匿名登录')),
                value: _ftpAnonymous,
                onChanged: (v) => setState(() => _ftpAnonymous = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_tr(context, 'Passive mode', '被动模式')),
                value: _ftpPassive,
                onChanged: (v) => setState(() => _ftpPassive = v),
              ),
            ],
            if (_protocol == RemoteProtocol.smb) ...[
              TextField(
                controller: _smbDomainController,
                decoration: InputDecoration(labelText: _tr(context, 'SMB domain', 'SMB 域')),
              ),
            ],
            if (_protocol == RemoteProtocol.sftp) ...[
              TextField(
                controller: _sftpPrivateKeyController,
                decoration: InputDecoration(labelText: _tr(context, 'SFTP private key', 'SFTP 私钥')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sftpPassphraseController,
                decoration: InputDecoration(labelText: _tr(context, 'SFTP passphrase', 'SFTP 私钥口令')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sftpAdvancedController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: _tr(context, 'SFTP advanced config (JSON)', 'SFTP 高级配置（JSON）')),
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
    final webdavUrl = _webdavUrlController.text.trim();
    final host = _hostController.text.trim();
    final parsedPort = int.tryParse(_portController.text.trim());

    if (name.isEmpty) {
      setState(() => _validationError = _tr(context, 'Display name is required', '显示名称不能为空'));
      return;
    }
    if (_protocol == RemoteProtocol.webdav) {
      final uri = Uri.tryParse(webdavUrl);
      final validScheme = uri != null && {'http', 'https'}.contains(uri.scheme.toLowerCase());
      if (webdavUrl.isEmpty || uri == null || !validScheme || uri.host.isEmpty) {
        setState(() => _validationError = _tr(context, 'Please enter a valid WebDAV URL', '请输入有效的 WebDAV 地址'));
        return;
      }
    } else {
      if (host.isEmpty) {
        setState(() => _validationError = _tr(context, 'Host is required', '主机不能为空'));
        return;
      }
      if (_portController.text.trim().isNotEmpty && (parsedPort == null || parsedPort < 1 || parsedPort > 65535)) {
        setState(() => _validationError = _tr(context, 'Port must be between 1 and 65535', '端口必须在 1 到 65535 之间'));
        return;
      }
    }
    if (_protocol == RemoteProtocol.sftp && _usernameController.text.trim().isEmpty) {
      setState(() => _validationError = _tr(context, 'SFTP username is required', 'SFTP 用户名不能为空'));
      return;
    }
    final sftpAdvancedText = _sftpAdvancedController.text.trim();
    if (_protocol == RemoteProtocol.sftp && sftpAdvancedText.isNotEmpty) {
      try {
        jsonDecode(sftpAdvancedText);
      } catch (_) {
        setState(() => _validationError = _tr(context, 'SFTP advanced config must be valid JSON', 'SFTP 高级配置必须是有效 JSON'));
        return;
      }
    }

    setState(() => _validationError = null);

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
      sftpAdvancedJson: sftpAdvancedText.isNotEmpty ? sftpAdvancedText : null,
    );
    Navigator.maybeOf(context)?.pop(server);
  }
}
