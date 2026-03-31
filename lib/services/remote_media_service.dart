import 'dart:async';

import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class RemoteBrowseNode {
  final String path;
  final String name;
  final bool isDirectory;
  final bool isVideo;
  final bool isImage;

  const RemoteBrowseNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.isVideo = false,
    this.isImage = false,
  });
}

class RemoteFolderPageData {
  final String path;
  final List<RemoteBrowseNode> children;
  final bool blockedByWifiOnly;

  const RemoteFolderPageData({
    required this.path,
    required this.children,
    this.blockedByWifiOnly = false,
  });
}

class RemoteMediaService {
  Future<bool> shouldBlockAutoLoadByWifiPolicy() async {
    if (!settings.remoteWifiOnlyDownload) return false;
    final result = await Connectivity().checkConnectivity();
    final onWifi = result.contains(ConnectivityResult.wifi);
    return !onWifi;
  }

  // Directory lazy-load entry point. This currently returns deterministic
  // sample nodes per level while protocol adapters are being integrated.
  Future<RemoteFolderPageData> loadFolder({
    required RemoteServer server,
    required String path,
    bool force = false,
  }) async {
    final blocked = !force && await shouldBlockAutoLoadByWifiPolicy();
    if (blocked) {
      await remoteMediaLogService.log(
        'remote_load',
        'blocked by wifi-only policy',
        data: {
          'server': server.name,
          'path': path,
        },
      );
      return RemoteFolderPageData(path: path, children: const [], blockedByWifiOnly: true);
    }

    final nodes = _mockNodes(path);
    await remoteMediaLogService.log(
      'lazy_load',
      'loaded remote folder level',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': path,
        'childCount': nodes.length,
      },
    );
    return RemoteFolderPageData(path: path, children: nodes);
  }

  List<RemoteBrowseNode> _mockNodes(String path) {
    final normalized = path.isEmpty ? '/' : path;
    if (normalized == '/' || normalized == '.') {
      return const [
        RemoteBrowseNode(path: '/DCIM', name: 'DCIM', isDirectory: true),
        RemoteBrowseNode(path: '/Movies', name: 'Movies', isDirectory: true),
        RemoteBrowseNode(path: '/旅行', name: '旅行', isDirectory: true),
      ];
    }

    final isLeaf = normalized.split('/').where((v) => v.isNotEmpty).length >= 3;
    if (isLeaf) {
      return [
        RemoteBrowseNode(path: '$normalized/封面.jpg', name: '封面.jpg', isDirectory: false, isImage: true),
        RemoteBrowseNode(path: '$normalized/预告.mp4', name: '预告.mp4', isDirectory: false, isVideo: true),
      ];
    }

    return [
      RemoteBrowseNode(path: '$normalized/子目录A', name: '子目录A', isDirectory: true),
      RemoteBrowseNode(path: '$normalized/子目录B', name: '子目录B', isDirectory: true),
      RemoteBrowseNode(path: '$normalized/样例图.png', name: '样例图.png', isDirectory: false, isImage: true),
      RemoteBrowseNode(path: '$normalized/样例视频.mp4', name: '样例视频.mp4', isDirectory: false, isVideo: true),
    ];
  }
}
