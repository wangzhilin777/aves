import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/catalog.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/settings/enums/remote_stream_mode.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/remote_stream_proxy_service.dart';
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
  final int? modifiedMillis;

  const RemoteBrowseNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.isVideo = false,
    this.isImage = false,
    this.sizeBytes,
    this.modifiedMillis,
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

class RemoteMediaResolveResult {
  final Uri? streamUri;
  final File? downloadedFile;
  final RemotePreviewPlan plan;

  const RemoteMediaResolveResult({
    required this.streamUri,
    required this.downloadedFile,
    required this.plan,
  });
}

class _ChunkFileSegment {
  final File file;
  final RemoteByteRange range;

  const _ChunkFileSegment({
    required this.file,
    required this.range,
  });
}

class RemoteMediaService {
  static const _streamChunkSizeBytes = 2 * 1024 * 1024;
  final Map<String, (RemoteServer server, RemoteBrowseNode node)> _virtualRemoteRefs = {};
  final Set<String> _downloadInProgressUris = {};
  final Set<String> _cacheWarmupKeys = {};
  final Map<String, (String uri, int expiresAtMillis)> _playbackUriCache = {};
  final Set<String> _proxyLoggedUris = {};

  RemoteMediaService() {
    remoteStreamProxyService.remoteRequestHandler = _handleProxyRequest;
    unawaited(remoteStreamProxyService.ensureStarted());
  }

  void registerVirtualRemoteRef({
    required String uri,
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) {
    _virtualRemoteRefs[uri] = (server, node);
  }

  bool hasVirtualRemoteRef(String uri) => _virtualRemoteRefs.containsKey(uri);

  Future<String> resolveStreamUriForPlayback(String rawUri) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _playbackUriCache[rawUri];
    if (cached != null && cached.$2 > now) {
      return cached.$1;
    }

    final uri = Uri.tryParse(rawUri);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return rawUri;
    }

    final targetUri = uri.userInfo.isNotEmpty ? uri.replace(userInfo: '') : uri;
    final headers = <String, String>{
      'Range': 'bytes=0-1',
    };
    if (uri.userInfo.isNotEmpty) {
      final token = base64Encode(utf8.encode(uri.userInfo));
      headers['Authorization'] = 'Basic $token';
    }

