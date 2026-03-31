import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/remote_media_service.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:flutter/material.dart';

class RemoteBrowserPage extends StatefulWidget {
  static const routeName = '/remote/browser';
  final RemoteServer server;
  final String initialPath;

  const RemoteBrowserPage({
    super.key,
    required this.server,
    this.initialPath = '/',
  });

  @override
  State<RemoteBrowserPage> createState() => _RemoteBrowserPageState();
}

class _RemoteBrowserPageState extends State<RemoteBrowserPage> with FeedbackMixin {
  final _service = RemoteMediaService();
  final _queryController = TextEditingController();
  late Future<RemoteFolderPageData> _loader;
  late String _path;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _loader = _load();
    _queryController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<RemoteFolderPageData> _load({bool force = false}) => _service.loadFolder(server: widget.server, path: _path, force: force);

  String _parentPath(String path) {
    final parts = path.split('/').where((v) => v.isNotEmpty).toList();
    if (parts.isEmpty) return '/';
    final parent = parts.take(parts.length - 1).join('/');
    return parent.isEmpty ? '/' : '/$parent';
  }

  @override
  Widget build(BuildContext context) {
    String tr(String en, String zh) => context.locale.startsWith('zh') ? zh : en;

    return PopScope(
      canPop: _path == '/' || _path == '.',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _path = _parentPath(_path);
          _loader = _load(force: true);
        });
      },
      child: AvesScaffold(
        appBar: AppBar(
          title: Text('${widget.server.name}  $_path'),
          actions: [
            if (_path != '/')
              IconButton(
                onPressed: () => setState(() {
                  _path = _parentPath(_path);
                  _loader = _load(force: true);
                }),
                icon: const Icon(Icons.arrow_upward),
                tooltip: tr('Parent folder', '上级目录'),
              ),
            IconButton(
              onPressed: () => setState(() => _loader = _load(force: true)),
              icon: const Icon(AIcons.refresh),
              tooltip: tr('Refresh', '刷新'),
            ),
            IconButton(
              onPressed: _togglePin,
              icon: Icon(_isPinned ? AIcons.unpin : AIcons.pin),
              tooltip: _isPinned ? tr('Unpin folder', '取消固定文件夹') : tr('Show in remote albums', '在远程相册中显示'),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: TextField(
                  controller: _queryController,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(AIcons.search),
                    hintText: tr('Search this level', '搜索当前层级'),
                    suffixIcon: _queryController.text.isNotEmpty
                        ? IconButton(
                            onPressed: _queryController.clear,
                            icon: const Icon(AIcons.clear),
                          )
                        : null,
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder<RemoteFolderPageData>(
                  future: _loader,
                  builder: (context, snapshot) {
                    final data = snapshot.data;
                    if (data == null) {
                      if (snapshot.hasError) {
                        return Center(child: Text('Error: ${snapshot.error}'));
                      }
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (data.blockedByWifiOnly) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(AIcons.error),
                            const SizedBox(height: 8),
                            Text(tr('Wi-Fi only auto-load is enabled', '已开启仅 Wi-Fi 自动加载')),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: () => setState(() => _loader = _load(force: true)),
                              child: Text(tr('Load now', '立即加载')),
                            ),
                          ],
                        ),
                      );
                    }

                    final q = _queryController.text.trim().toLowerCase();
                    final nodes = q.isEmpty ? data.children : data.children.where((v) => v.name.toLowerCase().contains(q)).toList();
                    if (nodes.isEmpty) {
                      return Center(child: Text(tr('No matching remote folders or media', '没有匹配的远程文件夹或媒体')));
                    }

                    return ListView.builder(
                      itemCount: nodes.length,
                      itemBuilder: (context, index) {
                        final node = nodes[index];
                        return ListTile(
                          leading: Icon(node.isDirectory ? AIcons.folder : (node.isVideo ? AIcons.video : AIcons.image)),
                          title: Text(node.name),
                          subtitle: Text('${node.path}${node.sizeBytes != null ? '  (${node.sizeBytes}B)' : ''}'),
                          onTap: () async {
                            if (node.isDirectory) {
                              setState(() {
                                _path = node.path;
                                _loader = _load(force: true);
                              });
                            } else {
                              final result = await _service.resolveMedia(server: widget.server, node: node);
                              if (!mounted) return;
                              final plan = result.plan;
                              final mode = plan.streamFirst ? tr('Stream first', '优先流式') : tr('Download first', '优先下载');
                              final fallback = plan.allowDownloadFallback ? tr('fallback enabled', '允许回退下载') : tr('fallback disabled', '不允许回退下载');
                              final auto = plan.shouldAutoDownload ? tr('auto-download', '自动下载') : tr('no auto-download', '不自动下载');
                              final cached = result.downloadedFile != null ? tr('cached', '已缓存') : tr('not cached', '未缓存');
                              showFeedback(context, FeedbackType.info, '$mode, $auto, $fallback, $cached');
                            }
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isPinned => settings.remotePinnedFolders.any((v) => v.serverId == widget.server.id && v.path == _path);

  String get _pathLeaf {
    final parts = _path.split('/').where((v) => v.isNotEmpty).toList();
    return parts.isEmpty ? '/' : parts.last;
  }

  Future<void> _togglePin() async {
    final all = settings.remotePinnedFolders;
    if (_isPinned) {
      settings.remotePinnedFolders = all.where((v) => !(v.serverId == widget.server.id && v.path == _path)).toList();
      await remoteMediaLogService.log('remote_load', 'unpinned folder', data: {'server': widget.server.name, 'path': _path});
    } else {
      settings.remotePinnedFolders = [
        ...all,
        RemotePinnedFolder(serverId: widget.server.id, path: _path, title: '${widget.server.name}:$_pathLeaf'),
      ];
      await remoteMediaLogService.log('remote_load', 'pinned folder', data: {'server': widget.server.name, 'path': _path});
    }
    setState(() {});
  }
}
