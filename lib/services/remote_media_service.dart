// ignore_for_file: implementation_imports, unawaited_futures

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
import 'package:ftpconnect/src/ftp_reply.dart';
import 'package:ftpconnect/src/ftp_socket.dart';
import 'package:ftpconnect/src/utils.dart';
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

  RemoteBrowseNode copyWith({
    String? path,
    String? name,
    bool? isDirectory,
    bool? isVideo,
    bool? isImage,
    int? sizeBytes,
    int? modifiedMillis,
    bool preserveExistingSizeBytes = true,
    bool preserveExistingModifiedMillis = true,
  }) {
    return RemoteBrowseNode(
      path: path ?? this.path,
      name: name ?? this.name,
      isDirectory: isDirectory ?? this.isDirectory,
      isVideo: isVideo ?? this.isVideo,
      isImage: isImage ?? this.isImage,
      sizeBytes: sizeBytes ?? (preserveExistingSizeBytes ? this.sizeBytes : null),
      modifiedMillis: modifiedMillis ?? (preserveExistingModifiedMillis ? this.modifiedMillis : null),
    );
  }
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
  static const _smbStreamChunkSizeBytes = 4 * 1024 * 1024;
  static const _streamChunkCacheVersion = 4;
  static const _streamChunkPrefetchCount = 2;
  static const _previewInitialWarmupChunkCount = 1;
  static const _viewerInitialWarmupChunkCount = 2;
  final Map<String, (RemoteServer server, RemoteBrowseNode node)> _virtualRemoteRefs = {};
  final Map<String, Future<File?>> _downloadInFlight = {};
  final Set<String> _cacheWarmupKeys = {};
  final Map<String, (String uri, int expiresAtMillis)> _playbackUriCache = {};
  final Set<String> _proxyLoggedUris = {};
  final Map<String, Future<File>> _streamChunkInFlight = {};
  final Set<String> _loggedInitialChunkSignatures = {};

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

  int _chunkSizeForProtocol(RemoteProtocol protocol) {
    switch (protocol) {
      case RemoteProtocol.smb:
        return _smbStreamChunkSizeBytes;
      case RemoteProtocol.webdav:
      case RemoteProtocol.ftp:
      case RemoteProtocol.sftp:
        return _streamChunkSizeBytes;
    }
  }

  int _initialWarmupChunkCount({
    required RemoteProtocol protocol,
    required String trigger,
  }) {
    final normalizedTrigger = trigger.toLowerCase();
    if (normalizedTrigger.contains('grid_preview')) {
      return _previewInitialWarmupChunkCount;
    }
    if (normalizedTrigger.contains('viewer_init') || normalizedTrigger.contains('viewer_autoplay')) {
      return _viewerInitialWarmupChunkCount;
    }
    return switch (protocol) {
      RemoteProtocol.webdav => 1,
      RemoteProtocol.ftp || RemoteProtocol.sftp || RemoteProtocol.smb => _viewerInitialWarmupChunkCount,
    };
  }

  int _prefetchChunkCountForRequest({
    required RemoteProtocol protocol,
    required RemoteByteRange requestedRange,
    required int totalLength,
  }) {
    final requestedLength = requestedRange.contentLength;
    final chunkSize = _chunkSizeForProtocol(protocol);
    if (requestedLength <= 0 || totalLength <= 0) {
      return 0;
    }
    final isProbeLikeRequest = requestedRange.start > 0 && requestedLength <= chunkSize;
    if (isProbeLikeRequest) {
      return 0;
    }
    final isOpenHeadRequest = requestedRange.start == 0 && requestedRange.endInclusive == totalLength - 1;
    if (isOpenHeadRequest) {
      return 1;
    }
    return 1;
  }

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

    final downloadKey = '${ref.$1.id}|${ref.$2.path}';
    final inFlight = _downloadInFlight[downloadKey];
    if (inFlight != null) {
      await remoteMediaLogService.log(
        'auto_download',
        'await existing remote download task',
        data: {
          'trigger': trigger,
          'uri': sourceUri,
          'server': ref.$1.name,
          'protocol': ref.$1.protocol.name,
          'path': ref.$2.path,
        },
      );
      final existingFile = await inFlight;
      if (existingFile == null) return null;
      final fileUri = Uri.file(existingFile.path).toString();
      entry.uri = fileUri;
      entry.path = existingFile.path;
      entry.sizeBytes = await existingFile.length();
      _virtualRemoteRefs[fileUri] = ref;
      await _refreshEntryMetadataFromLocalFile(entry, fileUri);
      entry.visualChangeNotifier.notify();
      return existingFile;
    }

    Future<File?> runDownload() async {
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
    }

    final task = Future<File?>(runDownload);
    _downloadInFlight[downloadKey] = task;
    try {
      return await task;
    } finally {
      _downloadInFlight.remove(downloadKey);
    }
  }

  (RemoteServer server, RemoteBrowseNode node)? getVirtualRemoteRef(String uri) => _virtualRemoteRefs[uri];

  RemoteProtocol? getRemoteProtocolForEntry(AvesEntry entry) => _virtualRemoteRefs[entry.uri]?.$1.protocol;

  Future<File?> bindExistingCacheFileForEntry(
    AvesEntry entry, {
    String trigger = 'remote_entry_bind_existing_cache',
  }) async {
    final sourceUri = entry.uri;
    final ref = _virtualRemoteRefs[sourceUri];
    if (ref == null) return null;

    final file = await _getExistingCacheFile(ref.$1, ref.$2);
    if (file == null) return null;

    final fileUri = Uri.file(file.path).toString();
    if (entry.uri == fileUri && entry.path == file.path) {
      return file;
    }

    entry.uri = fileUri;
    entry.path = file.path;
    entry.sizeBytes = await file.length();
    _virtualRemoteRefs[fileUri] = ref;
    await _refreshEntryMetadataFromLocalFile(entry, fileUri);
    entry.visualChangeNotifier.notify();
    await remoteMediaLogService.log(
      'auto_download',
      'entry switched to existing cached file',
      data: {
        'trigger': trigger,
        'fromUri': sourceUri,
        'toFile': file.path,
        'server': ref.$1.name,
        'protocol': ref.$1.protocol.name,
        'path': ref.$2.path,
      },
    );
    return file;
  }

  Future<File?> prepareEntryForPlayback(
    AvesEntry entry, {
    required String trigger,
    bool allowDownload = false,
  }) async {
    final ref = _virtualRemoteRefs[entry.uri];
    if (ref == null || !entry.isVideo) return null;

    final server = ref.$1;
    if (server.protocol == RemoteProtocol.webdav) {
      return bindExistingCacheFileForEntry(entry, trigger: '${trigger}_bind_existing');
    }

    final existing = await bindExistingCacheFileForEntry(entry, trigger: '${trigger}_bind_existing');
    if (existing != null) {
      return existing;
    }
    if (!allowDownload) return null;

    return ensureDownloadedForEntry(entry, trigger: '${trigger}_download');
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

  Future<RemoteBrowseNode> ensureNodeMetadata(
    RemoteServer server,
    RemoteBrowseNode node, {
    String trigger = 'node_prepare',
  }) async {
    var sizeBytes = node.sizeBytes;
    var modifiedMillis = node.modifiedMillis;

    final cachedFile = await _getExistingCacheFile(server, node);
    if (cachedFile != null) {
      try {
        final stat = await cachedFile.stat();
        final localLength = stat.size;
        if (localLength > 0) {
          sizeBytes = localLength;
        }
        final localModifiedMillis = stat.modified.millisecondsSinceEpoch;
        if (localModifiedMillis > 0) {
          modifiedMillis = localModifiedMillis;
        }
      } catch (_) {
        // ignore local stat issues and keep trying remote metadata below
      }
    }

    if (server.protocol == RemoteProtocol.webdav && (sizeBytes == null || modifiedMillis == null || sizeBytes <= 0)) {
      final metadata = await _fetchWebDavFileMetadata(server: server, node: node);
      final remoteSizeBytes = metadata['sizeBytes'] as int?;
      final remoteModifiedMillis = metadata['modifiedMillis'] as int?;
      if (remoteSizeBytes != null && remoteSizeBytes > 0) {
        sizeBytes = remoteSizeBytes;
      }
      if (remoteModifiedMillis != null && remoteModifiedMillis > 0) {
        modifiedMillis = remoteModifiedMillis;
      }
    }

    final enrichedNode = node.copyWith(
      sizeBytes: sizeBytes,
      modifiedMillis: modifiedMillis,
    );
    await remoteMediaLogService.log(
      'metadata',
      'prepared remote node metadata',
      data: {
        'trigger': trigger,
        'server': server.name,
        'path': node.path,
        'sizeBytes': enrichedNode.sizeBytes,
        'modifiedMillis': enrichedNode.modifiedMillis,
        'usedCachedFile': cachedFile != null,
      },
    );
    return enrichedNode;
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

  Future<void> prepareInitialStreamPlaybackForEntry(
    AvesEntry entry, {
    String trigger = 'stream_playback_prepare',
  }) async {
    if (!entry.isVideo) return;
    final ref = _virtualRemoteRefs[entry.uri];
    if (ref == null) return;

    final server = ref.$1;
    final node = ref.$2;
    if (server.protocol == RemoteProtocol.webdav || !_shouldPreferStreamOverCachedFile(server, node)) {
      return;
    }

    final totalLength = node.sizeBytes;
    if (totalLength == null || totalLength <= 0) {
      return;
    }

    final warmupKey = 'stream_prepare|${server.id}|${node.path}';
    if (_cacheWarmupKeys.contains(warmupKey)) return;
    _cacheWarmupKeys.add(warmupKey);
    try {
      await remoteMediaLogService.log(
        'stream',
        'prepare initial remote stream chunks for playback',
        data: {
          'trigger': trigger,
          'server': server.name,
          'protocol': server.protocol.name,
          'path': node.path,
          'sizeBytes': totalLength,
        },
      );

      final initialChunkCount = _initialWarmupChunkCount(
        protocol: server.protocol,
        trigger: trigger,
      );
      final chunkSize = _chunkSizeForProtocol(server.protocol);
      final ranges = <RemoteByteRange>[
        for (var chunkIndex = 0; chunkIndex < initialChunkCount; chunkIndex++)
          if (chunkIndex * chunkSize < totalLength)
            RemoteByteRange(
              start: chunkIndex * chunkSize,
              endInclusive: min(totalLength - 1, ((chunkIndex + 1) * chunkSize) - 1),
              totalLength: totalLength,
            ),
      ];

      if (totalLength > chunkSize) {
        final tailStart = max(0, totalLength - chunkSize);
        if (!ranges.any((range) => range.start == tailStart && range.endInclusive == totalLength - 1)) {
          ranges.add(
            RemoteByteRange(
              start: tailStart,
              endInclusive: totalLength - 1,
              totalLength: totalLength,
            ),
          );
        }
      }

      Future<List<int>> Function(RemoteByteRange range)? fetchChunk;
      switch (server.protocol) {
        case RemoteProtocol.webdav:
          fetchChunk = null;
        case RemoteProtocol.ftp:
          fetchChunk = (range) => _fetchFtpChunk(server: server, path: node.path, range: range);
        case RemoteProtocol.sftp:
          fetchChunk = (range) => _fetchSftpChunk(server: server, path: node.path, range: range);
        case RemoteProtocol.smb:
          fetchChunk = (range) => _fetchSmbChunk(server: server, path: node.path, range: range);
      }
      if (fetchChunk == null) {
        _cacheWarmupKeys.remove(warmupKey);
        return;
      }
      if (ranges.isEmpty) {
        _cacheWarmupKeys.remove(warmupKey);
        return;
      }

      final immediateRange = ranges.first;
      await _getOrCreateStreamChunkFile(
        server: server,
        node: node,
        range: immediateRange,
        fetchChunk: fetchChunk,
      );

      final backgroundRanges = ranges.skip(1).toList();
      if (backgroundRanges.isNotEmpty) {
        unawaited(
          Future.wait([
                for (final range in backgroundRanges)
                  _getOrCreateStreamChunkFile(
                    server: server,
                    node: node,
                    range: range,
                    fetchChunk: fetchChunk,
                  ),
              ])
              .then((_) async {
                await remoteMediaLogService.log(
                  'stream',
                  'prepared remaining remote stream warmup chunks in background',
                  data: {
                    'trigger': trigger,
                    'server': server.name,
                    'protocol': server.protocol.name,
                    'path': node.path,
                    'backgroundRanges': backgroundRanges.map((range) => '${range.start}-${range.endInclusive}').toList(),
                  },
                );
              })
              .catchError((error, stack) async {
                await remoteMediaLogService.log(
                  'stream',
                  'failed to prepare background remote stream warmup chunks',
                  data: {
                    'trigger': trigger,
                    'server': server.name,
                    'protocol': server.protocol.name,
                    'path': node.path,
                    'error': '$error',
                  },
                );
                await reportService.recordError(error, stack);
              })
              .whenComplete(() {
                _cacheWarmupKeys.remove(warmupKey);
              }),
        );
      } else {
        _cacheWarmupKeys.remove(warmupKey);
      }

      await remoteMediaLogService.log(
        'stream',
        'prepared immediate remote stream warmup chunk for playback',
        data: {
          'trigger': trigger,
          'server': server.name,
          'protocol': server.protocol.name,
          'path': node.path,
          'immediateRange': '${immediateRange.start}-${immediateRange.endInclusive}',
          'backgroundRangeCount': backgroundRanges.length,
          'allRanges': ranges.map((range) => '${range.start}-${range.endInclusive}').toList(),
        },
      );
    } catch (error, stack) {
      _cacheWarmupKeys.remove(warmupKey);
      await remoteMediaLogService.log(
        'stream',
        'failed to prepare initial remote stream chunks for playback',
        data: {
          'trigger': trigger,
          'server': server.name,
          'protocol': server.protocol.name,
          'path': node.path,
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
      rethrow;
    }
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

  Future<int> getPinnedFolderCacheBytes({
    required RemoteServer server,
    required String folderPath,
  }) async {
    final files = await _collectCacheFilesForPinnedFolder(server: server, folderPath: folderPath);
    var bytes = 0;
    for (final file in files) {
      try {
        bytes += await file.length();
      } catch (_) {}
    }
    return bytes;
  }

  Future<bool> clearPinnedFolderCache({
    required RemoteServer server,
    required String folderPath,
  }) async {
    try {
      final files = await _collectCacheFilesForPinnedFolder(server: server, folderPath: folderPath);
      var deleted = 0;
      for (final file in files) {
        try {
          if (await file.exists()) {
            await file.delete();
            deleted++;
          }
        } catch (_) {}
      }
      await remoteMediaLogService.log(
        'cache',
        'cleared pinned folder cache',
        data: {
          'server': server.name,
          'path': folderPath,
          'deletedCount': deleted,
        },
      );
      return true;
    } catch (error, stack) {
      await remoteMediaLogService.log(
        'cache',
        'failed to clear pinned folder cache',
        data: {
          'server': server.name,
          'path': folderPath,
          'error': '$error',
        },
      );
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
    final preferStreamOverCache = _shouldPreferStreamOverCachedFile(server, node);
    if (cachedFile != null && !preferStreamOverCache) {
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
    if (cachedFile != null && preferStreamOverCache && streamUri != null) {
      await remoteMediaLogService.log(
        'stream',
        'prefer remote stream over cached file for playback',
        data: {
          'server': server.name,
          'protocol': server.protocol.name,
          'path': node.path,
          'cachedFile': cachedFile.path,
          'streamUri': streamUri.toString(),
        },
      );
    }
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
      final summary = <String, Object?>{
        'server': server.name,
        'path': node.path,
        'uri': targetUri.toString(),
      };
      final headers = <String, String>{};
      final username = server.username;
      final password = server.password;
      if (username != null && password != null) {
        final token = base64Encode(utf8.encode('$username:$password'));
        headers['Authorization'] = 'Basic $token';
      }

      final headResponse = await client.send(http.Request('HEAD', targetUri)..headers.addAll(headers)).timeout(const Duration(seconds: 8));
      await headResponse.stream.drain<void>();
      final headSize = int.tryParse(headResponse.headers['content-length'] ?? '');
      final headModified = _parseHttpDateMillis(headResponse.headers['last-modified']);
      await remoteMediaLogService.log(
        'metadata',
        'webdav file metadata via head',
        data: {
          ...summary,
          'status': headResponse.statusCode,
          'sizeBytes': headSize,
          'modifiedMillis': headModified,
        },
      );
      if (headResponse.statusCode >= 200 && headResponse.statusCode < 300 && (headSize != null || headModified != null)) {
        return {
          'sizeBytes': headSize,
          'modifiedMillis': headModified,
        };
      }

      final propfindHeaders = <String, String>{
        ...headers,
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      };
      const propfindBody = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:getcontenttype/>
  </d:prop>
</d:propfind>''';
      final propfindResponse = await client
          .send(
            http.Request('PROPFIND', targetUri)
              ..headers.addAll(propfindHeaders)
              ..body = propfindBody,
          )
          .timeout(const Duration(seconds: 8));
      final propfindText = await propfindResponse.stream.bytesToString();
      int? propfindSize;
      int? propfindModified;
      if (propfindResponse.statusCode == 207 || propfindResponse.statusCode == 200) {
        final doc = XmlDocument.parse(propfindText);
        final responseNode = doc.findAllElements('response', namespace: 'DAV:').firstOrNull;
        if (responseNode != null) {
          propfindSize = int.tryParse(_findDavValue(responseNode, 'getcontentlength') ?? '');
          propfindModified = _parseHttpDateMillis(_findDavValue(responseNode, 'getlastmodified'));
        }
      }
      await remoteMediaLogService.log(
        'metadata',
        'webdav file metadata via propfind',
        data: {
          ...summary,
          'status': propfindResponse.statusCode,
          'sizeBytes': propfindSize,
          'modifiedMillis': propfindModified,
        },
      );
      if (propfindSize != null || propfindModified != null) {
        return {
          'sizeBytes': propfindSize,
          'modifiedMillis': propfindModified,
        };
      }
    } catch (error) {
      await remoteMediaLogService.log(
        'metadata',
        'webdav file metadata lookup failed',
        data: {
          'server': server.name,
          'path': node.path,
          'uri': targetUri.toString(),
          'error': '$error',
        },
      );
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
        final hrefText = _findDavValue(node, 'href');
        if (hrefText == null || hrefText.isEmpty) continue;
        final hrefUri = Uri.tryParse(hrefText);
        final decodedPath = Uri.decodeFull((hrefUri?.path ?? hrefText).trim());
        if (decodedPath.isEmpty) continue;

        if (_normalizePath(decodedPath) == _normalizePath(path) || _normalizePath(decodedPath) == _normalizePath(targetUri.path)) {
          continue;
        }

        final displayName = _findDavValue(node, 'displayname')?.trim();
        final resourceType = node.findAllElements('collection', namespace: 'DAV:').isNotEmpty;
        final contentType = (_findDavValue(node, 'getcontenttype') ?? '').toLowerCase();
        final contentLengthText = _findDavValue(node, 'getcontentlength')?.trim();
        final contentLength = int.tryParse(contentLengthText ?? '');
        final modifiedText = _findDavValue(node, 'getlastmodified')?.trim();
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
      } else {
        final missingSizeCount = out.where((v) => !v.isDirectory && v.sizeBytes == null).length;
        await remoteMediaLogService.log(
          'metadata',
          'webdav list metadata summary',
          data: {
            'uri': targetUri.toString(),
            'responseCount': responses.length,
            'itemCount': out.length,
            'missingSizeCount': missingSizeCount,
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
          modifiedMillis: _dateTimeToMillis(v.modifyTime),
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
      var list = await sftp.listdir(targetPath);
      if (list.isEmpty && targetPath != '/' && !targetPath.endsWith('/')) {
        final retryPath = '$targetPath/';
        await remoteMediaLogService.log(
          'remote_load',
          'retry sftp list with trailing slash',
          data: {
            'server': server.name,
            'path': path,
            'targetPath': targetPath,
            'retryPath': retryPath,
          },
        );
        list = await sftp.listdir(retryPath);
      }

      final out = list.where((v) => v.filename != '.' && v.filename != '..').map((v) {
        final name = v.filename.trim().isNotEmpty ? v.filename : _deriveSftpFallbackName(v.longname);
        final longName = v.longname.toLowerCase();
        final isDirectory = v.attr.isDirectory || longName.startsWith('d');
        final lower = name.toLowerCase();
        return RemoteBrowseNode(
          path: _joinRemotePath(path, name),
          name: name,
          isDirectory: isDirectory,
          isVideo: !isDirectory && _videoExt.any(lower.endsWith),
          isImage: !isDirectory && _imageExt.any(lower.endsWith),
          sizeBytes: isDirectory ? null : v.attr.size,
          modifiedMillis: _secondsToMillis(v.attr.modifyTime),
        );
      }).toList()..sort(_compareNodes);
      await remoteMediaLogService.log(
        'remote_load',
        'loaded sftp folder metadata',
        data: {
          'server': server.name,
          'path': path,
          'targetPath': targetPath,
          'rawCount': list.length,
          'children': out.length,
          'mediaCount': out.where((v) => !v.isDirectory && (v.isImage || v.isVideo)).length,
          'missingModifiedCount': out.where((v) => v.modifiedMillis == null).length,
        },
      );
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
          modifiedMillis: _normalizeSmbMillis(v.lastModified),
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
          return await _proxyFtp(server: server, node: node, request: request);
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

    await remoteMediaLogService.log(
      'stream',
      'serve webdav stream through direct passthrough proxy',
      data: {
        'server': server.name,
        'path': node.path,
        'method': request.method,
        'range': request.rangeHeader,
      },
    );
    return _proxyWebDavPassthrough(
      server: server,
      node: node,
      request: request,
      targetUri: targetUri,
    );
  }

  Future<RemoteProxyResponse> _proxyWebDavPassthrough({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
    required Uri targetUri,
  }) async {
    final headers = <String, String>{};
    final username = server.username;
    final password = server.password;
    if (username != null && password != null) {
      final token = base64Encode(utf8.encode('$username:$password'));
      headers[HttpHeaders.authorizationHeader] = 'Basic $token';
    }
    if (request.method != 'HEAD' && request.rangeHeader != null && request.rangeHeader!.isNotEmpty) {
      headers[HttpHeaders.rangeHeader] = request.rangeHeader!;
    }

    final client = http.Client();
    final upstreamRequest = http.Request(request.method, targetUri)..headers.addAll(headers);
    final upstreamResponse = await client.send(upstreamRequest);

    Stream<List<int>> stream() async* {
      try {
        if (request.method != 'HEAD') {
          await for (final chunk in upstreamResponse.stream) {
            yield chunk;
          }
        }
      } finally {
        client.close();
      }
    }

    return RemoteProxyResponse(
      statusCode: upstreamResponse.statusCode,
      stream: request.method == 'HEAD' ? const Stream<List<int>>.empty() : stream(),
      contentType: upstreamResponse.headers[HttpHeaders.contentTypeHeader] ?? inferMimeType(node),
      contentLength: int.tryParse(upstreamResponse.headers[HttpHeaders.contentLengthHeader] ?? ''),
      totalLength: int.tryParse(upstreamResponse.headers[HttpHeaders.contentLengthHeader] ?? ''),
      contentRange: upstreamResponse.headers[HttpHeaders.contentRangeHeader],
      lastModified: _parseHeaderHttpDate(upstreamResponse.headers[HttpHeaders.lastModifiedHeader]),
      acceptRanges: (upstreamResponse.headers[HttpHeaders.acceptRangesHeader] ?? '').toLowerCase() == 'bytes',
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
    await remoteMediaLogService.log(
      'stream',
      'proxying remote stream through chunked backend',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'method': request.method,
        'range': request.rangeHeader,
        'sizeBytes': totalLength,
      },
    );
    return _proxyChunkedRemote(
      server: server,
      node: node,
      request: request,
      totalLength: totalLength,
      lastModified: _millisToDateTime(node.modifiedMillis),
      fetchChunk: (chunkRange) => _fetchSftpChunk(server: server, path: node.path, range: chunkRange),
    );
  }

  Future<RemoteProxyResponse> _proxyFtp({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      throw StateError('Missing FTP host');
    }

    final totalLength = node.sizeBytes ?? await _fetchFtpFileSize(server: server, path: node.path);
    if (totalLength <= 0) {
      await remoteMediaLogService.log(
        'stream',
        'fallback to ftp cache-backed stream because file length is unknown',
        data: {
          'server': server.name,
          'path': node.path,
        },
      );
      return _proxyCachedFile(server: server, node: node, request: request, reason: 'ftp_unknown_size_fallback');
    }

    await remoteMediaLogService.log(
      'stream',
      'proxying remote stream through chunked backend',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'method': request.method,
        'range': request.rangeHeader,
        'sizeBytes': totalLength,
      },
    );
    return _proxyChunkedRemote(
      server: server,
      node: node,
      request: request,
      totalLength: totalLength,
      lastModified: _millisToDateTime(node.modifiedMillis),
      fetchChunk: (chunkRange) => _fetchFtpChunk(server: server, path: node.path, range: chunkRange),
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
    await remoteMediaLogService.log(
      'stream',
      'proxying remote stream through chunked backend',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'method': request.method,
        'range': request.rangeHeader,
        'sizeBytes': totalLength,
      },
    );
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

  DateTime? _parseHeaderHttpDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return HttpDate.parse(raw);
    } catch (_) {
      return null;
    }
  }

  String _trimStackTrace(StackTrace stack) {
    final lines = stack.toString().trim().split('\n');
    if (lines.length <= 8) {
      return lines.join('\n');
    }
    return lines.take(8).join('\n');
  }

  Future<RemoteProxyResponse> _proxyChunkedRemote({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteProxyRequest request,
    required int totalLength,
    required DateTime? lastModified,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async {
    final preferStreamOverCache = _shouldPreferStreamOverCachedFile(server, node);
    final fullCacheFile = preferStreamOverCache ? null : await _getExistingCacheFile(server, node);
    if (fullCacheFile != null) {
      return _serveLocalFile(
        file: fullCacheFile,
        mimeType: inferMimeType(node),
        rangeHeader: request.rangeHeader,
        method: request.method,
      );
    }
    if (preferStreamOverCache) {
      final existingCache = await _getExistingCacheFile(server, node);
      if (existingCache != null) {
        await remoteMediaLogService.log(
          'stream',
          'bypass existing full cache file and keep remote streaming path',
          data: {
            'server': server.name,
            'protocol': server.protocol.name,
            'path': node.path,
            'file': existingCache.path,
          },
        );
      }
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

    final isPartial = request.rangeHeader != null && request.rangeHeader!.isNotEmpty;
    return RemoteProxyResponse(
      statusCode: isPartial ? HttpStatus.partialContent : HttpStatus.ok,
      stream: _openLazyChunkedRangeStream(
        server: server,
        node: node,
        requestedRange: range,
        totalLength: totalLength,
        fetchChunk: fetchChunk,
      ),
      contentType: inferMimeType(node),
      contentLength: range.contentLength,
      totalLength: totalLength,
      contentRange: isPartial ? range.contentRangeHeader : null,
      lastModified: lastModified,
    );
  }

  Stream<List<int>> _openLazyChunkedRangeStream({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange requestedRange,
    required int totalLength,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async* {
    final chunkSize = _chunkSizeForProtocol(server.protocol);
    final firstChunk = requestedRange.start ~/ chunkSize;
    final lastChunk = requestedRange.endInclusive ~/ chunkSize;
    final maxPrefetchCount = _prefetchChunkCountForRequest(
      protocol: server.protocol,
      requestedRange: requestedRange,
      totalLength: totalLength,
    );
    final prefetchCount = min(maxPrefetchCount, min(_streamChunkPrefetchCount, lastChunk - firstChunk + 1));
    if (prefetchCount > 0) {
      unawaited(
        _prefetchUpcomingStreamChunks(
          server: server,
          node: node,
          startChunkIndex: firstChunk + 1,
          count: prefetchCount,
          totalLength: totalLength,
          fetchChunk: fetchChunk,
        ),
      );
    }
    for (var chunkIndex = firstChunk; chunkIndex <= lastChunk; chunkIndex++) {
      final chunkStart = chunkIndex * chunkSize;
      final chunkEnd = min(totalLength - 1, chunkStart + chunkSize - 1);
      final chunkRange = RemoteByteRange(start: chunkStart, endInclusive: chunkEnd, totalLength: totalLength);
      final chunkFile = await _getOrCreateStreamChunkFile(
        server: server,
        node: node,
        range: chunkRange,
        fetchChunk: fetchChunk,
      );
      final readStart = max(requestedRange.start, chunkRange.start);
      final readEndInclusive = min(requestedRange.endInclusive, chunkRange.endInclusive);
      if (readEndInclusive < readStart) continue;
      final localStart = readStart - chunkRange.start;
      final localEndExclusive = readEndInclusive - chunkRange.start + 1;
      yield* chunkFile.openRead(localStart, localEndExclusive);
    }
    unawaited(_tryMergeCompleteChunkCache(server: server, node: node, totalLength: totalLength));
  }

  Future<void> _prefetchUpcomingStreamChunks({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required int startChunkIndex,
    required int count,
    required int totalLength,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async {
    if (count <= 0) return;
    final chunkSize = _chunkSizeForProtocol(server.protocol);
    final futures = <Future<void>>[];
    for (var chunkIndex = startChunkIndex; chunkIndex < startChunkIndex + count; chunkIndex++) {
      final chunkStart = chunkIndex * chunkSize;
      if (chunkStart >= totalLength) break;
      final chunkEnd = min(totalLength - 1, chunkStart + chunkSize - 1);
      final chunkRange = RemoteByteRange(start: chunkStart, endInclusive: chunkEnd, totalLength: totalLength);
      futures.add(
        _getOrCreateStreamChunkFile(
          server: server,
          node: node,
          range: chunkRange,
          fetchChunk: fetchChunk,
        ).then((_) {}),
      );
    }
    if (futures.isEmpty) return;
    await remoteMediaLogService.log(
      'stream',
      'prefetch upcoming remote stream chunks',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'startChunkIndex': startChunkIndex,
        'count': futures.length,
      },
    );
    await Future.wait(futures, eagerError: false);
  }

  Future<File> _getOrCreateStreamChunkFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange range,
    required Future<List<int>> Function(RemoteByteRange range) fetchChunk,
  }) async {
    final file = await _buildStreamChunkFile(server: server, node: node, range: range);
    Future<File> createOrFetch() async {
      if (await file.exists()) {
        final length = await file.length();
        if (length == range.contentLength) {
          final isUsable = await _inspectCachedInitialChunkAndValidate(
            server: server,
            node: node,
            range: range,
            file: file,
          );
          if (!isUsable) {
            await file.delete();
          } else {
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
        }
        if (await file.exists()) {
          await file.delete();
        }
      }

      List<int> bytes;
      try {
        bytes = await fetchChunk(range);
      } catch (error, stack) {
        await remoteMediaLogService.log(
          'stream',
          'failed to fetch remote stream chunk',
          data: {
            'server': server.name,
            'protocol': server.protocol.name,
            'path': node.path,
            'start': range.start,
            'end': range.endInclusive,
            'error': '$error',
            'stack': _trimStackTrace(stack),
          },
        );
        rethrow;
      }
      await file.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      await _logInitialChunkSignature(
        server: server,
        node: node,
        range: range,
        bytes: bytes,
        source: 'fetched',
      );
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

    final chunkKey = file.path;
    final inFlight = _streamChunkInFlight[chunkKey];
    if (inFlight != null) {
      await remoteMediaLogService.log(
        'cache',
        'join in-flight remote stream chunk',
        data: {
          'server': server.name,
          'path': node.path,
          'start': range.start,
          'end': range.endInclusive,
          'file': file.path,
        },
      );
      return inFlight;
    }

    final future = createOrFetch();
    _streamChunkInFlight[chunkKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_streamChunkInFlight[chunkKey], future)) {
        final _ = _streamChunkInFlight.remove(chunkKey);
      }
    }
  }

  Future<bool> _inspectCachedInitialChunkAndValidate({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange range,
    required File file,
  }) async {
    if (!node.isVideo || range.start != 0) return true;
    try {
      final bytes = await file
          .openRead(0, min(64, range.contentLength))
          .fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (builder, chunk) => builder..add(chunk),
          );
      final headBytes = bytes.takeBytes();
      await _logInitialChunkSignature(
        server: server,
        node: node,
        range: range,
        bytes: headBytes,
        source: 'cache_hit',
      );
      final looksValid = _looksLikePlayableVideoHeader(headBytes);
      if (!looksValid) {
        await remoteMediaLogService.log(
          'cache',
          'discard invalid cached initial video stream chunk',
          data: {
            'server': server.name,
            'protocol': server.protocol.name,
            'path': node.path,
            'file': file.path,
          },
        );
      }
      return looksValid;
    } catch (error) {
      await remoteMediaLogService.log(
        'stream',
        'failed to inspect cached initial video stream chunk',
        data: {
          'server': server.name,
          'protocol': server.protocol.name,
          'path': node.path,
          'source': 'cache_hit',
          'error': '$error',
        },
      );
      return false;
    }
  }

  Future<void> _logInitialChunkSignature({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required RemoteByteRange range,
    required List<int> bytes,
    required String source,
  }) async {
    if (!node.isVideo || range.start != 0 || bytes.isEmpty) return;
    final key = '${server.id}|${node.path}|${range.start}|$source';
    if (_loggedInitialChunkSignatures.contains(key)) return;
    _loggedInitialChunkSignatures.add(key);

    final head = bytes.take(min(32, bytes.length)).toList(growable: false);
    final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final asciiHead = head.map((b) => (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.').join();
    final ftypIndex = _indexOfPattern(bytes, asciiPattern: 'ftyp', limit: min(bytes.length, 64));
    final jpegMagic = head.length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF;
    final pngMagic = head.length >= 8 && head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47 && head[4] == 0x0D && head[5] == 0x0A && head[6] == 0x1A && head[7] == 0x0A;

    await remoteMediaLogService.log(
      'stream',
      'inspected initial remote video chunk signature',
      data: {
        'server': server.name,
        'protocol': server.protocol.name,
        'path': node.path,
        'source': source,
        'bytesInspected': head.length,
        'hex': hex,
        'ascii': asciiHead,
        'ftypIndex': ftypIndex,
        'jpegMagic': jpegMagic,
        'pngMagic': pngMagic,
      },
    );
  }

  int _indexOfPattern(List<int> bytes, {required String asciiPattern, required int limit}) {
    final pattern = ascii.encode(asciiPattern);
    final maxStart = min(limit, bytes.length) - pattern.length;
    for (var i = 0; i <= maxStart; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  bool _looksLikePlayableVideoHeader(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final head = bytes.take(min(64, bytes.length)).toList(growable: false);
    final ftypIndex = _indexOfPattern(head, asciiPattern: 'ftyp', limit: head.length);
    return ftypIndex >= 0 && ftypIndex <= 16;
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

  Future<int> _fetchFtpFileSize({
    required RemoteServer server,
    required String path,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) return 0;

    final ftp = FTPConnect(
      host,
      port: server.port ?? 21,
      user: server.ftpAnonymous ? 'anonymous' : (server.username ?? 'anonymous'),
      pass: server.ftpAnonymous ? 'anonymous@' : (server.password ?? ''),
      timeout: 20,
    );
    ftp.transferMode = server.ftpPassiveMode ? TransferMode.passive : TransferMode.active;
    try {
      final connected = await ftp.connect();
      if (!connected) return 0;
      final effectivePath = _resolveEffectivePath(server, path);
      final slash = effectivePath.lastIndexOf('/');
      final parent = slash <= 0 ? '/' : effectivePath.substring(0, slash);
      final name = slash == -1 ? effectivePath : effectivePath.substring(slash + 1);
      if (name.isEmpty) return 0;
      final changed = await ftp.changeDirectory(parent);
      if (!changed) return 0;
      final size = await ftp.sizeFile(name);
      return size > 0 ? size : 0;
    } catch (_) {
      return 0;
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  Future<List<int>> _fetchFtpChunk({
    required RemoteServer server,
    required String path,
    required RemoteByteRange range,
  }) async {
    final host = server.host;
    if (host == null || host.isEmpty) {
      throw StateError('Missing FTP host');
    }

    final user = server.ftpAnonymous ? 'anonymous' : (server.username ?? 'anonymous');
    final pass = server.ftpAnonymous ? 'anonymous@' : (server.password ?? '');
    final socket = FTPSocket(
      host,
      server.port ?? 21,
      SecurityType.ftp,
      Logger(isEnabled: false),
      20,
    );
    socket.transferMode = server.ftpPassiveMode ? TransferMode.passive : TransferMode.active;

    Socket? dataSocket;
    try {
      await remoteMediaLogService.log(
        'stream',
        'requesting ftp stream chunk',
        data: {
          'server': server.name,
          'path': path,
          'start': range.start,
          'end': range.endInclusive,
        },
      );
      await socket.connect(user, pass);
      await socket.setTransferType(TransferType.binary);

      final effectivePath = _resolveEffectivePath(server, path);
      final slash = effectivePath.lastIndexOf('/');
      final parent = slash <= 0 ? '/' : effectivePath.substring(0, slash);
      final name = slash == -1 ? effectivePath : effectivePath.substring(slash + 1);
      if (name.isEmpty) {
        throw StateError('Invalid FTP file path');
      }

      final cwdResponse = await socket.sendCommand('CWD $parent');
      if (!cwdResponse.isSuccessCode()) {
        throw StateError('FTP change directory failed with ${cwdResponse.code}');
      }

      final restResponse = await socket.sendCommand('REST ${range.start}');
      if (restResponse.code != 350) {
        throw StateError('FTP REST failed with ${restResponse.code}');
      }

      final dataResponse = await socket.openDataTransferChannel();
      final dataPort = Utils.parsePort(dataResponse.message, socket.supportIPV6);
      socket.sendCommandWithoutWaitingResponse('RETR $name');
      dataSocket = await Socket.connect(host, dataPort, timeout: const Duration(seconds: 20));

      FTPReply response = await socket.readResponse();
      final accepted = response.isSuccessCode() || response.code == 125 || response.code == 150;
      if (!accepted) {
        throw StateError('FTP RETR failed with ${response.code}');
      }

      final builder = BytesBuilder(copy: false);
      var remaining = range.contentLength;
      await for (final data in dataSocket) {
        if (remaining <= 0) break;
        if (data.length <= remaining) {
          builder.add(data);
          remaining -= data.length;
        } else {
          builder.add(data.sublist(0, remaining));
          remaining = 0;
          break;
        }
      }

      await dataSocket.close();
      dataSocket = null;

      if (response.code == 125 || response.code == 150) {
        try {
          await socket.readResponse();
        } catch (_) {
          // Some servers report a transfer-aborted status after the client closes early.
        }
      }

      final bytes = builder.takeBytes();
      if (bytes.length != range.contentLength) {
        throw StateError('FTP chunk length mismatch expected=${range.contentLength} actual=${bytes.length}');
      }
      await remoteMediaLogService.log(
        'stream',
        'received ftp stream chunk',
        data: {
          'server': server.name,
          'path': path,
          'start': range.start,
          'end': range.endInclusive,
          'bytes': bytes.length,
        },
      );
      return bytes;
    } finally {
      try {
        await dataSocket?.close();
      } catch (_) {}
      try {
        await socket.disconnect();
      } catch (_) {}
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
      await remoteMediaLogService.log(
        'stream',
        'requesting sftp stream chunk',
        data: {
          'server': server.name,
          'path': path,
          'start': range.start,
          'end': range.endInclusive,
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 12));
      final sftp = await client.sftp();
      final file = await sftp.open(_resolveEffectivePath(server, path));
      try {
        final bytes = await file.readBytes(length: range.contentLength, offset: range.start);
        if (bytes.length != range.contentLength) {
          throw StateError('SFTP chunk length mismatch expected=${range.contentLength} actual=${bytes.length}');
        }
        await remoteMediaLogService.log(
          'stream',
          'received sftp stream chunk',
          data: {
            'server': server.name,
            'path': path,
            'start': range.start,
            'end': range.endInclusive,
            'bytes': bytes.length,
          },
        );
        return bytes;
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
      await remoteMediaLogService.log(
        'stream',
        'requesting smb stream chunk',
        data: {
          'server': server.name,
          'path': path,
          'start': range.start,
          'end': range.endInclusive,
        },
      );
      final file = await smb.file(_resolveEffectivePath(server, path));
      final raf = await smb.open(file);
      try {
        await raf.setPosition(range.start);
        final bytes = await raf.read(range.contentLength);
        if (bytes.length != range.contentLength) {
          throw StateError('SMB chunk length mismatch expected=${range.contentLength} actual=${bytes.length}');
        }
        await remoteMediaLogService.log(
          'stream',
          'received smb stream chunk',
          data: {
            'server': server.name,
            'path': path,
            'start': range.start,
            'end': range.endInclusive,
            'bytes': bytes.length,
          },
        );
        return bytes;
      } finally {
        await raf.close();
      }
    } finally {
      await smb.close();
    }
  }

  int? _dateTimeToMillis(DateTime? value) => value?.millisecondsSinceEpoch;

  int? _secondsToMillis(int? value) => value != null && value > 0 ? value * 1000 : null;

  int? _normalizeSmbMillis(int? value) => value != null && value > 0 ? value : null;

  String _deriveSftpFallbackName(String longname) {
    final trimmed = longname.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'\s+'));
    return parts.isEmpty ? trimmed : parts.last;
  }

  Future<File?> _downloadWebDavFile({
    required RemoteServer server,
    required RemoteBrowseNode node,
  }) async {
    final base = server.webdavUrl;
    if (base == null || base.isEmpty) return null;
    final targetUri = _buildWebDavUri(base, _resolveEffectivePath(server, node.path));
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
    return File('${cacheDir.path}${Platform.pathSeparator}${_buildCacheFileName(node.name, cacheKey)}');
  }

  Future<Directory> _getStreamChunkDirectory(RemoteServer server, RemoteBrowseNode node, {bool createIfMissing = true}) async {
    final cacheDir = await getConnectionCacheDirectory(server.id);
    final chunkKey = _stableCacheKey('${server.id}|${node.path}|chunks_v$_streamChunkCacheVersion');
    final dir = Directory('${cacheDir.path}${Platform.pathSeparator}.chunks_$chunkKey');
    if (createIfMissing && !await dir.exists()) {
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
    final dir = await _getStreamChunkDirectory(server, node, createIfMissing: false);
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
    final legacyCacheFile = await _buildLegacyCacheFile(server, node);
    final primaryCandidate = await _resolveValidCacheCandidate(server: server, node: node, candidate: cacheFile);
    final legacyCandidate = await _resolveValidCacheCandidate(server: server, node: node, candidate: legacyCacheFile);
    final candidate = primaryCandidate ?? legacyCandidate;
    if (candidate == null) {
      return null;
    }
    if (candidate.path != cacheFile.path) {
      try {
        if (primaryCandidate == null) {
          if (await cacheFile.exists()) {
            try {
              await cacheFile.delete();
            } catch (_) {}
          }
          await candidate.rename(cacheFile.path);
          await remoteMediaLogService.log(
            'cache',
            'migrated legacy remote cache file name',
            data: {
              'server': server.name,
              'path': node.path,
              'from': candidate.path,
              'to': cacheFile.path,
            },
          );
          return cacheFile;
        }
        return primaryCandidate;
      } catch (_) {
        return candidate;
      }
    }
    return candidate;
  }

  Future<File?> getExistingCacheFile(RemoteServer server, RemoteBrowseNode node) => _getExistingCacheFile(server, node);

  bool shouldPreferStreamOverCachedFile(RemoteServer server, RemoteBrowseNode node) => _shouldPreferStreamOverCachedFile(server, node);

  bool _shouldPreferStreamOverCachedFile(RemoteServer server, RemoteBrowseNode node) {
    return node.isVideo;
  }

  Future<File?> _resolveValidCacheCandidate({
    required RemoteServer server,
    required RemoteBrowseNode node,
    required File candidate,
  }) async {
    if (!await candidate.exists()) return null;
    final length = await candidate.length();
    if (length <= 0) {
      return null;
    }
    final expectedLength = node.sizeBytes;
    if (expectedLength != null && expectedLength > 0 && length != expectedLength) {
      final downloadKey = '${server.id}|${node.path}';
      if (_downloadInFlight.containsKey(downloadKey)) {
        await remoteMediaLogService.log(
          'cache',
          'skip deleting incomplete cache file because download is still in progress',
          data: {
            'server': server.name,
            'path': node.path,
            'file': candidate.path,
            'expectedLength': expectedLength,
            'actualLength': length,
          },
        );
        return null;
      }
      await remoteMediaLogService.log(
        'cache',
        'discard remote cache file because length does not match source metadata',
        data: {
          'server': server.name,
          'path': node.path,
          'file': candidate.path,
          'expectedLength': expectedLength,
          'actualLength': length,
        },
      );
      try {
        await candidate.delete();
      } catch (_) {}
      return null;
    }
    return candidate;
  }

  Future<File> _buildLegacyCacheFile(RemoteServer server, RemoteBrowseNode node) async {
    final cacheDir = await getConnectionCacheDirectory(server.id);
    final cacheKey = _stableCacheKey('${server.id}|${node.path}|${node.name}');
    return File('${cacheDir.path}${Platform.pathSeparator}${_safeFileName(node.name)}_$cacheKey');
  }

  String _buildCacheFileName(String rawName, int cacheKey) {
    final safeName = _safeFileName(rawName);
    final dotIndex = safeName.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex == safeName.length - 1) {
      return '${safeName}_$cacheKey';
    }
    final base = safeName.substring(0, dotIndex);
    final ext = safeName.substring(dotIndex);
    return '${base}_$cacheKey$ext';
  }

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

  String? _findDavValue(XmlElement node, String localName) {
    return node.findAllElements(localName, namespace: 'DAV:').firstOrNull?.innerText;
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
        final chunkDir = await _getStreamChunkDirectory(server, node, createIfMissing: false);
        if (await chunkDir.exists()) {
          try {
            await chunkDir.delete(recursive: true);
          } catch (_) {}
        }
        await remoteMediaLogService.log(
          'cache',
          'merged complete remote stream chunks into full cache file and pruned chunk cache',
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

  Future<Set<File>> _collectCacheFilesForPinnedFolder({
    required RemoteServer server,
    required String folderPath,
  }) async {
    final mediaNodes = await _collectMediaNodesRecursively(server: server, folderPath: folderPath);
    final files = <File>{};
    for (final node in mediaNodes) {
      final cacheFile = await _buildCacheFile(server, node);
      if (await cacheFile.exists()) files.add(cacheFile);

      final legacy = await _buildLegacyCacheFile(server, node);
      if (await legacy.exists()) files.add(legacy);

      final chunkDir = await _getStreamChunkDirectory(server, node, createIfMissing: false);
      if (await chunkDir.exists()) {
        await for (final entity in chunkDir.list(recursive: true, followLinks: false)) {
          if (entity is File) files.add(entity);
        }
      }
    }
    return files;
  }

  Future<List<RemoteBrowseNode>> _collectMediaNodesRecursively({
    required RemoteServer server,
    required String folderPath,
  }) async {
    final mediaNodes = <RemoteBrowseNode>[];
    final queue = <String>[_normalizePath(folderPath)];
    final visited = <String>{};
    while (queue.isNotEmpty) {
      final currentPath = queue.removeLast();
      if (!visited.add(currentPath)) continue;
      final page = await loadFolder(server: server, path: currentPath, force: true);
      for (final node in page.children) {
        if (node.isDirectory) {
          queue.add(node.path);
        } else {
          mediaNodes.add(node);
        }
      }
      if (mediaNodes.length > 20000) {
        await remoteMediaLogService.log(
          'cache',
          'stop recursive cache scan because node count limit reached',
          data: {
            'server': server.name,
            'path': folderPath,
            'count': mediaNodes.length,
          },
        );
        break;
      }
    }
    return mediaNodes;
  }
}