    final client = http.Client();
    try {
      final req = http.Request('GET', targetUri)..headers.addAll(headers);
      final resp = await client.send(req).timeout(const Duration(seconds: 8));
      await resp.stream.drain<void>();
      String? resolvedUri;
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final location = resp.headers['location'];
        if (location != null && location.isNotEmpty) {
          resolvedUri = targetUri.resolve(location).toString();
        }
      } else if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final candidate = resp.request?.url.toString();
        if (candidate != null && candidate.isNotEmpty && candidate != targetUri.toString()) {
          resolvedUri = candidate;
        }
      }

      if (resolvedUri != null) {
        resolvedUri = _preserveAuthUserInfo(uri, resolvedUri);
      }

      if (resolvedUri != null && resolvedUri != rawUri) {
        _playbackUriCache[rawUri] = (resolvedUri, now + const Duration(minutes: 10).inMilliseconds);
        final ref = _virtualRemoteRefs[rawUri];
        if (ref != null) {
          _virtualRemoteRefs[resolvedUri] = ref;
        }
        await remoteMediaLogService.log(
          'autoplay',
          'resolved remote stream uri for playback',
          data: {
            'from': rawUri,
            'to': resolvedUri,
            'status': resp.statusCode,
            'location': resp.headers['location'],
          },
        );
        return resolvedUri;
      }

      await remoteMediaLogService.log(
        'autoplay',
        'keep original remote playback uri',
        data: {
          'uri': rawUri,
          'status': resp.statusCode,
          'location': resp.headers['location'],
        },
      );
    } catch (error) {
      await remoteMediaLogService.log(
        'autoplay',
        'failed to resolve remote playback uri, using original',
        data: {
          'uri': rawUri,
          'error': '$error',
        },
      );
    } finally {
      client.close();
    }

    return rawUri;
  }

  String _preserveAuthUserInfo(Uri originalUri, String candidateUriRaw) {
    if (originalUri.userInfo.isEmpty) return candidateUriRaw;
    final candidateUri = Uri.tryParse(candidateUriRaw);
    if (candidateUri == null) return candidateUriRaw;
    if (candidateUri.userInfo.isNotEmpty) return candidateUriRaw;
    final sameTarget = candidateUri.scheme == originalUri.scheme && candidateUri.host.toLowerCase() == originalUri.host.toLowerCase() && candidateUri.port == originalUri.port;
    if (!sameTarget) return candidateUriRaw;
    return candidateUri.replace(userInfo: originalUri.userInfo).toString();
  }

  int? _parseHttpDateMillis(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return HttpDate.parse(raw).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  Future<File?> ensureDownloadedForEntry(
    AvesEntry entry, {
    String trigger = 'remote_entry_prefetch',
  }) async {
    final sourceUri = entry.uri;
    final ref = _virtualRemoteRefs[sourceUri];
    if (ref == null) return null;
    if (_downloadInProgressUris.contains(sourceUri)) return null;

    _downloadInProgressUris.add(sourceUri);
    try {
      final file = await downloadMedia(
        server: ref.$1,
        node: ref.$2,
        trigger: trigger,
      );
      if (file == null) return null;
      final fileUri = Uri.file(file.path).toString();
      entry.uri = fileUri;
      entry.path = file.path;
      entry.sizeBytes = await file.length();
      _virtualRemoteRefs[fileUri] = ref;
      await _refreshEntryMetadataFromLocalFile(entry, fileUri);
      entry.visualChangeNotifier.notify();
      await remoteMediaLogService.log(
        'auto_download',
        'entry switched to downloaded file',
        data: {
          'trigger': trigger,
          'fromUri': sourceUri,
          'toFile': file.path,
        },
      );
      return file;
    } finally {
      _downloadInProgressUris.remove(sourceUri);
    }
  }

  Future<void> ensureEntryMetadata(
    AvesEntry entry, {
    String trigger = 'remote_metadata',
  }) async {
    var changed = false;

    final localPath = entry.path;
    if (localPath != null) {
      final localFile = File(localPath);
      if (await localFile.exists()) {
        final fileLength = await localFile.length();
        if (fileLength > 0 && entry.sizeBytes != fileLength) {
          entry.sizeBytes = fileLength;
          changed = true;
        }
        final stat = await localFile.stat();
        final modifiedMillis = stat.modified.millisecondsSinceEpoch;
        if (modifiedMillis > 0) {
          if (entry.dateModifiedMillis != modifiedMillis) {
            entry.dateModifiedMillis = modifiedMillis;
            changed = true;
          }
          if (entry.sourceDateTakenMillis == null) {
            entry.sourceDateTakenMillis = modifiedMillis;
            changed = true;
          }
        }
      }
    }

    final ref = _virtualRemoteRefs[entry.uri];
    if (ref != null) {
      final server = ref.$1;
      final node = ref.$2;

      if (entry.sizeBytes == null && node.sizeBytes != null) {
        entry.sizeBytes = node.sizeBytes;
        changed = true;
      }
      if (entry.dateModifiedMillis == null && node.modifiedMillis != null) {
        entry.dateModifiedMillis = node.modifiedMillis;
        changed = true;
      }
      if (entry.sourceDateTakenMillis == null && node.modifiedMillis != null) {
        entry.sourceDateTakenMillis = node.modifiedMillis;
        changed = true;
      }
      if ((entry.sourceTitle == null || entry.sourceTitle!.isEmpty) && node.name.isNotEmpty) {
        entry.sourceTitle = node.name;
        changed = true;
      }

      if (server.protocol == RemoteProtocol.webdav && (entry.sizeBytes == null || entry.dateModifiedMillis == null)) {
        final metadata = await _fetchWebDavFileMetadata(server: server, node: node);
        final sizeBytes = metadata['sizeBytes'] as int?;
        final modifiedMillis = metadata['modifiedMillis'] as int?;
        if (sizeBytes != null && sizeBytes > 0 && entry.sizeBytes != sizeBytes) {
          entry.sizeBytes = sizeBytes;
          changed = true;
        }
        if (modifiedMillis != null && modifiedMillis > 0) {
          if (entry.dateModifiedMillis != modifiedMillis) {
            entry.dateModifiedMillis = modifiedMillis;
            changed = true;
          }
          if (entry.sourceDateTakenMillis == null) {
            entry.sourceDateTakenMillis = modifiedMillis;
            changed = true;
          }
        }
      }
    }

    if (changed) {
      entry.metadataChangeNotifier.notify();
      await remoteMediaLogService.log(
        'remote_load',
        'refreshed remote entry metadata',
        data: {
          'trigger': trigger,
          'uri': entry.uri,
          'sizeBytes': entry.sizeBytes,
          'dateModifiedMillis': entry.dateModifiedMillis,
          'sourceDateTakenMillis': entry.sourceDateTakenMillis,
          'durationMillis': entry.durationMillis,
        },
      );
    }
  }

  Future<void> warmupVideoCacheForEntry(
    AvesEntry entry, {
    String trigger = 'stream_cache_warmup',
  }) async {
    if (!entry.isVideo) return;
    if (trigger == 'grid_preview') {
      await remoteMediaLogService.log(
        'auto_download',
        'skip full video warmup during grid preview because stream chunk cache is preferred',
        data: {
          'trigger': trigger,
          'uri': entry.uri,
        },
      );
      return;
    }
    final ref = _virtualRemoteRefs[entry.uri];
    if (ref == null) return;

    final server = ref.$1;
    final node = ref.$2;
    final warmupKey = '${server.id}|${node.path}';
    if (_cacheWarmupKeys.contains(warmupKey)) return;
    final existing = await _getExistingCacheFile(server, node);
    if (existing != null) {
      await remoteMediaLogService.log(
        'auto_download',
        'skip warmup because video cache already exists',
        data: {
          'trigger': trigger,
          'server': server.name,
          'path': node.path,
          'file': existing.path,
        },
      );
      return;
    }

    _cacheWarmupKeys.add(warmupKey);
    unawaited(
      ensureDownloadedForEntry(entry, trigger: trigger)
          .then((file) async {
            if (file != null) {
              await ensureEntryMetadata(entry, trigger: '${trigger}_downloaded');
              await remoteMediaLogService.log(
                'auto_download',
                'video warmup switched current entry to cached file',
                data: {
                  'trigger': trigger,
                  'server': server.name,
                  'path': node.path,
                  'uri': entry.uri,
                  'file': file.path,
                },
              );
            }
          })
          .whenComplete(() {
            _cacheWarmupKeys.remove(warmupKey);
          }),
    );
  }

  Future<void> _refreshEntryMetadataFromLocalFile(AvesEntry entry, String fileUri) async {
    try {
      final fetched = await mediaFetchService.getEntry(fileUri, entry.sourceMimeType, allowUnsized: true);
      if (fetched != null) {
        if (fetched.width <= 1 || fetched.height <= 1) {
          await fetched.catalog(background: false, force: true, persist: false);
        }
        entry.width = fetched.width;
        entry.height = fetched.height;
        entry.sourceRotationDegrees = fetched.sourceRotationDegrees;
        entry.dateAddedSecs = fetched.dateAddedSecs ?? entry.dateAddedSecs;
        entry.dateModifiedMillis = fetched.dateModifiedMillis ?? entry.dateModifiedMillis;
        entry.sourceDateTakenMillis = fetched.sourceDateTakenMillis ?? entry.sourceDateTakenMillis;
        entry.durationMillis = fetched.durationMillis ?? entry.durationMillis;
      } else {
        await entry.catalog(background: false, force: true, persist: false);
      }
      if (entry.width <= 1 || entry.height <= 1) {
        await entry.catalog(background: false, force: true, persist: false);
      }
    } catch (error, stack) {
      await remoteMediaLogService.log(
        'lazy_load',
        'failed to refresh remote entry metadata',
        data: {
          'uri': entry.uri,
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
    }
  }

  Future<int> purgeIndexedRemoteCacheEntries() async {
    final entries = await localMediaDb.loadEntries(origin: EntryOrigins.mediaStoreContent);
    final remoteEntries = entries.where((entry) => entry.isRemoteCachedMedia).toSet();
    if (remoteEntries.isEmpty) return 0;

    final ids = remoteEntries.map((entry) => entry.id).toSet();
    await localMediaDb.removeIds(ids);
    await remoteMediaLogService.log(
      'remote_load',
      'purged indexed remote cache entries after policy change',
      data: {'count': remoteEntries.length},
    );
    return remoteEntries.length;
  }

  Future<void> syncCacheMediaScanPolicy() async {
    final externalCacheRoot = await storageService.getExternalCacheDirectory();
    if (externalCacheRoot.isEmpty) return;
    final remoteRoot = Directory('$externalCacheRoot${Platform.pathSeparator}remote');
    if (!await remoteRoot.exists()) {
      await remoteRoot.create(recursive: true);
    }
    await _applyNoMediaPolicy(remoteRoot);
  }

  Future<Directory> getConnectionCacheDirectory(String serverId) async {
    final externalCacheRoot = await storageService.getExternalCacheDirectory();
    final rootPath = externalCacheRoot.isNotEmpty ? externalCacheRoot : Directory.systemTemp.path;
    final remoteRoot = Directory('$rootPath${Platform.pathSeparator}remote');
    if (!await remoteRoot.exists()) {
      await remoteRoot.create(recursive: true);
    }
    await _applyNoMediaPolicy(remoteRoot);

    final dir = Directory('${remoteRoot.path}${Platform.pathSeparator}$serverId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _applyNoMediaPolicy(dir);
    return dir;
  }

  Future<int> getConnectionCacheBytes(String serverId) async {
    final dir = await getConnectionCacheDirectory(serverId);
    if (!await dir.exists()) return 0;

    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          bytes += await entity.length();
        } catch (_) {}
      }
    }
    return bytes;
  }

  Future<bool> clearConnectionCache(String serverId) async {
    final dir = await getConnectionCacheDirectory(serverId);
    if (!await dir.exists()) return true;
    try {
      await dir.delete(recursive: true);
      await remoteMediaLogService.log('remote_load', 'cleared remote cache for server', data: {'serverId': serverId});
      return true;
    } catch (error, stack) {
      await remoteMediaLogService.log('remote_load', 'failed to clear remote cache', data: {'serverId': serverId, 'error': '$error'});
      await reportService.recordError(error, stack);
      return false;
    }
  }

  Future<RemoteConnectionTestResult> testConnection(RemoteServer server) async {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return _testWebDav(server);
      case RemoteProtocol.ftp:
        return _testFtp(server);
      case RemoteProtocol.sftp:
        return _testSftp(server);
      case RemoteProtocol.smb:
        return _testSmb(server);
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
    if (streamMode == RemoteStreamMode.streamOnly && node.isVideo) {
      plan = const RemotePreviewPlan(
        streamFirst: true,
        shouldAutoDownload: false,
        allowDownloadFallback: false,
        reason: 'video_stream_only',
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

  Future<RemoteMediaResolveResult> resolveMedia({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final plan = await decidePreviewPlan(server: server, node: node);
    final cachedFile = await _getExistingCacheFile(server, node);
    if (cachedFile != null) {
      await remoteMediaLogService.log(
        'auto_download',
        'reuse cached remote media',
        data: {
          'server': server.name,
          'path': node.path,
          'file': cachedFile.path,
        },
      );
      return RemoteMediaResolveResult(
        streamUri: null,
        downloadedFile: cachedFile,
        plan: plan,
      );
    }

    final streamUri = buildStreamUri(server: server, node: node);
    File? downloadedFile;
    if (plan.shouldAutoDownload) {
      downloadedFile = await _autoDownload(server: server, node: node);
    } else if (streamUri == null && plan.allowDownloadFallback) {
      await remoteMediaLogService.log(
        'auto_download',
        'stream unavailable, triggering fallback download',
        data: {
          'server': server.name,
          'protocol': server.protocol.name,
          'path': node.path,
        },
      );
      downloadedFile = await _autoDownload(server: server, node: node);
    }
    return RemoteMediaResolveResult(
      streamUri: streamUri,
      downloadedFile: downloadedFile,
      plan: plan,
    );
  }

  Future<Map<String, Object?>> probeStreamUriHealth(String rawUri) async {
    final uri = Uri.tryParse(rawUri);
    if (uri == null) {
      return {'ok': false, 'reason': 'invalid_uri'};
    }
    if (!(uri.isScheme('http') || uri.isScheme('https'))) {
      return {'ok': false, 'reason': 'unsupported_scheme', 'scheme': uri.scheme};
    }

    final targetUri = uri.userInfo.isNotEmpty ? uri.replace(userInfo: '') : uri;
    final headers = <String, String>{
      'Range': 'bytes=0-1',
    };
    if (uri.userInfo.isNotEmpty) {
      final token = base64Encode(utf8.encode(uri.userInfo));
      headers['Authorization'] = 'Basic $token';
    }

    final client = http.Client();
    try {
      final req = http.Request('GET', targetUri)..headers.addAll(headers);
      final resp = await client.send(req).timeout(const Duration(seconds: 8));
      await resp.stream.drain<void>();
      return {
        'ok': resp.statusCode >= 200 && resp.statusCode < 400,
        'status': resp.statusCode,
        'reasonPhrase': resp.reasonPhrase,
        'contentType': resp.headers['content-type'],
        'contentLength': resp.headers['content-length'],
        'acceptRanges': resp.headers['accept-ranges'],
        'targetUri': targetUri.toString(),
      };
    } catch (error) {
      return {
        'ok': false,
        'reason': 'request_exception',
        'error': '$error',
        'targetUri': targetUri.toString(),
      };
    } finally {
      client.close();
    }
  }

  Future<File?> downloadMedia({
    required RemoteServer server,
    required RemoteBrowseNode node,
    String trigger = 'manual',
  }) async {
    await remoteMediaLogService.log(
      'auto_download',
      'download requested',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'trigger': trigger,
      },
    );
    return _autoDownload(server: server, node: node);
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

  Uri? buildStreamUri({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) {
    if (node.isVideo) {
      final proxyUri = remoteStreamProxyService.proxyUriForRemote(serverId: server.id, path: node.path);
      if (proxyUri != null) {
        final key = '${server.id}|${node.path}';
        if (_proxyLoggedUris.add(key)) {
          unawaited(
            remoteMediaLogService.log(
              'remote_load',
              'using unified local proxy uri for remote video stream',
              data: {
                'server': server.name,
                'protocol': server.protocol.name,
                'path': node.path,
                'proxyUri': proxyUri.toString(),
              },
            ),
          );
        }
        return proxyUri;
      }
      unawaited(remoteStreamProxyService.ensureStarted());
    }

    switch (server.protocol) {
      case RemoteProtocol.webdav:
        final base = server.webdavUrl;
        if (base == null || base.isEmpty) return null;
        var uri = _buildWebDavUri(base, _resolveEffectivePath(server, node.path));
        if (uri == null) return null;
        final username = server.username?.trim();
        final password = server.password;
        if (uri.userInfo.isEmpty && username != null && username.isNotEmpty && password != null) {
          uri = uri.replace(userInfo: '$username:$password');
        }
        return uri;
      case RemoteProtocol.ftp:
      case RemoteProtocol.sftp:
      case RemoteProtocol.smb:
        return null;
    }
  }

  Future<Map<String, Object?>> _fetchWebDavFileMetadata({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final base = server.webdavUrl;
    if (base == null || base.isEmpty) return const {};
    final targetUri = _buildWebDavUri(base, _resolveEffectivePath(server, node.path));
    if (targetUri == null) return const {};

    final client = http.Client();
    try {
      final headers = <String, String>{};
      final username = server.username;
      final password = server.password;
      if (username != null && password != null) {
        final token = base64Encode(utf8.encode('$username:$password'));
        headers['Authorization'] = 'Basic $token';
      }

      final response = await client.send(http.Request('HEAD', targetUri)..headers.addAll(headers)).timeout(const Duration(seconds: 8));
      await response.stream.drain<void>();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return {
          'sizeBytes': int.tryParse(response.headers['content-length'] ?? ''),
          'modifiedMillis': _parseHttpDateMillis(response.headers['last-modified']),
        };
      }
    } catch (_) {
      // ignore and fall back to list metadata
    } finally {
      client.close();
    }
    return const {};
  }

  String inferMimeType(RemoteBrowseNode node) {
    final lower = node.name.toLowerCase();
    for (final ext in _extensionToMimeType.keys) {
      if (lower.endsWith(ext)) {
        return _extensionToMimeType[ext]!;
      }
    }
    if (node.isImage) return MimeTypes.anyImage;
    if (node.isVideo) return MimeTypes.anyVideo;
    return 'application/octet-stream';
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
    <d:getcontentlength/>
    <d:getlastmodified/>
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
        final contentLengthText = node.findElements('getcontentlength', namespace: 'DAV:').firstOrNull?.innerText.trim();
        final contentLength = int.tryParse(contentLengthText ?? '');
        final modifiedText = node.findElements('getlastmodified', namespace: 'DAV:').firstOrNull?.innerText.trim();
        final modifiedMillis = _parseHttpDateMillis(modifiedText);

        final hrefName = decodedPath.split('/').where((v) => v.isNotEmpty).lastOrNull ?? decodedPath;
        final name = resourceType ? (displayName != null && displayName.isNotEmpty ? displayName : hrefName) : hrefName;
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
            sizeBytes: isDirectory ? null : contentLength,
            modifiedMillis: modifiedMillis,
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
          modifiedMillis: null,
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
          modifiedMillis: null,
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
        return shares.map((v) => RemoteBrowseNode(path: '/${v.name}', name: v.name, isDirectory: true, modifiedMillis: null)).toList()..sort(_compareNodes);
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
          modifiedMillis: null,
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

  Future<File?> _autoDownload({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    switch (server.protocol) {
      case RemoteProtocol.webdav:
        return _downloadWebDavFile(server: server, node: node);
      case RemoteProtocol.ftp:
        return _downloadFtpFile(server: server, node: node);
      case RemoteProtocol.sftp:
        return _downloadSftpFile(server: server, node: node);
      case RemoteProtocol.smb:
        return _downloadSmbFile(server: server, node: node);
    }
  }

  Future<RemoteProxyResponse?> _handleProxyRequest(RemoteProxyRequest request) async {
    final server = settings.remoteServers.byId(request.serverId);
    if (server == null) {
      await remoteMediaLogService.log(
        'stream',
        'proxy request skipped because remote server was not found',
        data: {
          'serverId': request.serverId,
          'path': request.path,
        },
      );
      return null;
    }

    final node = _findNodeForProxy(server, request.path);
    try {
      switch (server.protocol) {
        case RemoteProtocol.webdav:
          return await _proxyWebDav(server: server, node: node, request: request);
        case RemoteProtocol.ftp:
          return await _proxyCachedFile(server: server, node: node, request: request, reason: 'ftp_cache_backed_stream');
        case RemoteProtocol.sftp:
          return await _proxySftp(server: server, node: node, request: request);
        case RemoteProtocol.smb:
          return await _proxySmb(server: server, node: node, request: request);
      }
    } catch (error, stack) {
      await remoteMediaLogService.log(
        'stream',
        'remote proxy request failed',
        data: {
          'server': server.name,
          'protocol': server.protocol.name,
          'path': request.path,
          'method': request.method,
          'range': request.rangeHeader,
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
      return null;
    }
  }

  RemoteBrowseNode _findNodeForProxy(RemoteServer server, String path) {
    final match = _virtualRemoteRefs.values.firstWhereOrNull((ref) => ref.$1.id == server.id && ref.$2.path == path);
    if (match != null) return match.$2;
    final name = path.split('/').where((segment) => segment.isNotEmpty).lastOrNull ?? path;
    final lower = name.toLowerCase();
    return RemoteBrowseNode(
      path: path,
      name: name,
      isDirectory: false,
      isVideo: _videoExt.any(lower.endsWith),
      isImage: _imageExt.any(lower.endsWith),
    );
  }

  Future<RemoteProxyResponse> _proxyWebDav({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
  }) async {
    final base = server.webdavUrl;
    if (base == null || base.isEmpty) {
      throw StateError('Missing WebDAV URL');
    }
    final targetUri = _buildWebDavUri(base, _resolveEffectivePath(server, node.path));
    if (targetUri == null) {
      throw StateError('Invalid WebDAV target URI');
    }

    final metadata = await _fetchWebDavFileMetadata(server: server, node: node);
    final totalLength = (metadata['sizeBytes'] as int?) ?? node.sizeBytes ?? 0;
    final lastModified = _millisToDateTime((metadata['modifiedMillis'] as int?) ?? node.modifiedMillis);
    return _proxyChunkedRemote(
      server: server,
      node: node,
      request: request,
      totalLength: totalLength,
      lastModified: lastModified,
      fetchChunk: (chunkRange) => _fetchWebDavChunk(server: server, node: node, uri: targetUri, range: chunkRange),
    );
  }

  Future<RemoteProxyResponse> _proxySftp({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
  }) async {
    final host = server.host;
    final username = server.username;
    if (host == null || host.isEmpty || username == null || username.isEmpty) {
      throw StateError('Missing SFTP host or username');
    }

    final totalLength = node.sizeBytes ?? await _fetchSftpFileSize(server: server, path: node.path);
    return _proxyChunkedRemote(
      server: server,
      node: node,
      request: request,
      totalLength: totalLength,
      lastModified: _millisToDateTime(node.modifiedMillis),
      fetchChunk: (chunkRange) => _fetchSftpChunk(server: server, path: node.path, range: chunkRange),
    );
  }

  Future<RemoteProxyResponse> _proxySmb({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      throw StateError('Missing SMB host');
    }

    final totalLength = node.sizeBytes ?? await _fetchSmbFileSize(server: server, path: node.path);
    return _proxyChunkedRemote(
      server: server,
      node: node,
      request: request,
      totalLength: totalLength,
      lastModified: _millisToDateTime(node.modifiedMillis),
      fetchChunk: (chunkRange) => _fetchSmbChunk(server: server, path: node.path, range: chunkRange),
    );
  }

  Future<RemoteProxyResponse> _proxyCachedFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
    required String reason,
  }) async {
    final file = await _getExistingCacheFile(server, node) ?? await _autoDownload(server: server, node: node);
    if (file == null || !await file.exists()) {
      throw StateError('No cached file available for ${server.protocol.name}');
    }
    await remoteMediaLogService.log(
      'stream',
      'serving remote stream through local cache file',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'file': file.path,
        'reason': reason,
      },
    );
    return _serveLocalFile(file: file, mimeType: inferMimeType(node), rangeHeader: request.rangeHeader, method: request.method);
  }

  Future<RemoteProxyResponse> _serveLocalFile({
    required File file,
    required String mimeType,
    required String? rangeHeader,
    required String method,
  }) async {
    final totalLength = await file.length();
    final range = _resolveByteRange(rangeHeader, totalLength);
    final isPartial = rangeHeader != null && rangeHeader.isNotEmpty;
    return RemoteProxyResponse(
      statusCode: isPartial ? HttpStatus.partialContent : HttpStatus.ok,
      stream: method == 'HEAD' ? const Stream<List<int>>.empty() : file.openRead(range.start, range.endInclusive + 1),
      contentType: mimeType,
      contentLength: range.contentLength,
      totalLength: totalLength,
      contentRange: isPartial ? range.contentRangeHeader : null,
      lastModified: (await file.stat()).modified,
    );
  }

  RemoteByteRange _resolveByteRange(String? rangeHeader, int totalLength) {
    if (totalLength <= 0) {
      return const RemoteByteRange(start: 0, endInclusive: 0, totalLength: 0);
    }
    if (rangeHeader == null || rangeHeader.isEmpty || !rangeHeader.startsWith('bytes=')) {
      return RemoteByteRange(start: 0, endInclusive: totalLength - 1, totalLength: totalLength);
    }

    final spec = rangeHeader.substring('bytes='.length).split(',').first.trim();
    if (spec.isEmpty) {
      return RemoteByteRange(start: 0, endInclusive: totalLength - 1, totalLength: totalLength);
    }

    final parts = spec.split('-');
    final rawStart = parts.isNotEmpty ? parts[0].trim() : '';
    final rawEnd = parts.length > 1 ? parts[1].trim() : '';

    int start;
    int endInclusive;
    if (rawStart.isEmpty) {
      final suffixLength = int.tryParse(rawEnd) ?? totalLength;
      start = totalLength - suffixLength;
      endInclusive = totalLength - 1;
    } else {
      start = int.tryParse(rawStart) ?? 0;
      endInclusive = rawEnd.isEmpty ? totalLength - 1 : (int.tryParse(rawEnd) ?? (totalLength - 1));
    }

    start = start.clamp(0, totalLength - 1);
    endInclusive = endInclusive.clamp(start, totalLength - 1);
    return RemoteByteRange(start: start, endInclusive: endInclusive, totalLength: totalLength);
  }

  DateTime? _millisToDateTime(int? millis) => millis != null && millis > 0 ? DateTime.fromMillisecondsSinceEpoch(millis) : null;

  Future<RemoteProxyResponse> _proxyChunkedRemote({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
    required int totalLength,
    required DateTime? lastModified,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async {
    final fullCacheFile = await _getExistingCacheFile(server, node);
    if (fullCacheFile != null) {
      return _serveLocalFile(
        file: fullCacheFile,
        mimeType: inferMimeType(node),
        rangeHeader: request.rangeHeader,
        method: request.method,
      );
    }

    final range = _resolveByteRange(request.rangeHeader, totalLength);
    if (request.method == 'HEAD') {
      final isPartial = request.rangeHeader != null && request.rangeHeader!.isNotEmpty;
      return RemoteProxyResponse(
        statusCode: isPartial ? HttpStatus.partialContent : HttpStatus.ok,
        stream: const Stream<List<int>>.empty(),
        contentType: inferMimeType(node),
        contentLength: range.contentLength,
        totalLength: totalLength,
        contentRange: isPartial ? range.contentRangeHeader : null,
        lastModified: lastModified,
      );
    }

    final chunkFiles = await _ensureStreamChunkFiles(
      server: server,
      node: node,
      requestedRange: range,
      totalLength: totalLength,
      fetchChunk: fetchChunk,
    );
    unawaited(_tryMergeCompleteChunkCache(server: server, node: node, totalLength: totalLength));

    final isPartial = request.rangeHeader != null && request.rangeHeader!.isNotEmpty;
    return RemoteProxyResponse(
      statusCode: isPartial ? HttpStatus.partialContent : HttpStatus.ok,
      stream: _openChunkedRangeStream(chunkFiles: chunkFiles, requestedRange: range),
      contentType: inferMimeType(node),
      contentLength: range.contentLength,
      totalLength: totalLength,
      contentRange: isPartial ? range.contentRangeHeader : null,
      lastModified: lastModified,
    );
  }

  Future<List<_ChunkFileSegment>> _ensureStreamChunkFiles({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange requestedRange,
    required int totalLength,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async {
    final firstChunk = requestedRange.start ~/ _streamChunkSizeBytes;
    final lastChunk = requestedRange.endInclusive ~/ _streamChunkSizeBytes;
    final result = <_ChunkFileSegment>[];
    for (var chunkIndex = firstChunk; chunkIndex <= lastChunk; chunkIndex++) {
      final chunkStart = chunkIndex * _streamChunkSizeBytes;
      final chunkEnd = min(totalLength - 1, chunkStart + _streamChunkSizeBytes - 1);
      final chunkRange = RemoteByteRange(start: chunkStart, endInclusive: chunkEnd, totalLength: totalLength);
      final chunkFile = await _getOrCreateStreamChunkFile(server: server, node: node, range: chunkRange, fetchChunk: fetchChunk);
      result.add(_ChunkFileSegment(file: chunkFile, range: chunkRange));
    }
    return result;
  }

  Stream<List<int>> _openChunkedRangeStream({
    required List<_ChunkFileSegment> chunkFiles,
    required RemoteByteRange requestedRange,
  }) async* {
    for (final segment in chunkFiles) {
      final readStart = max(requestedRange.start, segment.range.start);
      final readEndInclusive = min(requestedRange.endInclusive, segment.range.endInclusive);
      if (readEndInclusive < readStart) continue;
      final localStart = readStart - segment.range.start;
      final localEndExclusive = readEndInclusive - segment.range.start + 1;
      yield* segment.file.openRead(localStart, localEndExclusive);
    }
  }

  Future<File> _getOrCreateStreamChunkFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange range,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async {
    final file = await _buildStreamChunkFile(server: server, node: node, range: range);
    if (await file.exists()) {
      final length = await file.length();
      if (length == range.contentLength) {
        await remoteMediaLogService.log(
          'cache',
          'stream chunk cache hit',
          data: {
            'server': server.name,
            'path': node.path,
            'start': range.start,
            'end': range.endInclusive,
            'file': file.path,
          },
        );
        return file;
      }
      await file.delete();
    }

    final bytes = await fetchChunk(range);
    await file.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await remoteMediaLogService.log(
      'cache',
      'stored remote stream chunk',
      data: {
        'server': server.name,
        'path': node.path,
        'start': range.start,
        'end': range.endInclusive,
        'bytes': bytes.length,
        'file': file.path,
      },
    );
    await _enforceCacheLimit(server.id, trigger: 'stream_chunk');
    return file;
  }

  Future<List<int>> _fetchWebDavChunk({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required Uri uri,
    required RemoteByteRange range,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers[HttpHeaders.rangeHeader] = 'bytes=${range.start}-${range.endInclusive}';
      final username = server.username;
      final password = server.password;
      if (username != null && password != null) {
        final token = base64Encode(utf8.encode('$username:$password'));
        request.headers[HttpHeaders.authorizationHeader] = 'Basic $token';
      }
      final response = await client.send(request);
      if (response.statusCode != HttpStatus.partialContent && response.statusCode != HttpStatus.ok) {
        throw StateError('WebDAV chunk request failed with ${response.statusCode}');
      }
      return response.stream.toBytes();
    } finally {
      client.close();
    }
  }

  Future<int> _fetchSftpFileSize({
    required RemoteServer server,
    required String path,
  }) async {
    final host = server.host;
    final username = server.username;
    if (host == null || host.isEmpty || username == null || username.isEmpty) {
      return 0;
    }
    final socket = await SSHSocket.connect(host, server.port ?? 22, timeout: const Duration(seconds: 8));
    final privateKeyText = server.sftpPrivateKey;
    final passphrase = server.sftpPassphrase;
    final identities = privateKeyText != null && privateKeyText.isNotEmpty ? SSHKeyPair.fromPem(privateKeyText, passphrase?.isNotEmpty == true ? passphrase : null) : null;
    final client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: () => server.password,
    );
    try {
      await client.authenticated.timeout(const Duration(seconds: 12));
      final sftp = await client.sftp();
      final file = await sftp.open(_resolveEffectivePath(server, path));
      try {
        final stat = await file.stat();
        return stat.size ?? 0;
      } finally {
        await file.close();
        sftp.close();
      }
    } finally {
      client.close();
    }
  }

  Future<List<int>> _fetchSftpChunk({
    required RemoteServer server,
    required String path,
    required RemoteByteRange range,
  }) async {
    final host = server.host;
    final username = server.username;
    if (host == null || host.isEmpty || username == null || username.isEmpty) {
      throw StateError('Missing SFTP host or username');
    }
    final socket = await SSHSocket.connect(host, server.port ?? 22, timeout: const Duration(seconds: 8));
    final privateKeyText = server.sftpPrivateKey;
    final passphrase = server.sftpPassphrase;
    final identities = privateKeyText != null && privateKeyText.isNotEmpty ? SSHKeyPair.fromPem(privateKeyText, passphrase?.isNotEmpty == true ? passphrase : null) : null;
    final client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: () => server.password,
    );
    try {
      await client.authenticated.timeout(const Duration(seconds: 12));
      final sftp = await client.sftp();
      final file = await sftp.open(_resolveEffectivePath(server, path));
      try {
        return await file.readBytes(length: range.contentLength, offset: range.start);
      } finally {
        await file.close();
        sftp.close();
      }
    } finally {
      client.close();
    }
  }

  Future<int> _fetchSmbFileSize({
    required RemoteServer server,
    required String path,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) return 0;
    final smb = await SmbConnect.connectAuth(
      host: host,
      username: server.username ?? '',
      password: server.password ?? '',
      domain: server.smbDomain ?? '',
    );
    try {
      final file = await smb.file(_resolveEffectivePath(server, path));
      return file.size;
    } finally {
      await smb.close();
    }
  }

  Future<List<int>> _fetchSmbChunk({
    required RemoteServer server,
    required String path,
    required RemoteByteRange range,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      throw StateError('Missing SMB host');
    }
    final smb = await SmbConnect.connectAuth(
      host: host,
      username: server.username ?? '',
      password: server.password ?? '',
      domain: server.smbDomain ?? '',
    );
    try {
      final file = await smb.file(_resolveEffectivePath(server, path));
      final stream = await smb.openRead(file, range.start, range.endInclusive + 1);
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        buffer.add(chunk);
      }
      return buffer.takeBytes();
    } finally {
      await smb.close();
    }
  }

  Future<File?> _downloadWebDavFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final targetUri = buildStreamUri(server: server, node: node);
    if (targetUri == null) return null;
    final cacheFile = await _getOrCreateCacheFile(server, node);

    final client = http.Client();
    try {
      final req = http.Request('GET', targetUri);
      final username = server.username;
      final password = server.password;
      if (username != null && password != null) {
        final token = base64Encode(utf8.encode('$username:$password'));
        req.headers['Authorization'] = 'Basic $token';
      }
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        await remoteMediaLogService.log('auto_download', 'download failed with status', data: {'server': server.name, 'path': node.path, 'status': resp.statusCode});
        return null;
      }
      await cacheFile.create(recursive: true);
      final sink = cacheFile.openWrite();
      await resp.stream.pipe(sink);
      await sink.close();
      await _scanDownloadedFileIfNeeded(server: server, node: node, cacheFile: cacheFile);
      await _enforceCacheLimit(server.id, trigger: 'webdav_download');
      await remoteMediaLogService.log('auto_download', 'download success', data: {'server': server.name, 'path': node.path, 'file': cacheFile.path});
      return cacheFile;
    } catch (error, stack) {
      await remoteMediaLogService.log('auto_download', 'download exception', data: {'server': server.name, 'path': node.path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return null;
    } finally {
      client.close();
    }
  }

  Future<File?> _downloadFtpFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) return null;
    final cacheFile = await _getOrCreateCacheFile(server, node);

    final ftp = FTPConnect(
      host,
      port: server.port ?? 21,
      user: server.ftpAnonymous ? 'anonymous' : (server.username ?? 'anonymous'),
      pass: server.ftpAnonymous ? 'anonymous@' : (server.password ?? ''),
      timeout: 30,
    );
    ftp.transferMode = server.ftpPassiveMode ? TransferMode.passive : TransferMode.active;
    try {
      final connected = await ftp.connect();
      if (!connected) return null;
      final effectivePath = _resolveEffectivePath(server, node.path);
      final slash = effectivePath.lastIndexOf('/');
      final parent = slash <= 0 ? '/' : effectivePath.substring(0, slash);
      final name = slash == -1 ? effectivePath : effectivePath.substring(slash + 1);
      final changed = await ftp.changeDirectory(parent);
      if (!changed || name.isEmpty) return null;
      final ok = await ftp.downloadFile(name, cacheFile);
      if (!ok) return null;
      await _scanDownloadedFileIfNeeded(server: server, node: node, cacheFile: cacheFile);
      await _enforceCacheLimit(server.id, trigger: 'ftp_download');
      await remoteMediaLogService.log('auto_download', 'ftp download success', data: {'server': server.name, 'path': node.path, 'file': cacheFile.path});
      return cacheFile;
    } catch (error, stack) {
      await remoteMediaLogService.log('auto_download', 'ftp download exception', data: {'server': server.name, 'path': node.path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return null;
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  Future<File?> _downloadSftpFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final host = server.host;
    final username = server.username;
    if (host == null || host.isEmpty || username == null || username.isEmpty) return null;
    final cacheFile = await _getOrCreateCacheFile(server, node);

    SSHClient? client;
    SftpClient? sftp;
    SftpFile? remoteFile;
    try {
      final socket = await SSHSocket.connect(host, server.port ?? 22, timeout: const Duration(seconds: 8));
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
      final effectivePath = _resolveEffectivePath(server, node.path);
      remoteFile = await sftp.open(effectivePath);
      final sink = cacheFile.openWrite();
      await remoteFile.read().forEach(sink.add);
      await sink.close();
      await _scanDownloadedFileIfNeeded(server: server, node: node, cacheFile: cacheFile);
      await _enforceCacheLimit(server.id, trigger: 'sftp_download');
      await remoteMediaLogService.log('auto_download', 'sftp download success', data: {'server': server.name, 'path': node.path, 'file': cacheFile.path});
      return cacheFile;
    } catch (error, stack) {
      await remoteMediaLogService.log('auto_download', 'sftp download exception', data: {'server': server.name, 'path': node.path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return null;
    } finally {
      await remoteFile?.close();
      sftp?.close();
      client?.close();
    }
  }

  Future<File?> _downloadSmbFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) return null;
    final cacheFile = await _getOrCreateCacheFile(server, node);
    SmbConnect? smb;
    IOSink? sink;
    try {
      smb = await SmbConnect.connectAuth(
        host: host,
        username: server.username ?? '',
        password: server.password ?? '',
        domain: server.smbDomain ?? '',
      );
      final effectivePath = _resolveEffectivePath(server, node.path);
      final remote = await smb.file(effectivePath);
      final stream = await smb.openRead(remote);
      sink = cacheFile.openWrite();
      await stream.forEach(sink.add);
      await sink.flush();
      await sink.close();
      await _scanDownloadedFileIfNeeded(server: server, node: node, cacheFile: cacheFile);
      await _enforceCacheLimit(server.id, trigger: 'smb_download');
      await remoteMediaLogService.log('auto_download', 'smb download success', data: {'server': server.name, 'path': node.path, 'file': cacheFile.path});
      return cacheFile;
    } catch (error, stack) {
      await remoteMediaLogService.log('auto_download', 'smb download exception', data: {'server': server.name, 'path': node.path, 'error': '$error'});
      await reportService.recordError(error, stack);
      return null;
    } finally {
      await sink?.close();
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

  Future<RemoteConnectionTestResult> _testFtp(RemoteServer server) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      return const RemoteConnectionTestResult(success: false, message: 'Missing host');
    }
    final watch = Stopwatch()..start();
    final ftp = FTPConnect(
      host,
      port: server.port ?? 21,
      user: server.ftpAnonymous ? 'anonymous' : (server.username ?? 'anonymous'),
      pass: server.ftpAnonymous ? 'anonymous@' : (server.password ?? ''),
      timeout: 12,
    );
    ftp.transferMode = server.ftpPassiveMode ? TransferMode.passive : TransferMode.active;
    try {
      final connected = await ftp.connect();
      if (!connected) {
        await remoteMediaLogService.log('remote_load', 'ftp test failed', data: {'server': server.name, 'host': host, 'port': server.port ?? 21});
        return const RemoteConnectionTestResult(success: false, message: 'FTP auth failed');
      }
      await ftp.currentDirectory();
      watch.stop();
      await remoteMediaLogService.log('remote_load', 'ftp test success', data: {'server': server.name, 'latencyMs': watch.elapsedMilliseconds, 'passive': server.ftpPassiveMode, 'anonymous': server.ftpAnonymous});
      return RemoteConnectionTestResult(
        success: true,
        message: 'FTP connected',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } catch (error) {
      watch.stop();
      await remoteMediaLogService.log('remote_load', 'ftp test exception', data: {'server': server.name, 'error': '$error', 'latencyMs': watch.elapsedMilliseconds});
      return RemoteConnectionTestResult(
        success: false,
        message: 'FTP error: $error',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  Future<RemoteConnectionTestResult> _testSftp(RemoteServer server) async {
    final host = server.host;
    final username = server.username;
    if (host == null || host.isEmpty) {
      return const RemoteConnectionTestResult(success: false, message: 'Missing host');
    }
    if (username == null || username.isEmpty) {
      return const RemoteConnectionTestResult(success: false, message: 'Missing username');
    }
    final watch = Stopwatch()..start();
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(host, server.port ?? 22, timeout: const Duration(seconds: 8));
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
      watch.stop();
      await remoteMediaLogService.log('remote_load', 'sftp test success', data: {'server': server.name, 'latencyMs': watch.elapsedMilliseconds});
      return RemoteConnectionTestResult(
        success: true,
        message: 'SFTP connected',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } catch (error) {
      watch.stop();
      await remoteMediaLogService.log('remote_load', 'sftp test exception', data: {'server': server.name, 'error': '$error', 'latencyMs': watch.elapsedMilliseconds});
      return RemoteConnectionTestResult(
        success: false,
        message: 'SFTP error: $error',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } finally {
      client?.close();
    }
  }

  Future<RemoteConnectionTestResult> _testSmb(RemoteServer server) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      return const RemoteConnectionTestResult(success: false, message: 'Missing host');
    }
    final watch = Stopwatch()..start();
    SmbConnect? smb;
    try {
      smb = await SmbConnect.connectAuth(
        host: host,
        username: server.username ?? '',
        password: server.password ?? '',
        domain: server.smbDomain ?? '',
      );
      await smb.listShares();
      watch.stop();
      await remoteMediaLogService.log('remote_load', 'smb test success', data: {'server': server.name, 'latencyMs': watch.elapsedMilliseconds});
      return RemoteConnectionTestResult(
        success: true,
        message: 'SMB connected',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } catch (error) {
      watch.stop();
      await remoteMediaLogService.log('remote_load', 'smb test exception', data: {'server': server.name, 'error': '$error', 'latencyMs': watch.elapsedMilliseconds});
      return RemoteConnectionTestResult(
        success: false,
        message: 'SMB error: $error',
        latencyMillis: watch.elapsedMilliseconds,
      );
    } finally {
      await smb?.close();
    }
  }

  Uri? _buildWebDavUri(String base, String path) {
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return null;
    final normalizedPath = path.trim().isEmpty ? '/' : path.trim();
    if (normalizedPath == '/' || normalizedPath == '.') return baseUri;
    final basePath = baseUri.path.endsWith('/') ? baseUri.path.substring(0, baseUri.path.length - 1) : baseUri.path;
    final normalizedNoSlash = normalizedPath.replaceFirst(RegExp(r'^/+'), '');
    final basePathNormalized = _normalizePath(basePath);
    final normalizedAsPath = _normalizePath(normalizedPath);
    final fullPath = normalizedAsPath == basePathNormalized || normalizedAsPath.startsWith('$basePathNormalized/') ? normalizedAsPath : '$basePath/$normalizedNoSlash';
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

  String _safeFileName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'remote_file';
    return trimmed.replaceAll(RegExp(r'[\\\\/:*?\"<>|]'), '_');
  }

  int _stableCacheKey(String value) {
    final data = utf8.encode(value);
    var hash = 0x811C9DC5;
    for (final b in data) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  Future<File> _buildCacheFile(RemoteServer server, RemoteBrowseNode node) async {
    final cacheDir = await getConnectionCacheDirectory(server.id);
    final cacheKey = _stableCacheKey('${server.id}|${node.path}|${node.name}');
    return File('${cacheDir.path}${Platform.pathSeparator}${_safeFileName(node.name)}_$cacheKey');
  }

  Future<Directory> _getStreamChunkDirectory(RemoteServer server, RemoteBrowseNode node) async {
    final cacheDir = await getConnectionCacheDirectory(server.id);
    final chunkKey = _stableCacheKey('${server.id}|${node.path}|chunks');
    final dir = Directory('${cacheDir.path}${Platform.pathSeparator}.chunks_$chunkKey');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _buildStreamChunkFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange range,
  }) async {
    final dir = await _getStreamChunkDirectory(server, node);
    return File('${dir.path}${Platform.pathSeparator}${range.start}_${range.endInclusive}.chunk');
  }

  Future<List<File>> _listStreamChunkFiles(RemoteServer server, RemoteBrowseNode node) async {
    final dir = await _getStreamChunkDirectory(server, node);
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.chunk')) {
        files.add(entity);
      }
    }
    return files;
  }

  RemoteByteRange? _parseChunkFileRange(File file, int totalLength) {
    final name = file.uri.pathSegments.last;
    final match = RegExp(r'^(\d+)_(\d+)\.chunk$').firstMatch(name);
    if (match == null) return null;
    final start = int.tryParse(match.group(1) ?? '');
    final endInclusive = int.tryParse(match.group(2) ?? '');
    if (start == null || endInclusive == null || endInclusive < start) return null;
    return RemoteByteRange(
      start: start,
      endInclusive: min(endInclusive, max(totalLength - 1, 0)),
      totalLength: totalLength,
    );
  }

  Future<File?> _getExistingCacheFile(RemoteServer server, RemoteBrowseNode node) async {
    final cacheFile = await _buildCacheFile(server, node);
    if (await cacheFile.exists() && await cacheFile.length() > 0) {
      return cacheFile;
    }
    return null;
  }

  Future<File?> getExistingCacheFile(RemoteServer server, RemoteBrowseNode node) => _getExistingCacheFile(server, node);

  Future<File> _getOrCreateCacheFile(RemoteServer server, RemoteBrowseNode node) async {
    final cacheFile = await _getExistingCacheFile(server, node) ?? await _buildCacheFile(server, node);
    if (await cacheFile.exists() && await cacheFile.length() > 0) {
      await remoteMediaLogService.log('auto_download', 'cache hit', data: {'server': server.name, 'path': node.path, 'file': cacheFile.path});
      return cacheFile;
    }
    await cacheFile.create(recursive: true);
    return cacheFile;
  }

  Future<void> _scanDownloadedFileIfNeeded({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required File cacheFile,
  }) async {
    if (!settings.remoteCacheInSmartCollections) return;
    final mimeType = inferMimeType(node);
    try {
      final uri = await mediaStoreService.scanFile(cacheFile.path, mimeType);
      await remoteMediaLogService.log(
        'remote_load',
        'scanned remote cache file for smart collections',
        data: {
          'server': server.name,
          'path': node.path,
          'file': cacheFile.path,
          'mimeType': mimeType,
          'uri': uri?.toString(),
        },
      );
    } catch (error, stack) {
      await remoteMediaLogService.log(
        'remote_load',
        'failed to scan remote cache file',
        data: {
          'server': server.name,
          'path': node.path,
          'file': cacheFile.path,
          'mimeType': mimeType,
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
    }
  }

  Future<void> _applyNoMediaPolicy(Directory targetDir) async {
    final noMediaFile = File('${targetDir.path}${Platform.pathSeparator}.nomedia');
    if (!settings.remoteCacheInSmartCollections) {
      if (!await noMediaFile.exists()) {
        await noMediaFile.writeAsString('');
        await remoteMediaLogService.log(
          'remote_load',
          'created .nomedia for remote cache',
          data: {'dir': targetDir.path},
        );
      }
    } else {
      if (await noMediaFile.exists()) {
        await noMediaFile.delete();
        await remoteMediaLogService.log(
          'remote_load',
          'removed .nomedia for remote cache',
          data: {'dir': targetDir.path},
        );
      }
    }
  }

  Future<void> _tryMergeCompleteChunkCache({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required int totalLength,
  }) async {
    if (totalLength <= 0) return;
    final fullFile = await _buildCacheFile(server, node);
    if (await fullFile.exists() && await fullFile.length() == totalLength) return;

    final chunkFiles = await _listStreamChunkFiles(server, node);
    if (chunkFiles.isEmpty) return;
    final ranges = chunkFiles.map((file) => (file: file, range: _parseChunkFileRange(file, totalLength))).where((item) => item.range != null).map((item) => _ChunkFileSegment(file: item.file, range: item.range!)).toList()
      ..sort((a, b) => a.range.start.compareTo(b.range.start));
    if (ranges.isEmpty) return;

    var expectedStart = 0;
    for (final item in ranges) {
      final actualLength = await item.file.length();
      if (actualLength != item.range.contentLength) return;
      if (item.range.start != expectedStart) return;
      expectedStart = item.range.endInclusive + 1;
    }
    if (expectedStart < totalLength) return;

    final tempFile = File('${fullFile.path}.merging');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    await tempFile.create(recursive: true);
    final sink = tempFile.openWrite();
    try {
      for (final item in ranges) {
        await item.file.openRead().forEach(sink.add);
      }
      await sink.flush();
      await sink.close();
      final mergedLength = await tempFile.length();
      if (mergedLength == totalLength) {
        if (await fullFile.exists()) {
          await fullFile.delete();
        }
        await tempFile.rename(fullFile.path);
        await remoteMediaLogService.log(
          'cache',
          'merged complete remote stream chunks into full cache file',
          data: {
            'server': server.name,
            'path': node.path,
            'file': fullFile.path,
            'bytes': mergedLength,
            'chunkCount': ranges.length,
          },
        );
      } else {
        await tempFile.delete();
      }
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }
  }

  Future<void> _enforceCacheLimit(String serverId, {required String trigger}) async {
    final maxBytes = settings.remoteCacheMaxBytes;
    if (maxBytes <= 0) return;
    final dir = await getConnectionCacheDirectory(serverId);
    if (!await dir.exists()) return;

    final files = <File>[];
    var totalBytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('${Platform.pathSeparator}.nomedia')) continue;
      try {
        final length = await entity.length();
        if (length <= 0) continue;
        files.add(entity);
        totalBytes += length;
      } catch (_) {}
    }
    if (totalBytes <= maxBytes) return;

    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

    var deletedCount = 0;
    for (final file in files) {
      if (totalBytes <= maxBytes) break;
      try {
        final length = await file.length();
        await file.delete();
        totalBytes -= length;
        deletedCount++;
      } catch (_) {}
    }

    if (deletedCount > 0) {
      await remoteMediaLogService.log(
        'cache',
        'pruned remote cache because max size was exceeded',
        data: {
          'serverId': serverId,
          'trigger': trigger,
          'maxBytes': maxBytes,
          'remainingBytes': totalBytes,
          'deletedCount': deletedCount,
        },
      );
    }
  }

  static const _videoExt = ['.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.ts'];
  static const _imageExt = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.bmp', '.tiff', '.avif', '.svg'];
  static const Map<String, String> _extensionToMimeType = {
    '.jpg': MimeTypes.jpeg,
    '.jpeg': MimeTypes.jpeg,
    '.png': MimeTypes.png,
    '.webp': MimeTypes.webp,
    '.gif': MimeTypes.gif,
    '.heic': MimeTypes.heic,
    '.bmp': MimeTypes.bmp,
    '.tiff': MimeTypes.tiff,
    '.avif': MimeTypes.avif,
    '.svg': MimeTypes.svg,
    '.mp4': MimeTypes.mp4,
    '.mkv': MimeTypes.mkv,
    '.mov': MimeTypes.mov,
    '.avi': MimeTypes.avi,
    '.webm': MimeTypes.webm,
    '.m4v': MimeTypes.mp4,
    '.ts': MimeTypes.mp2t,
  };
}
