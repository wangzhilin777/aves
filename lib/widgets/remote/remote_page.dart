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
        title: Text(context.l10n.remoteManagerPageTitle),
        actions: [
          IconButton(
            onPressed: _busy ? null : _showEditor,
            icon: const Icon(AIcons.add),
            tooltip: context.l10n.remoteAddTooltip,
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
                text: context.l10n.remoteEmptyMessage,
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
                  subtitle: Text('${_subtitle(context, server)}\n${context.l10n.remoteCacheLabel}: $cacheText'),
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  children: [
                    ListTile(
                      leading: const Icon(AIcons.folder),
                      title: Text(context.l10n.remoteBrowseManage),
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
                      title: Text(context.l10n.remoteSelectFolderForAlbums),
                      onTap: () => _onServerAction(server, 'select_folder'),
                    ),
                    ListTile(
                      leading: const Icon(AIcons.image),
                      title: Text(context.l10n.remoteAlbumListTitle(pinnedFolders.length)),
                      subtitle: Text(context.l10n.remoteConnectionFolderActions),
                    ),
                    if (pinnedFolders.isEmpty)
                      ListTile(
                        dense: true,
                        leading: const SizedBox(width: 20),
                        title: Text(context.l10n.remoteNoPinnedFolder),
                      ),
                    ...pinnedFolders.map((folder) => _buildPinnedFolderTile(server, folder)),
                    ListTile(
                      leading: const Icon(AIcons.more),
                      title: Text(context.l10n.remoteMoreConnectionActions),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) => _onServerAction(server, action),
                        itemBuilder: (context) => [
                          PopupMenuItem(value: 'edit', child: Text(context.l10n.remoteEditAction)),
                          PopupMenuItem(value: 'test', child: Text(context.l10n.remoteTestConnection)),
                          PopupMenuItem(value: 'clear_metadata', child: Text(context.l10n.remoteActionClearMetadata)),
                          PopupMenuItem(value: 'clear_cache', child: Text(context.l10n.remoteActionClearCache)),
                          PopupMenuItem(value: 'clear_all_cache', child: Text(context.l10n.remoteActionClearMetadataAndCache)),
                          PopupMenuItem(value: 'delete', child: Text(context.l10n.remoteDeleteAction)),
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
        return '${context.l10n.remoteWebdavAddress}: ${server.webdavUrl ?? ''}';
      case RemoteProtocol.ftp:
        return '${context.l10n.remoteFtpHost}: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
      case RemoteProtocol.sftp:
        return '${context.l10n.remoteSftpHost}: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
      case RemoteProtocol.smb:
        return '${context.l10n.remoteSmbHost}: ${server.host ?? ''}${server.port != null ? ':${server.port}' : ''}';
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
            title: Text(context.l10n.remoteDeleteServerTitle),
            content: Text(context.l10n.remoteDeleteServerMessage),
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
      case 'clear_metadata':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.remoteDialogClearMetadataTitle),
            content: Text(context.l10n.remoteDialogClearMetadataMessage),
            actions: [
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(true), child: Text(MaterialLocalizations.of(context).okButtonLabel)),
            ],
          ),
        );
        if (ok == true) {
          final deleted = await remoteMediaService.clearConnectionMetadata(server.id);
          if (mounted) {
            showFeedback(
              context,
              FeedbackType.info,
              deleted > 0 ? context.l10n.remoteFeedbackMetadataCleared : context.l10n.remoteFeedbackNoMetadataToClear,
            );
            setState(() {});
          }
        }
      case 'clear_all_cache':
        final bytes = await remoteMediaService.getConnectionCacheBytes(server.id);
        final hint = formatFileSize(context.locale, bytes, round: 1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.remoteDialogClearMetadataAndCacheTitle),
            content: Text(context.l10n.remoteCurrentCacheSize(hint)),
            actions: [
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
              TextButton(onPressed: () => Navigator.maybeOf(context)?.pop(true), child: Text(MaterialLocalizations.of(context).okButtonLabel)),
            ],
          ),
        );
        if (ok == true) {
          final cleared = await remoteMediaService.clearConnectionAllCache(server.id);
          if (cleared) {
            _cacheBytesByServer[server.id] = 0;
            _setPinnedFolderCacheBytesForServer(server.id, 0);
          }
          if (mounted) {
            showFeedback(
              context,
              cleared ? FeedbackType.info : FeedbackType.warn,
              cleared ? context.l10n.remoteFeedbackMetadataAndCacheCleared : context.l10n.remoteFeedbackFailedClearMetadataAndCache,
            );
            setState(() {});
          }
        }
      case 'clear_cache':
        final bytes = await remoteMediaService.getConnectionCacheBytes(server.id);
        final hint = formatFileSize(context.locale, bytes, round: 1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.remoteDialogClearCacheTitle),
            content: Text(context.l10n.remoteCurrentCacheSize(hint)),
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
              cleared ? context.l10n.remoteFeedbackCacheCleared : context.l10n.remoteFeedbackFailedClearCache,
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
    final cacheText = cacheBytes == null ? context.l10n.remoteTapRefreshForCacheSize : formatFileSize(context.locale, cacheBytes, round: 1);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 20),
      child: ListTile(
        dense: true,
        leading: const Icon(AIcons.folder),
        title: Text(_leafName(folder.path)),
        subtitle: Text('${folder.path}\n${context.l10n.remoteCacheLabel}: $cacheText'),
        isThreeLine: true,
        onTap: () => _onPinnedFolderAction(server, folder, 'open'),
        onLongPress: () => _showPinnedFolderActionSheet(server, folder),
        trailing: PopupMenuButton<String>(
          onSelected: (action) => _onPinnedFolderAction(server, folder, action),
          itemBuilder: (context) => [
            PopupMenuItem(value: 'open', child: Text(context.l10n.remoteOpenFolder)),
            PopupMenuItem(value: 'refresh_cache', child: Text(context.l10n.remoteRefreshCacheSize)),
            PopupMenuItem(value: 'clear_metadata', child: Text(context.l10n.remoteFolderActionClearMetadata)),
            PopupMenuItem(value: 'clear_cache', child: Text(context.l10n.remoteFolderActionClearCache)),
            PopupMenuItem(value: 'clear_all_cache', child: Text(context.l10n.remoteActionClearMetadataAndCache)),
            PopupMenuItem(value: 'remove', child: Text(context.l10n.remoteRemoveFromAlbums)),
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
              title: Text(context.l10n.remoteOpenFolder),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('open'),
            ),
            ListTile(
              leading: const Icon(AIcons.refresh),
              title: Text(context.l10n.remoteRefreshCacheSize),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('refresh_cache'),
            ),
            ListTile(
              leading: const Icon(AIcons.info),
              title: Text(context.l10n.remoteFolderActionClearMetadata),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('clear_metadata'),
            ),
            ListTile(
              leading: const Icon(AIcons.clear),
              title: Text(context.l10n.remoteFolderActionClearCache),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('clear_cache'),
            ),
            ListTile(
              leading: const Icon(AIcons.clear),
              title: Text(context.l10n.remoteActionClearMetadataAndCache),
              onTap: () => Navigator.maybeOf(sheetContext)?.pop('clear_all_cache'),
            ),
            ListTile(
              leading: const Icon(AIcons.unpin),
              title: Text(context.l10n.remoteRemoveFromAlbums),
              subtitle: Text(context.l10n.remoteAutoClearFolderCache),
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
      case 'clear_metadata':
        final deleted = await remoteMediaService.clearPinnedFolderMetadata(server: server, folderPath: folder.path);
        if (mounted) {
          showFeedback(
            context,
            FeedbackType.info,
            deleted > 0 ? context.l10n.remoteFolderFeedbackMetadataCleared : context.l10n.remoteFolderFeedbackNoMetadataToClear,
          );
          setState(() {});
        }
      case 'clear_all_cache':
        final cleared = await remoteMediaService.clearPinnedFolderAllCache(server: server, folderPath: folder.path);
        if (cleared) {
          _cacheBytesByPinnedFolder['${server.id}|${folder.path}'] = 0;
          _ensureCacheBytes(server.id, force: true);
        }
        if (mounted) {
          showFeedback(
            context,
            cleared ? FeedbackType.info : FeedbackType.warn,
            cleared ? context.l10n.remoteFolderFeedbackMetadataAndCacheCleared : context.l10n.remoteFolderFeedbackFailedClearMetadataAndCache,
          );
          setState(() {});
        }
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
            cleared ? context.l10n.remoteFolderFeedbackCacheCleared : context.l10n.remoteFolderFeedbackFailedClearCache,
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
            cleared ? context.l10n.remoteFolderFeedbackRemovedAndCacheCleared : context.l10n.remoteFolderFeedbackRemoved,
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
      title: Text(widget.initial == null ? context.l10n.remoteAddServerTitle : context.l10n.remoteEditServerTitle),
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
              decoration: InputDecoration(labelText: context.l10n.remoteDisplayName),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<RemoteProtocol>(
              initialValue: _protocol,
              decoration: InputDecoration(labelText: context.l10n.remoteProtocolLabel),
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
                decoration: InputDecoration(labelText: context.l10n.remoteWebdavUrl),
              ),
              const SizedBox(height: 8),
            ] else ...[
              TextField(
                controller: _hostController,
                decoration: InputDecoration(labelText: context.l10n.remoteHostLabel),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _portController,
                decoration: InputDecoration(labelText: context.l10n.remotePortLabel),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _basePathController,
              decoration: InputDecoration(labelText: context.l10n.remoteBasePath),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(labelText: context.l10n.remoteUsername),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(labelText: context.l10n.remotePassword),
            ),
            if (_protocol == RemoteProtocol.ftp) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.remoteAnonymousLogin),
                value: _ftpAnonymous,
                onChanged: (v) => setState(() => _ftpAnonymous = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.remotePassiveMode),
                value: _ftpPassive,
                onChanged: (v) => setState(() => _ftpPassive = v),
              ),
            ],
            if (_protocol == RemoteProtocol.smb) ...[
              TextField(
                controller: _smbDomainController,
                decoration: InputDecoration(labelText: context.l10n.remoteSmbDomain),
              ),
            ],
            if (_protocol == RemoteProtocol.sftp) ...[
              TextField(
                controller: _sftpPrivateKeyController,
                decoration: InputDecoration(labelText: context.l10n.remoteSftpPrivateKey),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sftpPassphraseController,
                decoration: InputDecoration(labelText: context.l10n.remoteSftpPassphrase),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sftpAdvancedController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: context.l10n.remoteSftpAdvancedConfig),
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
      setState(() => _validationError = context.l10n.remoteValidationDisplayNameRequired);
      return;
    }
    if (_protocol == RemoteProtocol.webdav) {
      final uri = Uri.tryParse(webdavUrl);
      final validScheme = uri != null && {'http', 'https'}.contains(uri.scheme.toLowerCase());
      if (webdavUrl.isEmpty || uri == null || !validScheme || uri.host.isEmpty) {
        setState(() => _validationError = context.l10n.remoteValidationWebdavUrl);
        return;
      }
    } else {
      if (host.isEmpty) {
        setState(() => _validationError = context.l10n.remoteValidationHostRequired);
        return;
      }
      if (_portController.text.trim().isNotEmpty && (parsedPort == null || parsedPort < 1 || parsedPort > 65535)) {
        setState(() => _validationError = context.l10n.remoteValidationPortRange);
        return;
      }
    }
    if (_protocol == RemoteProtocol.sftp && _usernameController.text.trim().isEmpty) {
      setState(() => _validationError = context.l10n.remoteValidationSftpUsernameRequired);
      return;
    }
    final sftpAdvancedText = _sftpAdvancedController.text.trim();
    if (_protocol == RemoteProtocol.sftp && sftpAdvancedText.isNotEmpty) {
      try {
        jsonDecode(sftpAdvancedText);
      } catch (_) {
        setState(() => _validationError = context.l10n.remoteValidationSftpAdvancedJson);
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
