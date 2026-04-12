import 'dart:async';
import 'dart:math';

import 'package:aves/app_mode.dart';
import 'package:aves/model/device.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/multipage.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/settings/enums/remote_stream_mode.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/durations.dart';
import 'package:aves/widgets/viewer/multipage/conductor.dart';
import 'package:aves/widgets/viewer/multipage/controller.dart';
import 'package:aves/widgets/viewer/video/conductor.dart';
import 'package:aves_model/aves_model.dart';
import 'package:aves_video/aves_video.dart';
import 'package:collection/collection.dart';
import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

// state controllers/monitors
mixin EntryViewControllerMixin<T extends StatefulWidget> on State<T> {
  final Map<AvesEntry, VoidCallback> _metadataChangeListeners = {};
  final Map<AvesEntry, String> _lastBoundEntryUri = {};
  final Map<MultiPageController, Future<void> Function()> _multiPageControllerPageListeners = {};
  final Set<String> _sampledRemoteErrorProbeUris = {};
  final Set<String> _ftpAudioOnlyFallbackTriedUris = {};
  final Set<String> _sftpAudioOnlyFallbackTriedUris = {};
  final Set<String> _smbAudioOnlyFallbackTriedUris = {};
  final Map<String, int> _localErrorRecoveryAttempts = {};
  int _viewerRemotePreheatRequestToken = 0;
  String? _lastViewerRemotePreheatSignature;
  int _lastViewerRemotePreheatAtMillis = 0;
  int _viewerRemoteImagePreheatRequestToken = 0;
  String? _lastViewerRemoteImagePreheatSignature;
  int _lastViewerRemoteImagePreheatAtMillis = 0;
  String? _lastAutoPlayUri;
  int _lastAutoPlayAttemptMillis = 0;
  int _lastAutoPlayAnyAttemptMillis = 0;
  final Map<String, int> _lastLocalCacheProbeAtMillisByUri = {};
  int _autoPlayRequestToken = 0;

  bool? videoMutedOverride;

  bool get isViewingImage;

  ValueNotifier<AvesEntry?> get entryNotifier;

  Future<void> initEntryControllers(AvesEntry? entry) async {
    if (!mounted || entry == null) return;

    if (entry.isVideo) {
      await _initVideoController(entry);
    }
    if (entry.isMultiPage) {
      await _initMultiPageController(entry);
    }
    _lastBoundEntryUri[entry] = entry.uri;
    void listener() => _onMetadataChanged(entry);
    _metadataChangeListeners[entry] = listener;
    entry.metadataChangeNotifier.addListener(listener);
  }

  void cleanEntryControllers(AvesEntry? entry) {
    if (entry == null) return;

    final listener = _metadataChangeListeners.remove(entry);
    if (listener != null) {
      entry.metadataChangeNotifier.removeListener(listener);
    }
    if (entry.isMultiPage) {
      _cleanMultiPageController(entry);
    }
    _ftpAudioOnlyFallbackTriedUris.remove(entry.uri);
    _sftpAudioOnlyFallbackTriedUris.remove(entry.uri);
    _smbAudioOnlyFallbackTriedUris.remove(entry.uri);
    _localErrorRecoveryAttempts.remove(entry.uri);
    _lastBoundEntryUri.remove(entry);
  }

  void _onMetadataChanged(AvesEntry entry) {
    final lastUri = _lastBoundEntryUri[entry];
    if (lastUri == entry.uri) {
      if (mounted && entry == entryNotifier.value) {
        setState(() {});
      }
      return;
    }
    debugPrint('reinitialize controllers for entry=$entry because playback uri changed');
    cleanEntryControllers(entry);
    initEntryControllers(entry);
  }

  SlideshowVideoPlayback? get videoPlaybackOverride {
    if (!mounted) return null;
    final appMode = context.read<ValueNotifier<AppMode>>().value;
    switch (appMode) {
      case .screenSaver:
        return settings.screenSaverVideoPlayback;
      case .slideshow:
        return settings.slideshowVideoPlayback;
      default:
        return null;
    }
  }

  bool get videoAutoPlayEnabled {
    if (settings.gridVideoAutoPlay) {
      return true;
    }

    switch (videoPlaybackOverride) {
      case .skip:
        return false;
      case .playMuted:
      case .playWithSound:
        return true;
      case null:
        break;
    }

    switch (settings.videoAutoPlayMode) {
      case .disabled:
        return false;
      case .playMuted:
      case .playWithSound:
        return true;
    }
  }

  bool get shouldAutoPlayVideoMuted {
    if (videoMutedOverride != null) {
      return videoMutedOverride!;
    }

    if (settings.gridVideoAutoPlay) {
      return !settings.gridVideoSoundOn;
    }

    if (videoAutoPlayEnabled) {
      switch (videoPlaybackOverride) {
        case .skip:
        case .playWithSound:
          return false;
        case .playMuted:
          return true;
        case null:
          break;
      }

      switch (settings.videoAutoPlayMode) {
        case .disabled:
        case .playWithSound:
          return false;
        case .playMuted:
          return true;
      }
    }
    return false;
  }

  bool get shouldAutoPlayMotionPhoto {
    if (!isViewingImage) return false;

    return settings.enableMotionPhotoAutoPlay;
  }

  Future<void> _logLocalCacheUsage(AvesEntry entry, String stage) async {
    if (!settings.remoteLogEnabled) return;
    if (entry.isRemoteCachedMedia || entry.uri.startsWith('http://') || entry.uri.startsWith('https://')) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastLocalCacheProbeAtMillisByUri[entry.uri];
    if (last != null && now - last < 4000 && stage == 'viewer_init') return;
    if (stage == 'viewer_init') {
      _lastLocalCacheProbeAtMillisByUri[entry.uri] = now;
    }
    try {
      final usage = await storageService.getDataUsage();
      final details = await storageService.getDataUsageDetails();
      await remoteMediaLogService.log(
        'local_cache_probe',
        'sampled local viewer cache usage',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'stage': stage,
          'internalCacheBytes': usage['internalCache'],
          'externalCacheBytes': usage['externalCache'],
          'flutterBytes': usage['flutter'],
          'databaseBytes': usage['database'],
          'miscBytes': usage['miscData'],
          'usageDetails': details,
        },
      );
    } catch (error) {
      await remoteMediaLogService.log(
        'local_cache_probe',
        'failed to sample local viewer cache usage',
        data: {
          'uri': entry.uri,
          'stage': stage,
          'error': '$error',
        },
      );
    }
  }

  Future<bool> _waitForLocalVideoPriming(AvesVideoController controller, String uri) async {
    final decoded = controller.decodedVideoSizeNotifier.value;
    final hasDecodedFrame = decoded != null && decoded.width > 1 && decoded.height > 1;
    final hasFirstFrame = controller.firstFrameRenderedNotifier.value;
    final hasPlaybackProgress = controller.currentPosition > 0;
    if (hasDecodedFrame || hasFirstFrame || hasPlaybackProgress || controller.status == VideoStatus.error) {
      return hasDecodedFrame || hasFirstFrame || hasPlaybackProgress;
    }
    final completer = Completer<void>();
    VoidCallback? decodedListener;
    VoidCallback? firstFrameListener;
    StreamSubscription<int>? positionSub;
    StreamSubscription<VideoStatus>? statusSub;

    void complete() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    try {
      decodedListener = () {
        final size = controller.decodedVideoSizeNotifier.value;
        if (size != null && size.width > 1 && size.height > 1) {
          complete();
        }
      };
      firstFrameListener = () {
        if (controller.firstFrameRenderedNotifier.value) {
          complete();
        }
      };
      controller.decodedVideoSizeNotifier.addListener(decodedListener);
      controller.firstFrameRenderedNotifier.addListener(firstFrameListener);
      positionSub = controller.positionStream.listen((position) {
        if (position > 0) {
          complete();
        }
      });
      statusSub = controller.statusStream.listen((status) {
        if (status == VideoStatus.error) {
          complete();
        }
      });

      await completer.future.timeout(const Duration(milliseconds: 320));
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'viewer awaited local video priming before playback',
          data: {'uri': uri},
        ),
      );
    } catch (_) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'viewer local video priming wait timed out',
          data: {'uri': uri},
        ),
      );
    }
    controller.decodedVideoSizeNotifier.removeListener(decodedListener!);
    controller.firstFrameRenderedNotifier.removeListener(firstFrameListener!);
    await positionSub?.cancel();
    await statusSub?.cancel();
    final size = controller.decodedVideoSizeNotifier.value;
    return controller.currentPosition > 0 || controller.firstFrameRenderedNotifier.value || (size != null && size.width > 1 && size.height > 1);
  }

  bool _hasRenderableRemoteDetailPreheatFrame(AvesVideoController controller) {
    final size = controller.decodedVideoSizeNotifier.value;
    return controller.currentPosition > 0 || controller.firstFrameRenderedNotifier.value || (size != null && size.width > 1 && size.height > 1);
  }

  Future<void> _waitForRemoteDetailPreheatFrame(AvesVideoController controller, Duration timeout) async {
    if (_hasRenderableRemoteDetailPreheatFrame(controller)) return;
    final completer = Completer<void>();
    late VoidCallback decodedListener;
    late VoidCallback firstFrameListener;
    StreamSubscription<int>? positionSub;
    StreamSubscription<VideoStatus>? statusSub;

    void completeIfReady() {
      if (completer.isCompleted) return;
      if (_hasRenderableRemoteDetailPreheatFrame(controller) || controller.status == VideoStatus.error) {
        completer.complete();
      }
    }

    decodedListener = completeIfReady;
    firstFrameListener = completeIfReady;
    controller.decodedVideoSizeNotifier.addListener(decodedListener);
    controller.firstFrameRenderedNotifier.addListener(firstFrameListener);
    positionSub = controller.positionStream.listen((_) => completeIfReady());
    statusSub = controller.statusStream.listen((_) => completeIfReady());
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // best-effort remote detail preheat
    } finally {
      controller.decodedVideoSizeNotifier.removeListener(decodedListener);
      controller.firstFrameRenderedNotifier.removeListener(firstFrameListener);
      await positionSub.cancel();
      await statusSub.cancel();
    }
  }

  Future<AvesVideoController> _primeWebdavViewerControllerForDetailPreheat(AvesEntry entry, AvesVideoController controller) async {
    try {
      await controller.untilReady.timeout(const Duration(milliseconds: 900));
    } catch (_) {}
    if (_hasRenderableRemoteDetailPreheatFrame(controller)) {
      return controller;
    }

    final wasMuted = controller.isMuted;
    try {
      await controller.mute(true);
      await controller.play();
      await _waitForRemoteDetailPreheatFrame(controller, const Duration(milliseconds: 900));
    } catch (_) {
      // best-effort webdav detail preheat
    } finally {
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.seekTo(0);
      } catch (_) {}
      if (!wasMuted) {
        try {
          await controller.mute(false);
        } catch (_) {}
      }
    }
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'viewer applied webdav detail preview-style preheat',
        data: {
          'uri': entry.uri,
          'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
          'positionMillis': controller.currentPosition,
        },
      ),
    );
    return controller;
  }

  Future<AvesVideoController> _primeFtpViewerControllerForDetailPreheat(AvesEntry entry, AvesVideoController controller) async {
    try {
      await controller.untilReady.timeout(const Duration(milliseconds: 900));
    } catch (_) {}
    if (_hasRenderableRemoteDetailPreheatFrame(controller)) {
      return controller;
    }

    final wasMuted = controller.isMuted;
    try {
      await controller.mute(true);
      await controller.play();
      await _waitForRemoteDetailPreheatFrame(controller, const Duration(milliseconds: 2200));
    } catch (_) {
      // best-effort ftp detail preheat
    } finally {
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.seekTo(0);
      } catch (_) {}
      if (!wasMuted) {
        try {
          await controller.mute(false);
        } catch (_) {}
      }
    }
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'viewer applied ftp detail preview-style preheat',
        data: {
          'uri': entry.uri,
          'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
          'positionMillis': controller.currentPosition,
        },
      ),
    );
    return controller;
  }

  Future<AvesVideoController> _primeSftpViewerControllerForDetailPreheat(AvesEntry entry, AvesVideoController controller) async {
    try {
      await controller.untilReady.timeout(const Duration(milliseconds: 900));
    } catch (_) {}
    if (_hasRenderableRemoteDetailPreheatFrame(controller)) {
      return controller;
    }

    final wasMuted = controller.isMuted;
    try {
      await controller.mute(true);
      await controller.play();
      await _waitForRemoteDetailPreheatFrame(controller, const Duration(milliseconds: 2200));
    } catch (_) {
      // best-effort sftp detail preheat
    } finally {
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.seekTo(0);
      } catch (_) {}
      if (!wasMuted) {
        try {
          await controller.mute(false);
        } catch (_) {}
      }
    }
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'viewer applied sftp detail preview-style preheat',
        data: {
          'uri': entry.uri,
          'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
          'positionMillis': controller.currentPosition,
        },
      ),
    );
    return controller;
  }

  Future<AvesVideoController> _primeSmbViewerControllerForDetailPreheat(AvesEntry entry, AvesVideoController controller) async {
    try {
      await controller.untilReady.timeout(const Duration(milliseconds: 900));
    } catch (_) {}
    if (_hasRenderableRemoteDetailPreheatFrame(controller)) {
      return controller;
    }

    final wasMuted = controller.isMuted;
    try {
      await controller.mute(true);
      await controller.play();
      await _waitForRemoteDetailPreheatFrame(controller, const Duration(milliseconds: 2200));
    } catch (_) {
      // best-effort smb detail preheat
    } finally {
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.seekTo(0);
      } catch (_) {}
      if (!wasMuted) {
        try {
          await controller.mute(false);
        } catch (_) {}
      }
    }
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'viewer applied smb detail preview-style preheat',
        data: {
          'uri': entry.uri,
          'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
          'positionMillis': controller.currentPosition,
        },
      ),
    );
    return controller;
  }

  bool _isViewerRemotePreheatCandidate(AvesEntry entry) {
    if (!entry.isVideo) return false;
    if (entry.isRemoteCachedMedia) return false;
    if (remoteMediaService.hasVirtualRemoteRef(entry.uri)) return true;
    return entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
  }

  bool _isViewerRemoteImagePreheatCandidate(AvesEntry entry) {
    if (!entry.isImage || entry.isVideo || !entry.isDecodingSupported) return false;
    if (entry.isRemoteCachedMedia) return true;
    if (remoteMediaService.hasVirtualRemoteRef(entry.uri)) return true;
    return entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
  }

  Future<void> preheatViewerUpcomingRemoteVideos(List<AvesEntry> entries, int focusIndex) async {
    if (!settings.remoteViewerPreheatEnabled) return;
    final nextVideoPreheatCount = max(0, settings.remotePreviewVideoCount);
    if (nextVideoPreheatCount <= 0) return;
    if (focusIndex < 0 || focusIndex >= entries.length) return;
    final requestToken = ++_viewerRemotePreheatRequestToken;

    final focusEntry = entries[focusIndex];
    if (!_isViewerRemotePreheatCandidate(focusEntry)) return;

    final nextVideos = <AvesEntry>[];
    for (var i = focusIndex + 1; i < entries.length; i++) {
      final candidate = entries[i];
      if (!_isViewerRemotePreheatCandidate(candidate)) continue;
      nextVideos.add(candidate);
      if (nextVideos.length >= nextVideoPreheatCount) break;
    }
    if (nextVideos.isEmpty) return;
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final signature = '$focusIndex:${focusEntry.uri}:${nextVideos.map((entry) => entry.uri).join('|')}';
    if (_lastViewerRemotePreheatSignature == signature && nowMillis - _lastViewerRemotePreheatAtMillis < 1800) {
      return;
    }
    _lastViewerRemotePreheatSignature = signature;
    _lastViewerRemotePreheatAtMillis = nowMillis;

    for (final nextVideo in nextVideos) {
      if (requestToken != _viewerRemotePreheatRequestToken) return;
      if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
      try {
        await remoteMediaService.ensureEntryMetadata(nextVideo, trigger: 'viewer_focus_next_video_preheat');
        if (requestToken != _viewerRemotePreheatRequestToken) return;
        if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
        final protocol = remoteMediaService.getRemoteProtocolForEntry(nextVideo);
        if (protocol == RemoteProtocol.webdav) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(nextVideo, trigger: 'viewer_focus_next_video_warmup');
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          await remoteMediaService.prepareEntryForPlayback(
            nextVideo,
            trigger: 'viewer_focus_next_video_preheat',
            allowDownload: false,
          );
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          var controller = await context.read<VideoConductor>().getOrCreateController(nextVideo, maxControllerCount: 5);
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          controller = await _primeWebdavViewerControllerForDetailPreheat(nextVideo, controller);
          final size = controller.decodedVideoSizeNotifier.value;
          if (size != null && size.width > 1 && size.height > 1) {
            nextVideo.width = size.width.round();
            nextVideo.height = size.height.round();
            nextVideo.visualChangeNotifier.notify();
          }
          await remoteMediaLogService.log(
            'stream',
            'viewer prepared next webdav video detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextVideo.uri,
              'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
              'width': size?.width.round(),
              'height': size?.height.round(),
            },
          );
        } else if (protocol == RemoteProtocol.ftp) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(nextVideo, trigger: 'viewer_focus_next_video_warmup');
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          await remoteMediaService.prepareEntryForPlayback(
            nextVideo,
            trigger: 'viewer_focus_next_video_preheat',
            allowDownload: false,
          );
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          var controller = await context.read<VideoConductor>().getOrCreateController(nextVideo, maxControllerCount: 5);
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          controller = await _primeFtpViewerControllerForDetailPreheat(nextVideo, controller);
          final size = controller.decodedVideoSizeNotifier.value;
          if (size != null && size.width > 1 && size.height > 1) {
            nextVideo.width = size.width.round();
            nextVideo.height = size.height.round();
            nextVideo.visualChangeNotifier.notify();
          }
          await remoteMediaLogService.log(
            'stream',
            'viewer prepared next ftp video detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextVideo.uri,
              'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
              'width': size?.width.round(),
              'height': size?.height.round(),
            },
          );
        } else if (protocol == RemoteProtocol.sftp) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(nextVideo, trigger: 'viewer_focus_next_video_warmup');
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          await remoteMediaService.prepareEntryForPlayback(
            nextVideo,
            trigger: 'viewer_focus_next_video_preheat',
            allowDownload: false,
          );
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          var controller = await context.read<VideoConductor>().getOrCreateController(nextVideo, maxControllerCount: 5);
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          controller = await _primeSftpViewerControllerForDetailPreheat(nextVideo, controller);
          final size = controller.decodedVideoSizeNotifier.value;
          if (size != null && size.width > 1 && size.height > 1) {
            nextVideo.width = size.width.round();
            nextVideo.height = size.height.round();
            nextVideo.visualChangeNotifier.notify();
          }
          await remoteMediaLogService.log(
            'stream',
            'viewer prepared next sftp video detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextVideo.uri,
              'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
              'width': size?.width.round(),
              'height': size?.height.round(),
            },
          );
        } else if (protocol == RemoteProtocol.smb) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(nextVideo, trigger: 'viewer_focus_next_video_warmup');
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          await remoteMediaService.prepareEntryForPlayback(
            nextVideo,
            trigger: 'viewer_focus_next_video_preheat',
            allowDownload: false,
          );
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          var controller = await context.read<VideoConductor>().getOrCreateController(nextVideo, maxControllerCount: 5);
          if (requestToken != _viewerRemotePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          controller = await _primeSmbViewerControllerForDetailPreheat(nextVideo, controller);
          final size = controller.decodedVideoSizeNotifier.value;
          if (size != null && size.width > 1 && size.height > 1) {
            nextVideo.width = size.width.round();
            nextVideo.height = size.height.round();
            nextVideo.visualChangeNotifier.notify();
          }
          await remoteMediaLogService.log(
            'stream',
            'viewer prepared next smb video detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextVideo.uri,
              'hasRenderableFrame': _hasRenderableRemoteDetailPreheatFrame(controller),
              'width': size?.width.round(),
              'height': size?.height.round(),
            },
          );
        }
      } catch (error) {
        await remoteMediaLogService.log(
          'stream',
          'viewer failed next remote video detail preheat',
          data: {
            'focusUri': focusEntry.uri,
            'uri': nextVideo.uri,
            'error': '$error',
          },
        );
      }
    }
  }

  Future<void> preheatViewerUpcomingRemoteImages(List<AvesEntry> entries, int focusIndex) async {
    if (!settings.remoteViewerPreheatEnabled) return;
    final nextImagePreheatCount = max(0, settings.remotePreviewImageCount);
    if (nextImagePreheatCount <= 0) return;
    if (focusIndex < 0 || focusIndex >= entries.length) return;
    final requestToken = ++_viewerRemoteImagePreheatRequestToken;

    final focusEntry = entries[focusIndex];
    final nextImages = <AvesEntry>[];
    for (var i = focusIndex + 1; i < entries.length; i++) {
      final candidate = entries[i];
      if (!_isViewerRemoteImagePreheatCandidate(candidate)) continue;
      nextImages.add(candidate);
      if (nextImages.length >= nextImagePreheatCount) break;
    }
    if (nextImages.isEmpty) return;

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final signature = '$focusIndex:${focusEntry.uri}:${nextImages.map((entry) => entry.uri).join('|')}';
    if (_lastViewerRemoteImagePreheatSignature == signature && nowMillis - _lastViewerRemoteImagePreheatAtMillis < 1800) {
      return;
    }
    _lastViewerRemoteImagePreheatSignature = signature;
    _lastViewerRemoteImagePreheatAtMillis = nowMillis;

    for (final nextImage in nextImages) {
      if (requestToken != _viewerRemoteImagePreheatRequestToken) return;
      if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
      try {
        await remoteMediaService.ensureEntryMetadata(nextImage, trigger: 'viewer_focus_next_image_preheat');
        if (requestToken != _viewerRemoteImagePreheatRequestToken) return;
        if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;

        final protocol = remoteMediaService.getRemoteProtocolForEntry(nextImage);
        if (protocol == RemoteProtocol.webdav) {
          await remoteMediaService.bindExistingCacheFileForEntry(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat_bind_existing',
          );
          if (requestToken != _viewerRemoteImagePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          final resolved = await remoteMediaService.ensureViewerImageDisplayMetadata(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat',
          );
          await remoteMediaLogService.log(
            'metadata',
            'viewer prepared next webdav image detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextImage.uri,
              'resolved': resolved,
              'width': nextImage.width,
              'height': nextImage.height,
            },
          );
        } else if (protocol == RemoteProtocol.ftp) {
          await remoteMediaService.bindExistingCacheFileForEntry(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat_bind_existing',
          );
          if (requestToken != _viewerRemoteImagePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          final resolved = await remoteMediaService.ensureViewerImageDisplayMetadata(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat',
          );
          await remoteMediaLogService.log(
            'metadata',
            'viewer prepared next ftp image detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextImage.uri,
              'resolved': resolved,
              'width': nextImage.width,
              'height': nextImage.height,
            },
          );
        } else if (protocol == RemoteProtocol.sftp) {
          await remoteMediaService.bindExistingCacheFileForEntry(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat_bind_existing',
          );
          if (requestToken != _viewerRemoteImagePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          final resolved = await remoteMediaService.ensureViewerImageDisplayMetadata(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat',
          );
          await remoteMediaLogService.log(
            'metadata',
            'viewer prepared next sftp image detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextImage.uri,
              'resolved': resolved,
              'width': nextImage.width,
              'height': nextImage.height,
            },
          );
        } else if (protocol == RemoteProtocol.smb) {
          await remoteMediaService.bindExistingCacheFileForEntry(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat_bind_existing',
          );
          if (requestToken != _viewerRemoteImagePreheatRequestToken) return;
          if (!mounted || entryNotifier.value?.uri != focusEntry.uri) return;
          final resolved = await remoteMediaService.ensureViewerImageDisplayMetadata(
            nextImage,
            trigger: 'viewer_focus_next_image_preheat',
          );
          await remoteMediaLogService.log(
            'metadata',
            'viewer prepared next smb image detail preheat',
            data: {
              'focusUri': focusEntry.uri,
              'uri': nextImage.uri,
              'resolved': resolved,
              'width': nextImage.width,
              'height': nextImage.height,
            },
          );
        }
      } catch (error) {
        await remoteMediaLogService.log(
          'metadata',
          'viewer failed next remote image detail preheat',
          data: {
            'focusUri': focusEntry.uri,
            'uri': nextImage.uri,
            'error': '$error',
          },
        );
      }
    }
  }

  Future<void> _initVideoController(AvesEntry entry) async {
    if (!entry.isRemoteCachedMedia && !entry.uri.startsWith('http://') && !entry.uri.startsWith('https://')) {
      unawaited(_logLocalCacheUsage(entry, 'viewer_init'));
    }
    await remoteMediaService.ensureEntryMetadata(entry, trigger: 'viewer_init');
    await remoteMediaService.prepareEntryForPlayback(
      entry,
      trigger: 'viewer_init',
      allowDownload: false,
    );
    final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
    final isRemoteStream = entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
    final shouldApplyRemoteDetailPreviewPreheat = settings.remoteViewerPreheatEnabled && settings.remotePreviewVideoCount > 0;
    if (isRemoteStream) {
      if (!shouldApplyRemoteDetailPreviewPreheat) {
        unawaited(remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'viewer_init'));
      } else if (remoteProtocol == RemoteProtocol.webdav) {
        await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'viewer_init');
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer awaited initial webdav stream warmup before controller init',
            data: {'uri': entry.uri},
          ),
        );
      } else if (remoteProtocol == RemoteProtocol.ftp) {
        await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'viewer_init');
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer awaited initial ftp stream warmup before controller init',
            data: {'uri': entry.uri},
          ),
        );
      } else if (remoteProtocol == RemoteProtocol.sftp) {
        await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'viewer_init');
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer awaited initial sftp stream warmup before controller init',
            data: {'uri': entry.uri},
          ),
        );
      } else if (remoteProtocol == RemoteProtocol.smb) {
        await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'viewer_init');
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer awaited initial smb stream warmup before controller init',
            data: {'uri': entry.uri},
          ),
        );
      } else {
        unawaited(remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'viewer_init'));
      }
    }
    final videoConductor = context.read<VideoConductor>();
    var controller = await videoConductor.getOrCreateController(entry);
    final isLargeRemoteVideo = isRemoteStream && remoteMediaService.isLargeRemoteVideoEntry(entry);
    if (isLargeRemoteVideo && (controller.currentPosition > 0 || controller.isPlaying || controller.status == VideoStatus.error)) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'viewer recreates large remote video controller to avoid reusing preview session',
          data: {
            'uri': entry.uri,
            'status': controller.status.name,
            'isPlaying': controller.isPlaying,
            'isReady': controller.isReady,
            'positionMillis': controller.currentPosition,
            'protocol': remoteProtocol?.name,
          },
        ),
      );
      controller = await videoConductor.recreateController(entry);
    }
    if (isRemoteStream && shouldApplyRemoteDetailPreviewPreheat) {
      if (remoteProtocol == RemoteProtocol.webdav) {
        controller = await _primeWebdavViewerControllerForDetailPreheat(entry, controller);
      } else if (remoteProtocol == RemoteProtocol.ftp) {
        controller = await _primeFtpViewerControllerForDetailPreheat(entry, controller);
      } else if (remoteProtocol == RemoteProtocol.sftp) {
        controller = await _primeSftpViewerControllerForDetailPreheat(entry, controller);
      } else if (remoteProtocol == RemoteProtocol.smb) {
        controller = await _primeSmbViewerControllerForDetailPreheat(entry, controller);
      }
    }
    setState(() {});
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'viewer video controller created',
        data: {
          'uri': entry.uri,
          'isVideo': entry.isVideo,
          'status': controller.status.name,
          'autoPlayEnabled': videoAutoPlayEnabled,
          'isRemoteStream': isRemoteStream,
          'isRemoteCached': entry.isRemoteCachedMedia,
          'sourceType': isRemoteStream ? 'remote' : 'local',
          'path': entry.path,
        },
      ),
    );

    if (settings.remoteLogEnabled) {
      unawaited(
        controller.statusStream
            .firstWhere((status) => status == VideoStatus.error)
            .timeout(const Duration(seconds: 4))
            .then((_) async {
              if (isRemoteStream) {
                if (!_sampledRemoteErrorProbeUris.add(entry.uri)) return;
                final probe = await remoteMediaService.probeStreamUriHealth(entry.uri);
                return remoteMediaLogService.log(
                  'autoplay',
                  'viewer remote stream entered error status',
                  data: {
                    'uri': entry.uri,
                    'probe': probe,
                  },
                );
              }
              return remoteMediaLogService.log(
                'autoplay',
                'viewer local video entered error status',
                data: {
                  'uri': entry.uri,
                  'path': entry.path,
                  'status': controller.status.name,
                  'isRemoteCached': entry.isRemoteCachedMedia,
                },
              );
            })
            .catchError((_) {}),
      );
    }

    if (videoAutoPlayEnabled || entry.isAnimated) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'initialize video controller with auto play',
          data: {
            'uri': entry.uri,
            'isAnimated': entry.isAnimated,
            'autoPlayEnabled': videoAutoPlayEnabled,
            'muted': shouldAutoPlayVideoMuted,
            'isRemoteCached': entry.isRemoteCachedMedia,
            'sourceType': isRemoteStream ? 'remote' : 'local',
            'viewerAutoPlayMode': settings.videoAutoPlayMode.name,
          },
        ),
      );
      final resumeTimeMillis = await controller.getResumeTime(context);
      await _autoPlayVideo(controller, () => entry == entryNotifier.value, resumeTimeMillis: resumeTimeMillis);
    }
  }

  Future<void> _initMultiPageController(AvesEntry entry) async {
    if (!mounted) return;

    final multiPageController = context.read<MultiPageConductor>().getOrCreateController(entry);
    setState(() {});

    final multiPageInfo = multiPageController.info ?? await multiPageController.infoStream.first;
    assert(multiPageInfo != null);
    if (multiPageInfo == null) return;

    if (entry.isMotionPhoto) {
      await multiPageInfo.extractMotionPhotoVideo();
    }

    final videoPageEntries = multiPageInfo.videoPageEntries;
    if (videoPageEntries.isNotEmpty) {
      // init video controllers for all pages that could need it
      final videoConductor = context.read<VideoConductor>();
      await Future.forEach(videoPageEntries, (entry) async {
        await videoConductor.getOrCreateController(entry, maxControllerCount: videoPageEntries.length);
      });

      // auto play/pause when changing page
      Future<void> _onPageChanged() async {
        await pauseVideoControllers();
        unawaited(
          remoteMediaLogService.log(
            'focus',
            'multi-page focus changed',
            data: {
              'uri': entry.uri,
              'page': multiPageController.page,
              'autoPlayEnabled': videoAutoPlayEnabled,
            },
          ),
        );
        if (videoAutoPlayEnabled || (entry.isMotionPhoto && shouldAutoPlayMotionPhoto)) {
          final page = multiPageController.page;
          final pageInfo = multiPageInfo.getByIndex(page)!;
          if (pageInfo.isVideo) {
            final pageEntry = multiPageInfo.getPageEntryByIndex(page);
            final pageVideoController = videoConductor.getController(pageEntry);
            assert(pageVideoController != null);
            if (pageVideoController != null) {
              await _autoPlayVideo(pageVideoController, () => entry == entryNotifier.value && page == multiPageController.page);
            }
          }
        }
      }

      _multiPageControllerPageListeners[multiPageController] = _onPageChanged;
      multiPageController.pageNotifier.addListener(_onPageChanged);
      await _onPageChanged();

      if (entry.isMotionPhoto && shouldAutoPlayMotionPhoto) {
        await Future.delayed(ADurations.motionPhotoAutoPlayDelay);
        if (entry == entryNotifier.value) {
          multiPageController.page = 1;
        }
      }
    }
  }

  Future<void> _cleanMultiPageController(AvesEntry entry) async {
    final multiPageController = _multiPageControllerPageListeners.keys.firstWhereOrNull((v) => v.entry == entry);
    if (multiPageController != null) {
      final _onPageChange = _multiPageControllerPageListeners.remove(multiPageController);
      if (_onPageChange != null) {
        multiPageController.pageNotifier.removeListener(_onPageChange);
      }
    }
  }

  Future<void> _autoPlayVideo(AvesVideoController videoController, bool Function() isCurrent, {int? resumeTimeMillis}) async {
    final uri = videoController.entry.uri;
    final isRemoteStreamUri = uri.startsWith('http://') || uri.startsWith('https://');
    RemoteProtocol? remoteProtocol;
    final token = ++_autoPlayRequestToken;
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final elapsedSinceAnyAttempt = nowMillis - _lastAutoPlayAnyAttemptMillis;
    if (elapsedSinceAnyAttempt < 140) {
      await Future.delayed(Duration(milliseconds: 140 - elapsedSinceAnyAttempt) * timeDilation);
      if (token != _autoPlayRequestToken || !isCurrent()) {
        unawaited(
          remoteMediaLogService.log(
            'focus',
            'cancelled autoplay during anti-jitter throttle window',
            data: {'uri': uri},
          ),
        );
        return;
      }
    }
    if (_lastAutoPlayUri == uri && nowMillis - _lastAutoPlayAttemptMillis < 250) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'skipped duplicated autoplay attempt',
          data: {'uri': uri},
        ),
      );
      return;
    }
    _lastAutoPlayAnyAttemptMillis = nowMillis;
    _lastAutoPlayUri = uri;
    _lastAutoPlayAttemptMillis = nowMillis;

    // video decoding may fail or have initial artifacts when the player initializes
    // during this widget initialization (because of the page transition and hero animation?)
    // so we play after a delay for increased stability
    await Future.delayed(const Duration(milliseconds: 300) * timeDilation);
    if (token != _autoPlayRequestToken) {
      unawaited(
        remoteMediaLogService.log(
          'focus',
          'cancelled autoplay because newer focus request exists',
          data: {'uri': uri},
        ),
      );
      return;
    }
    if (!isCurrent()) {
      unawaited(
        remoteMediaLogService.log(
          'focus',
          'cancelled autoplay before play because focus changed',
          data: {'uri': uri},
        ),
      );
      return;
    }

    await context.read<VideoConductor>().pauseOthers(videoController);

    final controllerEntry = videoController.entry;
    if (controllerEntry is AvesEntry) {
      await remoteMediaService.ensureEntryMetadata(controllerEntry, trigger: 'viewer_autoplay');
      final hasRemoteRef = remoteMediaService.getVirtualRemoteRef(controllerEntry.uri) != null;
      if (hasRemoteRef) {
        if (isRemoteStreamUri) {
          remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(controllerEntry);
          if (remoteProtocol == RemoteProtocol.smb || remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp) {
            await remoteMediaService.prepareInitialStreamPlaybackForEntry(controllerEntry, trigger: 'viewer_autoplay');
            unawaited(
              remoteMediaLogService.log(
                'autoplay',
                'viewer awaited remote stream warmup before autoplay',
                data: {
                  'uri': controllerEntry.uri,
                  'protocol': remoteProtocol?.name,
                },
              ),
            );
          } else {
            unawaited(remoteMediaService.prepareInitialStreamPlaybackForEntry(controllerEntry, trigger: 'viewer_autoplay'));
          }
        } else {
          unawaited(
            remoteMediaLogService.log(
              'auto_download',
              'skip full warmup for remote-backed local playback uri during viewer autoplay',
              data: {
                'uri': controllerEntry.uri,
              },
            ),
          );
        }
      } else if (!isRemoteStreamUri) {
        unawaited(remoteMediaService.warmupVideoCacheForEntry(controllerEntry, trigger: 'viewer_autoplay'));
      } else {
        remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(controllerEntry);
        unawaited(remoteMediaService.prepareInitialStreamPlaybackForEntry(controllerEntry, trigger: 'viewer_autoplay'));
      }
    }

    if (!videoController.isMuted && (videoController.entry.isAnimated || shouldAutoPlayVideoMuted)) {
      await videoController.mute(true);
    }

    final prefersImmediatePlayback = isRemoteStreamUri && (remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp || remoteProtocol == RemoteProtocol.smb);
    var localPrimed = false;
    if (prefersImmediatePlayback) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'skip strict ready wait for remote chunked viewer autoplay',
          data: {
            'uri': uri,
            'protocol': remoteProtocol?.name,
          },
        ),
      );
      if (controllerEntry is AvesEntry && !controllerEntry.isRemoteCachedMedia && !controllerEntry.uri.startsWith('http://') && !controllerEntry.uri.startsWith('https://')) {
        unawaited(_logLocalCacheUsage(controllerEntry, 'viewer_playback_requested'));
      }
    } else {
      try {
        await videoController.untilReady.timeout(Duration(milliseconds: isRemoteStreamUri ? 1200 : 1500));
      } catch (_) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'video not ready before autoplay timeout',
            data: {
              'uri': uri,
              'status': videoController.status.name,
              'isPlaying': videoController.isPlaying,
            },
          ),
        );
      }
      if (!isRemoteStreamUri) {
        localPrimed = await _waitForLocalVideoPriming(videoController, uri);
        final localDecoded = videoController.decodedVideoSizeNotifier.value;
        final hasLocalFrame = localPrimed || (localDecoded != null && localDecoded.width > 1 && localDecoded.height > 1) || videoController.firstFrameRenderedNotifier.value || videoController.currentPosition > 0;
        final localRecoveryAttempts = _localErrorRecoveryAttempts[uri] ?? 0;
        if (!hasLocalFrame && videoController.status != VideoStatus.error && localRecoveryAttempts < 2) {
          _localErrorRecoveryAttempts[uri] = localRecoveryAttempts + 1;
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'viewer requested local controller recreation before playback after priming timeout without frame',
              data: {
                'uri': uri,
                'attempt': localRecoveryAttempts + 1,
              },
            ),
          );
          final recreatedController = await context.read<VideoConductor>().recreateController(controllerEntry as AvesEntry);
          if (!mounted) return;
          setState(() {});
          if (token == _autoPlayRequestToken && isCurrent()) {
            await Future.delayed(const Duration(milliseconds: 90) * timeDilation);
            if (token == _autoPlayRequestToken && isCurrent()) {
              await _autoPlayVideo(recreatedController, isCurrent, resumeTimeMillis: resumeTimeMillis);
            }
          }
          return;
        }
      }
    }

    if (resumeTimeMillis != null) {
      await videoController.seekTo(resumeTimeMillis);
    }
    await videoController.play();
    if (controllerEntry is AvesEntry) {
      await remoteMediaService.ensureEntryMetadata(controllerEntry, trigger: 'viewer_playback_started');
    }
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'playback requested',
        data: {
          'uri': videoController.entry.uri,
          'path': controllerEntry is AvesEntry ? controllerEntry.path : null,
          'resumeTimeMillis': resumeTimeMillis,
          'muted': videoController.isMuted,
          'isRemoteStream': isRemoteStreamUri,
          'sourceType': isRemoteStreamUri ? 'remote' : 'local',
          'status': videoController.status.name,
          'isPlaying': videoController.isPlaying,
          'positionMillis': videoController.currentPosition,
        },
      ),
    );

    // Remote streams can fail on first autoplay with audio enabled on some decoders.
    // Retry once with muted audio before giving up.
    if (token == _autoPlayRequestToken && isCurrent() && isRemoteStreamUri && videoController.status == VideoStatus.error && !videoController.isMuted) {
      try {
        await videoController.mute(true);
        await videoController.play();
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'remote stream autoplay retry requested with muted audio after error',
            data: {'uri': uri},
          ),
        );
      } catch (_) {}
    }

    // Playback initialization can still race with focus transitions or decoder warm-up.
    // If autoplay did not effectively start, retry once while the same entry stays focused.
    await Future.delayed(const Duration(milliseconds: 350) * timeDilation);
    if (token == _autoPlayRequestToken && isCurrent() && !videoController.isPlaying && videoController.status != VideoStatus.error) {
      await videoController.play();
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'autoplay retry requested after initial non-playing state',
          data: {'uri': uri},
        ),
      );
    }

    // Some videos (notably certain landscape encodes) may still miss the first autoplay window.
    // Keep one extra delayed retry while focus remains stable.
    await Future.delayed(const Duration(milliseconds: 550) * timeDilation);
    if (token == _autoPlayRequestToken && isCurrent() && !videoController.isPlaying && videoController.status != VideoStatus.error) {
      await videoController.seekTo(resumeTimeMillis ?? 0);
      await videoController.play();
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'autoplay second retry requested after delayed non-playing state',
          data: {'uri': uri, 'seekMillis': resumeTimeMillis ?? 0},
        ),
      );
    }
    final allowDownloadFallback = settings.remoteStreamMode == RemoteStreamMode.streamWithDownloadFallback;
    if (token == _autoPlayRequestToken && isCurrent() && isRemoteStreamUri && controllerEntry is AvesEntry && videoController.status == VideoStatus.error) {
      try {
        await remoteMediaService.prepareInitialStreamPlaybackForEntry(controllerEntry, trigger: 'viewer_error_retry');
        await Future.delayed(const Duration(milliseconds: 260) * timeDilation);
        if (token == _autoPlayRequestToken && isCurrent()) {
          await videoController.play();
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'viewer requested remote stream retry before download fallback',
              data: {
                'uri': uri,
                'protocol': remoteMediaService.getRemoteProtocolForEntry(controllerEntry)?.name,
              },
            ),
          );
        }
      } catch (error) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer remote stream retry preparation failed',
            data: {
              'uri': uri,
              'error': '$error',
            },
          ),
        );
      }
    }
    if (token == _autoPlayRequestToken && isCurrent() && isRemoteStreamUri && controllerEntry is AvesEntry) {
      final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(controllerEntry);
      final decoded = videoController.decodedVideoSizeNotifier.value;
      final hasVideoFrame = decoded != null && decoded.width > 1 && decoded.height > 1;
      if (remoteProtocol == RemoteProtocol.ftp && videoController.isPlaying && !hasVideoFrame) {
        if (_ftpAudioOnlyFallbackTriedUris.contains(uri)) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 450) * timeDilation);
        if (token != _autoPlayRequestToken || !isCurrent()) {
          return;
        }
        final decodedAfterDelay = videoController.decodedVideoSizeNotifier.value;
        final stillNoFrame = decodedAfterDelay == null || decodedAfterDelay.width <= 1 || decodedAfterDelay.height <= 1;
        if (!stillNoFrame || !videoController.isPlaying) {
          return;
        }
        _ftpAudioOnlyFallbackTriedUris.add(uri);
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer detected ftp audio-only playback, trigger fallback download',
            data: {
              'uri': uri,
            },
          ),
        );
        final fallbackFile = await remoteMediaService.ensureDownloadedForEntry(controllerEntry, trigger: 'viewer_audio_only_fallback');
        if (fallbackFile != null && token == _autoPlayRequestToken && isCurrent()) {
          final fallbackController = await context.read<VideoConductor>().getOrCreateController(controllerEntry);
          await context.read<VideoConductor>().pauseOthers(fallbackController);
          await fallbackController.mute(shouldAutoPlayVideoMuted);
          try {
            await fallbackController.untilReady.timeout(const Duration(milliseconds: 1200));
          } catch (_) {}
          await fallbackController.play();
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'viewer switched to downloaded fallback after ftp audio-only detection',
              data: {
                'uri': controllerEntry.uri,
                'file': fallbackFile.path,
              },
            ),
          );
          return;
        }
      }
      if (remoteProtocol == RemoteProtocol.sftp && videoController.isPlaying && !hasVideoFrame) {
        if (_sftpAudioOnlyFallbackTriedUris.contains(uri)) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 450) * timeDilation);
        if (token != _autoPlayRequestToken || !isCurrent()) {
          return;
        }
        final decodedAfterDelay = videoController.decodedVideoSizeNotifier.value;
        final stillNoFrame = decodedAfterDelay == null || decodedAfterDelay.width <= 1 || decodedAfterDelay.height <= 1;
        if (!stillNoFrame || !videoController.isPlaying) {
          return;
        }
        _sftpAudioOnlyFallbackTriedUris.add(uri);
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer detected sftp audio-only playback, trigger fallback download',
            data: {
              'uri': uri,
            },
          ),
        );
        final fallbackFile = await remoteMediaService.ensureDownloadedForEntry(controllerEntry, trigger: 'viewer_audio_only_fallback');
        if (fallbackFile != null && token == _autoPlayRequestToken && isCurrent()) {
          final fallbackController = await context.read<VideoConductor>().getOrCreateController(controllerEntry);
          await context.read<VideoConductor>().pauseOthers(fallbackController);
          await fallbackController.mute(shouldAutoPlayVideoMuted);
          try {
            await fallbackController.untilReady.timeout(const Duration(milliseconds: 1200));
          } catch (_) {}
          await fallbackController.play();
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'viewer switched to downloaded fallback after sftp audio-only detection',
              data: {
                'uri': controllerEntry.uri,
                'file': fallbackFile.path,
              },
            ),
          );
          return;
        }
      }
      if (remoteProtocol == RemoteProtocol.smb && videoController.isPlaying && !hasVideoFrame) {
        if (_smbAudioOnlyFallbackTriedUris.contains(uri)) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 450) * timeDilation);
        if (token != _autoPlayRequestToken || !isCurrent()) {
          return;
        }
        final decodedAfterDelay = videoController.decodedVideoSizeNotifier.value;
        final stillNoFrame = decodedAfterDelay == null || decodedAfterDelay.width <= 1 || decodedAfterDelay.height <= 1;
        if (!stillNoFrame || !videoController.isPlaying) {
          return;
        }
        _smbAudioOnlyFallbackTriedUris.add(uri);
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer detected smb audio-only playback, trigger fallback download',
            data: {
              'uri': uri,
            },
          ),
        );
        final fallbackFile = await remoteMediaService.ensureDownloadedForEntry(controllerEntry, trigger: 'viewer_audio_only_fallback');
        if (fallbackFile != null && token == _autoPlayRequestToken && isCurrent()) {
          final fallbackController = await context.read<VideoConductor>().getOrCreateController(controllerEntry);
          await context.read<VideoConductor>().pauseOthers(fallbackController);
          await fallbackController.mute(shouldAutoPlayVideoMuted);
          try {
            await fallbackController.untilReady.timeout(const Duration(milliseconds: 1200));
          } catch (_) {}
          await fallbackController.play();
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'viewer switched to downloaded fallback after smb audio-only detection',
              data: {
                'uri': controllerEntry.uri,
                'file': fallbackFile.path,
              },
            ),
          );
          return;
        }
      }
    }
    if (token == _autoPlayRequestToken && isCurrent() && isRemoteStreamUri && videoController.status == VideoStatus.error && controllerEntry is AvesEntry) {
      if (!allowDownloadFallback) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer download fallback skipped because stream-only mode is enabled',
            data: {'uri': uri},
          ),
        );
        return;
      }
      final fallbackFile = await remoteMediaService.ensureDownloadedForEntry(controllerEntry, trigger: 'viewer_error_fallback');
      if (fallbackFile != null && token == _autoPlayRequestToken && isCurrent()) {
        final fallbackController = await context.read<VideoConductor>().getOrCreateController(controllerEntry);
        await context.read<VideoConductor>().pauseOthers(fallbackController);
        await fallbackController.mute(shouldAutoPlayVideoMuted);
        try {
          await fallbackController.untilReady.timeout(const Duration(milliseconds: 1200));
        } catch (_) {}
        await fallbackController.play();
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer autoplay switched to downloaded fallback after remote stream error',
            data: {
              'uri': controllerEntry.uri,
              'file': fallbackFile.path,
            },
          ),
        );
        return;
      }
    }
    if (token == _autoPlayRequestToken && isCurrent() && !isRemoteStreamUri && controllerEntry is AvesEntry && videoController.status == VideoStatus.error) {
      final decoded = videoController.decodedVideoSizeNotifier.value;
      final hasVideoFrame = decoded != null && decoded.width > 1 && decoded.height > 1;
      final hasPlaybackProgress = videoController.currentPosition > 0;
      final localRecoveryAttempts = _localErrorRecoveryAttempts[uri] ?? 0;
      if (!hasVideoFrame && !hasPlaybackProgress && localRecoveryAttempts < 3) {
        _localErrorRecoveryAttempts[uri] = localRecoveryAttempts + 1;
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'viewer requested local controller recreation after early error without frame',
            data: {
              'uri': uri,
              'attempt': localRecoveryAttempts + 1,
            },
          ),
        );
        final recreatedController = await context.read<VideoConductor>().recreateController(controllerEntry);
        if (!mounted) return;
        setState(() {});
        if (token == _autoPlayRequestToken && isCurrent()) {
          await Future.delayed(const Duration(milliseconds: 120) * timeDilation);
          if (token == _autoPlayRequestToken && isCurrent()) {
            await _autoPlayVideo(recreatedController, isCurrent, resumeTimeMillis: resumeTimeMillis);
            return;
          }
        }
      }
    }
    if (token == _autoPlayRequestToken && isCurrent() && videoController.status == VideoStatus.error) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'viewer stream failed with error status',
          data: {'uri': uri},
        ),
      );
    }

    // playing controllers are paused when the entry changes,
    // but the controller may still be preparing (not yet playing) when this happens
    // so we make sure the current entry is still the same to keep playing
    if (token != _autoPlayRequestToken || !isCurrent()) {
      await videoController.pause();
      unawaited(
        remoteMediaLogService.log(
          'focus',
          'paused non-current video after focus changed',
          data: {
            'uri': videoController.entry.uri,
          },
        ),
      );
    }
  }

  Future<void> pauseVideoControllers() {
    _autoPlayRequestToken++;
    return context.read<VideoConductor>().pauseAll();
  }

  static const _pipRatioMax = Rational(43, 18);
  static const _pipRatioMin = Rational(18, 43);

  Future<void> updatePictureInPicture(BuildContext context) async {
    if (!device.supportPictureInPicture) return;

    if (context.mounted && settings.videoBackgroundMode == VideoBackgroundMode.pip) {
      final playingController = context.read<VideoConductor>().getPlayingController();
      if (playingController != null) {
        final entrySize = playingController.entry.displaySize;
        final entryAspectRatio = entrySize.aspectRatio;
        final Rational pipAspectRatio;
        if (entryAspectRatio > _pipRatioMax.aspectRatio) {
          pipAspectRatio = _pipRatioMax;
        } else if (entryAspectRatio < _pipRatioMin.aspectRatio) {
          pipAspectRatio = _pipRatioMin;
        } else {
          pipAspectRatio = Rational(entrySize.width.round(), entrySize.height.round());
        }

        final viewSize = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
        final fittedSize = applyBoxFit(BoxFit.contain, entrySize, viewSize).destination;
        final sourceRectHint = Rectangle<int>(
          ((viewSize.width - fittedSize.width) / 2).round(),
          ((viewSize.height - fittedSize.height) / 2).round(),
          fittedSize.width.round(),
          fittedSize.height.round(),
        );

        try {
          final status = await Floating().enable(
            OnLeavePiP(
              aspectRatio: pipAspectRatio,
              sourceRectHint: sourceRectHint,
            ),
          );
          debugPrint('Enabled picture-in-picture with status=$status');
          return;
        } on PlatformException catch (e, stack) {
          await reportService.recordError(e, stack);
        }
      }
    }

    debugPrint('Cancelling picture-in-picture');
    await Floating().cancelOnLeavePiP();
  }
}
