import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/enums/remote_stream_mode.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:http/http.dart' as http;
import 'package:smb_connect/smb_connect.dart';
import 'package:xml/xml.dart';

class RemoteBrowseNode {
  final String path;
  final String name;
  final bool isDirectory;
  final bool isVideo;
  final bool isImage;
  final int? sizeBytes;

  const RemoteBrowseNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.isVideo = false,
    this.isImage = false,
    this.sizeBytes,
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

class RemoteConnectionTestResult {
  final bool success;
  final String message;
  final int? latencyMillis;

  const RemoteConnectionTestResult({
    required this.success,
    required this.message,
    this.latencyMillis,
  });
}

class RemotePreviewPlan {
  final bool streamFirst;
  final bool shouldAutoDownload;
  final bool allowDownloadFallback;
  final String reason;

  const RemotePreviewPlan({
    required this.streamFirst,
    required this.shouldAutoDownload,
    required this.allowDownloadFallback,
    required this.reason,
  });
}

class RemoteMediaService {
  Future<RemoteConnectionTestResult> testConnection(RemoteServer server) async {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return _testWebDav(server);
      case RemoteProtocol.ftp:
      case RemoteProtocol.sftp:
      case RemoteProtocol.smb:
        return _testTcp(server);
    }
  }

  Future<bool> shouldBlockAutoLoadByWifiPolicy() async {
    if (!settings.remoteWifiOnlyDownload) return false;
    final result = await Connectivity().checkConnectivity();
    final onWifi = result.contains(ConnectivityResult.wifi);
    return !onWifi;
  }

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

  Future<RemotePreviewPlan> decidePreviewPlan({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final size = node.sizeBytes;
    final max = node.isVideo ? settings.remoteAutoDownloadVideoMaxBytes : settings.remoteAutoDownloadImageMaxBytes;
    final withinAutoLimit = size != null && size > 0 && size <= max;
    final streamMode = settings.remoteStreamMode;

    final RemotePreviewPlan plan;
    if (streamMode == RemoteStreamMode.streamOnly) {
      plan = const RemotePreviewPlan(
        streamFirst: true,
        shouldAutoDownload: false,
        allowDownloadFallback: false,
        reason: 'stream_only',
      );
    } else if (node.isVideo) {
      plan = RemotePreviewPlan(
        streamFirst: true,
        shouldAutoDownload: false,
        allowDownloadFallback: withinAutoLimit || size == null,
        reason: withinAutoLimit ? 'video_stream_then_fallback_download' : 'video_stream_fallback_limited_by_size',
      );
    } else if (withinAutoLimit) {
      plan = const RemotePreviewPlan(
        streamFirst: false,
        shouldAutoDownload: true,
        allowDownloadFallback: false,
        reason: 'image_auto_download_within_limit',
      );
    } else {
      plan = const RemotePreviewPlan(
        streamFirst: true,
        shouldAutoDownload: false,
        allowDownloadFallback: true,
        reason: 'image_stream_then_fallback_download',
      );
    }

    await remoteMediaLogService.log(
      'autoplay',
      'remote preview plan decided',
      data: {
        'server': server.name,
        'path': node.path,
        'isVideo': node.isVideo,
        'isImage': node.isImage,
        'sizeBytes': size,
        'streamMode': streamMode.name,
        'streamFirst': plan.streamFirst,
        'autoDownload': plan.shouldAutoDownload,
        'allowFallback': plan.allowDownloadFallback,
        'reason': plan.reason,
      },
    );
    return plan;
  }

  Future<List<RemoteBrowseNode>> _listNodes(RemoteServer server, String path) async {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return _listWebDav(server, path);
      case RemoteProtocol.ftp:
        return _listFtp(server, path);
      case RemoteProtocol.sftp:
        return _listSftp(server, path);
      case RemoteProtocol.smb:
        return _listSmb(server, path);
    }
  }

