import 'dart:async';

import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/remote_media_service.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
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

  @override
  Widget build(BuildContext context) {
    return AvesScaffold(
      appBar: AppBar(
        title: Text('${widget.server.name}  $_path'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _loader = _load(force: true)),
            icon: const Icon(AIcons.refresh),
            tooltip: 'Refresh',
          ),
          IconButton(
            onPressed: _togglePin,
            icon: Icon(_isPinned ? AIcons.unpin : AIcons.pin),
            tooltip: _isPinned ? 'Unpin folder' : 'Show in remote albums',
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
                  hintText: 'Search this level',
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
                          const Text('Wi-Fi only auto-load is enabled'),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: () => setState(() => _loader = _load(force: true)),
                            child: const Text('Load now'),
                          ),
                        ],
                      ),
                    );
                  }

                  final q = _queryController.text.trim().toLowerCase();
                  final nodes = q.isEmpty ? data.children : data.children.where((v) => v.name.toLowerCase().contains(q)).toList();
                  if (nodes.isEmpty) {
                    return const Center(child: Text('No matching remote folders or media'));
                  }

                  return ListView.builder(
                    itemCount: nodes.length,
                    itemBuilder: (context, index) {
                      final node = nodes[index];
                      return ListTile(
                        leading: Icon(node.isDirectory ? AIcons.folder : (node.isVideo ? AIcons.video : AIcons.image)),
                        title: Text(node.name),
                        subtitle: Text(node.path),
                        onTap: () {
                          if (node.isDirectory) {
                            Navigator.maybeOf(context)?.push(
                              MaterialPageRoute(
                                settings: const RouteSettings(name: RemoteBrowserPage.routeName),
                                builder: (_) => RemoteBrowserPage(server: widget.server, initialPath: node.path),
                              ),
                            );
                          } else {
                            showFeedback(context, FeedbackType.info, 'Preview chain will be connected in next step');
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
    );
  }

  bool get _isPinned => settings.remotePinnedFolders.any((v) => v.serverId == widget.server.id && v.path == _path);

  Future<void> _togglePin() async {
    final all = settings.remotePinnedFolders;
    if (_isPinned) {
      settings.remotePinnedFolders = all.where((v) => !(v.serverId == widget.server.id && v.path == _path)).toList();
      await remoteMediaLogService.log('remote_load', 'unpinned folder', data: {'server': widget.server.name, 'path': _path});
    } else {
      settings.remotePinnedFolders = [
        ...all,
        RemotePinnedFolder(serverId: widget.server.id, path: _path, title: '${widget.server.name}:$_path'),
      ];
      await remoteMediaLogService.log('remote_load', 'pinned folder', data: {'server': widget.server.name, 'path': _path});
    }
    setState(() {});
  }
}
