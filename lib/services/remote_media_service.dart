import 'dart:async';
import 'dart:convert';

import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

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

    final nodes = await _listNodes(server, path);
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

  Future<List<RemoteBrowseNode>> _listNodes(RemoteServer server, String path) async {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return _listWebDav(server, path);
      case RemoteProtocol.ftp:
      case RemoteProtocol.sftp:
      case RemoteProtocol.smb:
        return _mockNodes(path);
    }
  }

  Future<List<RemoteBrowseNode>> _listWebDav(RemoteServer server, String path) async {
    final base = server.webdavUrl;
    if (base == null || base.isEmpty) return _mockNodes(path);

    final targetUri = _buildWebDavUri(base, path);
    if (targetUri == null) return _mockNodes(path);

    final client = http.Client();
    try {
      final headers = <String, String>{
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      };
      final username = server.username;
      final password = server.password;
      if (username != null && password != null) {
        final token = base64Encode(utf8.encode('$username:$password'));
        headers['Authorization'] = 'Basic $token';
      }

      const body = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
    <d:getcontenttype/>
  </d:prop>
</d:propfind>''';
      final response = await client.send(
        http.Request('PROPFIND', targetUri)
          ..headers.addAll(headers)
          ..body = body,
      );
      final text = await response.stream.bytesToString();
      if (response.statusCode != 207 && response.statusCode != 200) {
        await remoteMediaLogService.log(
          'remote_load',
          'webdav list failed',
          data: {
            'status': response.statusCode,
            'uri': targetUri.toString(),
          },
        );
        return _mockNodes(path);
      }

      final doc = XmlDocument.parse(text);
      final responses = doc.findAllElements('response', namespace: 'DAV:').toList();
      final out = <RemoteBrowseNode>[];
      for (final node in responses) {
        final hrefText = node.findElements('href', namespace: 'DAV:').firstOrNull?.innerText;
        if (hrefText == null || hrefText.isEmpty) continue;
        final hrefUri = Uri.tryParse(hrefText);
        final decodedPath = Uri.decodeFull((hrefUri?.path ?? hrefText).trim());
        if (decodedPath.isEmpty) continue;

        // skip self entry (Depth:1 includes current folder)
        if (_normalizePath(decodedPath) == _normalizePath(path) || _normalizePath(decodedPath) == _normalizePath(targetUri.path)) {
          continue;
        }

        final displayName = node.findElements('displayname', namespace: 'DAV:').firstOrNull?.innerText.trim();
        final resourceType = node.findAllElements('collection', namespace: 'DAV:').isNotEmpty;
        final contentType = node.findElements('getcontenttype', namespace: 'DAV:').firstOrNull?.innerText.toLowerCase() ?? '';

        final name = displayName != null && displayName.isNotEmpty ? displayName : decodedPath.split('/').where((v) => v.isNotEmpty).lastOrNull ?? decodedPath;
        final isDirectory = resourceType;
        final lowerName = name.toLowerCase();
        final isVideo = !isDirectory && (contentType.startsWith('video/') || _videoExt.any(lowerName.endsWith));
        final isImage = !isDirectory && (contentType.startsWith('image/') || _imageExt.any(lowerName.endsWith));

        out.add(
          RemoteBrowseNode(
            path: decodedPath,
            name: name,
            isDirectory: isDirectory,
            isVideo: isVideo,
            isImage: isImage,
          ),
        );
      }

      if (out.isEmpty) {
        // keep subfolder-only / empty-folder behavior explicit
        await remoteMediaLogService.log(
          'lazy_load',
          'webdav empty level',
          data: {
            'uri': targetUri.toString(),
          },
        );
      }
      return out;
    } catch (error, stack) {
      await remoteMediaLogService.log(
        'remote_load',
        'webdav list exception',
        data: {
          'uri': targetUri.toString(),
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
      return _mockNodes(path);
    } finally {
      client.close();
    }
  }

  Uri? _buildWebDavUri(String base, String path) {
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return null;
    final normalizedPath = path.trim().isEmpty ? '/' : path.trim();
    if (normalizedPath == '/' || normalizedPath == '.') return baseUri;
    final basePath = baseUri.path.endsWith('/') ? baseUri.path.substring(0, baseUri.path.length - 1) : baseUri.path;
    final fullPath = '$basePath/${normalizedPath.replaceFirst(RegExp(r'^/+'), '')}';
    return baseUri.replace(path: fullPath);
  }

  String _normalizePath(String value) {
    final v = value.trim();
    if (v.isEmpty) return '/';
    return '/${v.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '')}';
  }

  static const _videoExt = ['.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.ts'];
  static const _imageExt = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.bmp', '.tiff', '.avif', '.svg'];

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