  Future<List<RemoteBrowseNode>> _listWebDav(RemoteServer server, String path) async {
    final base = server.webdavUrl;
    if (base == null || base.isEmpty) return const [];

    final targetUri = _buildWebDavUri(base, _resolveEffectivePath(server, path));
    if (targetUri == null) return const [];

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
        return const [];
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
            path: _normalizePath(decodedPath),
            name: name,
            isDirectory: isDirectory,
            isVideo: isVideo,
            isImage: isImage,
          ),
        );
      }

      if (out.isEmpty) {
        await remoteMediaLogService.log(
          'lazy_load',
          'webdav empty level',
          data: {
            'uri': targetUri.toString(),
          },
        );
      }
      return out..sort(_compareNodes);
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
      return const [];
    } finally {
      client.close();
    }
  }

  Future<List<RemoteBrowseNode>> _listFtp(RemoteServer server, String path) async {
    final host = server.host;
    if (host == null || host.isEmpty) return const [];

    final user = server.ftpAnonymous ? 'anonymous' : (server.username ?? 'anonymous');
    final pass = server.ftpAnonymous ? 'anonymous@' : (server.password ?? '');
    final ftp = FTPConnect(
      host,
      port: server.port ?? 21,
      user: user,
      pass: pass,
      timeout: 20,
    );
    ftp.transferMode = server.ftpPassiveMode ? TransferMode.passive : TransferMode.active;
    ftp.listCommand = ListCommand.mlsd;

    try {
      final connected = await ftp.connect();
      if (!connected) {
        await remoteMediaLogService.log('remote_load', 'ftp connect failed', data: {'server': server.name, 'host': host, 'port': server.port ?? 21});
        return const [];
      }
      final targetPath = _resolveEffectivePath(server, path);
      final changed = await ftp.changeDirectory(targetPath);
      if (!changed) {
        await remoteMediaLogService.log('remote_load', 'ftp change directory failed', data: {'server': server.name, 'targetPath': targetPath});
        return const [];
      }

      final list = await ftp.listDirectoryContent();
      final out = list.where((v) => v.name != '.' && v.name != '..').map((v) {
        final isDirectory = v.type == FTPEntryType.dir;
        final name = v.name;
        final lower = name.toLowerCase();
        return RemoteBrowseNode(
          path: _joinRemotePath(path, name),
          name: name,
          isDirectory: isDirectory,
          isVideo: !isDirectory && _videoExt.any(lower.endsWith),
          isImage: !isDirectory && _imageExt.any(lower.endsWith),
          sizeBytes: isDirectory ? null : v.size,
        );
      }).toList()..sort(_compareNodes);
      return out;
    } catch (error, stack) {
      await remoteMediaLogService.log('remote_load', 'ftp list exception', data: {'server': server.name, 'path': path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return const [];
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  Future<List<RemoteBrowseNode>> _listSftp(RemoteServer server, String path) async {
    final host = server.host;
    if (host == null || host.isEmpty) return const [];
    final username = server.username;
    if (username == null || username.isEmpty) return const [];
    final port = server.port ?? 22;

    SSHClient? client;
    SftpClient? sftp;
    try {
      final socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 8));
      final privateKeyText = server.sftpPrivateKey;
      final passphrase = server.sftpPassphrase;
      final identities = privateKeyText != null && privateKeyText.isNotEmpty ? SSHKeyPair.fromPem(privateKeyText, passphrase?.isNotEmpty == true ? passphrase : null) : null;

      client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: () => server.password,
      );
      await client.authenticated.timeout(const Duration(seconds: 12));
      sftp = await client.sftp();
      final targetPath = _resolveEffectivePath(server, path);
      final list = await sftp.listdir(targetPath);

      final out = list.where((v) => v.filename != '.' && v.filename != '..').map((v) {
        final name = v.filename;
        final isDirectory = v.attr.isDirectory;
        final lower = name.toLowerCase();
        return RemoteBrowseNode(
          path: _joinRemotePath(path, name),
          name: name,
          isDirectory: isDirectory,
          isVideo: !isDirectory && _videoExt.any(lower.endsWith),
          isImage: !isDirectory && _imageExt.any(lower.endsWith),
          sizeBytes: isDirectory ? null : v.attr.size,
        );
      }).toList()..sort(_compareNodes);
      return out;
    } catch (error, stack) {
      await remoteMediaLogService.log('remote_load', 'sftp list exception', data: {'server': server.name, 'path': path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return const [];
    } finally {
      sftp?.close();
      client?.close();
    }
  }

  Future<List<RemoteBrowseNode>> _listSmb(RemoteServer server, String path) async {
    final host = server.host;
    if (host == null || host.isEmpty) return const [];

    SmbConnect? smb;
    try {
      smb = await SmbConnect.connectAuth(
        host: host,
        username: server.username ?? '',
        password: server.password ?? '',
        domain: server.smbDomain ?? '',
      );
      final targetPath = _resolveEffectivePath(server, path);
      if (_normalizePath(targetPath) == '/') {
        final shares = await smb.listShares();
        return shares.map((v) => RemoteBrowseNode(path: '/${v.name}', name: v.name, isDirectory: true)).toList()..sort(_compareNodes);
      }

      final folder = await smb.file(targetPath);
      final list = await smb.listFiles(folder);
      final out = list.where((v) => v.name != '.' && v.name != '..').map((v) {
        final name = v.name;
        final isDirectory = v.isDirectory();
        final lower = name.toLowerCase();
        return RemoteBrowseNode(
          path: _joinRemotePath(path, name),
          name: name,
          isDirectory: isDirectory,
          isVideo: !isDirectory && _videoExt.any(lower.endsWith),
          isImage: !isDirectory && _imageExt.any(lower.endsWith),
          sizeBytes: isDirectory ? null : v.size,
        );
      }).toList()..sort(_compareNodes);
      return out;
    } catch (error, stack) {
      await remoteMediaLogService.log('remote_load', 'smb list exception', data: {'server': server.name, 'path': path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return const [];
    } finally {
      await smb?.close();
    }
  }

  Future<RemoteConnectionTestResult> _testWebDav(RemoteServer server) async {
    final base = server.webdavUrl;
    if (base == null || base.isEmpty) {
      return const RemoteConnectionTestResult(success: false, message: 'Missing WebDAV URL');
    }
    final uri = Uri.tryParse(base);
    if (uri == null) {
      return const RemoteConnectionTestResult(success: false, message: 'Invalid WebDAV URL');
    }

    final client = http.Client();
    final watch = Stopwatch()..start();
    try {
      final headers = <String, String>{'Depth': '0'};
      final username = server.username;
      final password = server.password;
      if (username != null && password != null) {
        final token = base64Encode(utf8.encode('$username:$password'));
        headers['Authorization'] = 'Basic $token';
      }

      final response = await client.send(
        http.Request('PROPFIND', uri)
          ..headers.addAll(headers)
          ..body = '',
      );
      await response.stream.drain<void>();
      watch.stop();
      final ok = response.statusCode >= 200 && response.statusCode < 500;
      await remoteMediaLogService.log(
        'remote_load',
        'webdav connection test',
        data: {
          'server': server.name,
          'status': response.statusCode,
          'latencyMs': watch.elapsedMilliseconds,
        },
      );
      return RemoteConnectionTestResult(
        success: ok,
        message: ok ? 'WebDAV responded with ${response.statusCode}' : 'WebDAV failed with ${response.statusCode}',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } catch (error, stack) {
      watch.stop();
      await remoteMediaLogService.log(
        'remote_load',
        'webdav connection exception',
        data: {
          'server': server.name,
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
      return RemoteConnectionTestResult(
        success: false,
        message: 'WebDAV error: $error',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } finally {
      client.close();
    }
  }

  Future<RemoteConnectionTestResult> _testTcp(RemoteServer server) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      return const RemoteConnectionTestResult(success: false, message: 'Missing host');
    }
    final port =
        server.port ??
        switch (server.protocol) {
          RemoteProtocol.ftp => 21,
          RemoteProtocol.sftp => 22,
          RemoteProtocol.smb => 445,
          RemoteProtocol.webdav => 80,
        };
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 6));
      socket.destroy();
      watch.stop();
      await remoteMediaLogService.log(
        'remote_load',
        'tcp connection test success',
        data: {
          'server': server.name,
          'protocol': server.protocol.name,
          'host': host,
          'port': port,
          'latencyMs': watch.elapsedMilliseconds,
          'ftpAnonymous': server.ftpAnonymous,
          'ftpPassive': server.ftpPassiveMode,
        },
      );
      return RemoteConnectionTestResult(
        success: true,
        message: '${server.protocol.name.toUpperCase()} TCP reachable',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } catch (error) {
      watch.stop();
      await remoteMediaLogService.log(
        'remote_load',
        'tcp connection test failed',
        data: {
          'server': server.name,
          'protocol': server.protocol.name,
          'host': host,
          'port': port,
          'error': '$error',
        },
      );
      return RemoteConnectionTestResult(
        success: false,
        message: '${server.protocol.name.toUpperCase()} TCP failed: $error',
        latencyMillis: watch.elapsedMilliseconds,
      );
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

  String _resolveEffectivePath(RemoteServer server, String path) {
    final relative = _normalizePath(path);
    final base = server.basePath;
    if (base == null || base.trim().isEmpty || _normalizePath(base) == '/') return relative;
    if (relative == '/') return _normalizePath(base);
    return _normalizePath('${_normalizePath(base)}/${relative.replaceFirst(RegExp(r'^/+'), '')}');
  }

  String _joinRemotePath(String parent, String childName) {
    final p = _normalizePath(parent);
    if (p == '/') return '/$childName';
    return '$p/$childName';
  }

  String _normalizePath(String value) {
    final v = value.trim();
    if (v.isEmpty) return '/';
    return '/${v.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '')}';
  }

  int _compareNodes(RemoteBrowseNode a, RemoteBrowseNode b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static const _videoExt = ['.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.ts'];
  static const _imageExt = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.bmp', '.tiff', '.avif', '.svg'];
}
