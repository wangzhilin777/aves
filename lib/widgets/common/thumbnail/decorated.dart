import 'dart:async';
import 'dart:math' as math;

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/images.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/fx/borders.dart';
import 'package:aves/widgets/common/grid/overlay.dart';
import 'package:aves/widgets/common/providers/viewer_entry_provider.dart';
import 'package:aves/widgets/common/grid/sections/mosaic/section_layout_builder.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/common/thumbnail/notifications.dart';
import 'package:aves/widgets/common/thumbnail/overlay.dart';
import 'package:aves/widgets/viewer/video/conductor.dart';
import 'package:aves/widgets/viewer/viewer_pop_result.dart';
import 'package:aves/widgets/viewer/visual/video/video_view.dart';
import 'package:aves_video/aves_video.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DecoratedThumbnail extends StatelessWidget {
  final AvesEntry entry;
  final double tileExtent;
  final ValueNotifier<bool>? cancellableNotifier;
  final ValueListenable<AvesEntry?>? playbackFocusNotifier;
  final ValueNotifier<ViewerPopResult?>? viewerReturnNotifier;
  final ValueListenable<bool>? isScrollingNotifier;
  final bool isMosaic, selectable, highlightable;
  final Object? Function()? heroTagger;
  final HeroPlaceholderBuilder? heroPlaceholderBuilder;
  final TransitionBuilder? imageDecorator;

  static Color borderColor(BuildContext context) => Theme.of(context).dividerColor;

  static double borderWidth(BuildContext context) => AvesBorder.straightBorderWidth(context);

  const DecoratedThumbnail({
    super.key,
    required this.entry,
    required this.tileExtent,
    this.cancellableNotifier,
    this.playbackFocusNotifier,
    this.viewerReturnNotifier,
    this.isScrollingNotifier,
    this.isMosaic = false,
    this.selectable = true,
    this.highlightable = true,
    this.heroTagger,
    this.heroPlaceholderBuilder,
    this.imageDecorator,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: entry.visualChangeNotifier,
      builder: (context, child) {
        final double thumbnailHeight = tileExtent;
        final double thumbnailWidth;
        final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
        final isRemoteManagedEntry = remoteProtocol != null || entry.isRemoteCachedMedia || remoteMediaService.hasVirtualRemoteRef(entry.uri);
        if (isMosaic) {
          thumbnailWidth =
              thumbnailHeight *
              entry.displayAspectRatio.clamp(
                MosaicSectionLayoutBuilder.minThumbnailAspectRatio,
                MosaicSectionLayoutBuilder.maxThumbnailAspectRatio,
              );
        } else {
          thumbnailWidth = tileExtent;
        }

        Widget buildBaseThumbnail({required bool suppressForLargeRemoteCurrentVideo}) {
          final hasRemotePreviewCover =
              entry.isVideo &&
              (remoteMediaService.getStandaloneFavouriteThumbnailProvider(
                        entry,
                        extent: math.max(thumbnailWidth, thumbnailHeight),
                      ) !=
                      null ||
                  remoteMediaService.getRemotePreviewThumbnailProvider(
                        entry,
                        extent: math.max(thumbnailWidth, thumbnailHeight),
                      ) !=
                      null);
          if (suppressForLargeRemoteCurrentVideo && !hasRemotePreviewCover) {
            return const SizedBox.expand();
          }
          if (isRemoteManagedEntry && entry.isVideo) {
            return _RemoteCachedThumbnailImage(
              entry: entry,
              width: thumbnailWidth,
              height: thumbnailHeight,
              fit: isMosaic ? BoxFit.cover : (entry.isSvg ? BoxFit.contain : BoxFit.cover),
            );
          }
          return ThumbnailImage(
            entry: entry,
            extent: tileExtent,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            isMosaic: isMosaic,
            cancellableNotifier: cancellableNotifier,
            heroTag: heroTagger?.call(),
            heroPlaceholderBuilder: heroPlaceholderBuilder,
          );
        }

        final shouldWatchCurrentVideoState = playbackFocusNotifier != null && entry.isVideo;
        Widget child = shouldWatchCurrentVideoState
            ? ValueListenableBuilder<AvesEntry?>(
                valueListenable: playbackFocusNotifier!,
                builder: (context, currentEntry, _) {
                  final suppressForLargeRemoteCurrentVideo = currentEntry?.uri == entry.uri && remoteMediaService.isLargeRemoteVideoEntry(entry);
                  return buildBaseThumbnail(suppressForLargeRemoteCurrentVideo: suppressForLargeRemoteCurrentVideo);
                },
              )
            : buildBaseThumbnail(suppressForLargeRemoteCurrentVideo: false);

        child = Stack(
          fit: StackFit.passthrough,
          children: [
            imageDecorator?.call(context, child) ?? child,
            ThumbnailEntryOverlay(entry: entry),
            if (selectable) ...[
              GridItemSelectionOverlay<AvesEntry>(
                item: entry,
                padding: const EdgeInsets.all(2),
              ),
              ThumbnailZoomOverlay(
                onZoom: () => OpenViewerNotification(entry).dispatch(context),
              ),
            ],
            if (playbackFocusNotifier != null && entry.isVideo)
              _AutoPlayVideoThumbnail(
                entry: entry,
                isCurrentNotifier: playbackFocusNotifier!,
                isScrollingNotifier: isScrollingNotifier,
                viewerReturnNotifier: viewerReturnNotifier,
                isMosaic: isMosaic,
                tileExtent: tileExtent,
              ),
            if (highlightable) ThumbnailHighlightOverlay(entry: entry),
          ],
        );

        return Container(
          foregroundDecoration: BoxDecoration(
            border: Border.fromBorderSide(
              BorderSide(
                color: borderColor(context),
                width: borderWidth(context),
              ),
            ),
          ),
          width: thumbnailWidth,
          height: thumbnailHeight,
          child: child,
        );
      },
    );
  }
}

class _RemoteCachedThumbnailImage extends StatefulWidget {
  final AvesEntry entry;
  final double width;
  final double height;
  final BoxFit fit;

  const _RemoteCachedThumbnailImage({
    required this.entry,
    required this.width,
    required this.height,
    required this.fit,
  });

  @override
  State<_RemoteCachedThumbnailImage> createState() => _RemoteCachedThumbnailImageState();
}

class _RemoteCachedThumbnailImageState extends State<_RemoteCachedThumbnailImage> {
  bool _warmupRequested = false;

  void _scheduleWarmupIfNeeded(AvesEntry entry) {
    if (_warmupRequested) return;
    final isStandaloneFavourite = remoteMediaService.isStandaloneFavouriteEntry(
      entry,
      settings.remoteStandaloneFavouritePaths,
    );
    if (!isStandaloneFavourite || !entry.isVideo) return;
    _warmupRequested = true;
    unawaited(
      remoteMediaService.warmupStandaloneFavouriteThumbnailIfNeeded(
        entry,
        trigger: 'favourite_tab_return',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final standaloneFavouriteProvider = remoteMediaService.getStandaloneFavouriteThumbnailProvider(
      entry,
      extent: math.max(widget.width, widget.height),
    );
    final remotePreviewProvider = remoteMediaService.getRemotePreviewThumbnailProvider(
      entry,
      extent: math.max(widget.width, widget.height),
    );
    final provider =
        standaloneFavouriteProvider ??
        remotePreviewProvider ??
        entry.cachedThumbnails.sortedBy<num>((provider) => provider.key.extent).lastOrNull;
    if (provider == null) {
      _scheduleWarmupIfNeeded(entry);
      return ThumbnailImage(
        entry: entry,
        extent: math.max(widget.width, widget.height),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        fit: widget.fit,
        showLoadingBackground: false,
      );
    }
    return Image(
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
    );
  }
}

class _AutoPlayVideoThumbnail extends StatefulWidget {
  final AvesEntry entry;
  final ValueListenable<AvesEntry?> isCurrentNotifier;
  final ValueListenable<bool>? isScrollingNotifier;
  final ValueNotifier<ViewerPopResult?>? viewerReturnNotifier;
  final bool isMosaic;
  final double tileExtent;

  const _AutoPlayVideoThumbnail({
    required this.entry,
    required this.isCurrentNotifier,
    this.isScrollingNotifier,
    this.viewerReturnNotifier,
    required this.isMosaic,
    required this.tileExtent,
  });

  @override
  State<_AutoPlayVideoThumbnail> createState() => _AutoPlayVideoThumbnailState();
}

class _AutoPlayVideoThumbnailState extends State<_AutoPlayVideoThumbnail> {
  AvesEntry get entry => widget.entry;

  bool get isCurrent => widget.isCurrentNotifier.value == entry;

  AvesVideoController? _controller;
  int _playToken = 0;
  bool _autoPlayInFlight = false;
  bool _videoSurfaceVisible = false;
  bool _ftpPreviewVisualSettled = false;
  bool _playRequestedForCurrentFocus = false;
  String? _lastAutoPlayUri;
  String? _lastDecisionKey;
  int _lastAutoPlayAttemptMillis = 0;
  int _lastAutoPlayAnyAttemptMillis = 0;
  final Map<String, int> _lastAutoPlayErrorAtMillisByUri = {};
  final Map<String, int> _lastDecodedFrameAtMillisByUri = {};
  StreamSubscription<VideoStatus>? _statusSubscription;
  StreamSubscription<int>? _positionSubscription;
  Timer? _videoSurfaceRevealTimer;
  Timer? _ftpPreviewSettleTimer;
  ViewerEntryNotifier? _viewerEntryNotifier;
  late Settings _settings;
  late VideoConductor _videoConductor;
  bool _hasPlaybackProgress = false;
  final Map<String, int> _lastLocalCacheProbeAtMillisByUri = {};
  String? _lastSurfaceDecisionKey;
  String? _lastControllerLifecycleKey;
  String? _lastTileSurfaceSnapshotKey;
  bool _standaloneFavouriteCoverCaptureInFlight = false;
  bool _standaloneFavouriteCoverCaptured = false;
  bool _remotePreviewCoverCaptureInFlight = false;
  bool _remotePreviewCoverCaptured = false;

  ViewerPopResult? get _viewerReturn => widget.viewerReturnNotifier?.value;

  bool _shouldAttachPreheatedControllerForNonCurrentTile({
    required RemoteProtocol remoteProtocol,
    required AvesVideoController preheatedController,
  }) {
    if (remoteProtocol == RemoteProtocol.webdav) {
      if (identical(_controller, preheatedController)) return false;
      final currentController = _controller;
      if (currentController == null) return true;

      final currentHasRenderableVisual =
          _hasDecodedFrame(currentController) ||
          currentController.firstFrameRenderedNotifier.value ||
          currentController.currentPosition > 0 ||
          currentController.status == VideoStatus.paused ||
          currentController.status == VideoStatus.completed;
      final incomingHasRenderableVisual =
          _hasDecodedFrame(preheatedController) ||
          preheatedController.firstFrameRenderedNotifier.value ||
          preheatedController.currentPosition > 0 ||
          preheatedController.status == VideoStatus.paused ||
          preheatedController.status == VideoStatus.completed;
      if (currentHasRenderableVisual && !incomingHasRenderableVisual) {
        return false;
      }
      if (currentController.isReady && !preheatedController.isReady && !incomingHasRenderableVisual) {
        return false;
      }
      return true;
    } else if (remoteProtocol == RemoteProtocol.ftp) {
      return !identical(_controller, preheatedController);
    } else if (remoteProtocol == RemoteProtocol.sftp) {
      return !identical(_controller, preheatedController);
    } else if (remoteProtocol == RemoteProtocol.smb) {
      return !identical(_controller, preheatedController);
    }
    return true;
  }

  bool _hasDecodedFrame(AvesVideoController? controller) {
    final decodedSize = controller?.decodedVideoSizeNotifier.value;
    return decodedSize != null && decodedSize.width > 1 && decodedSize.height > 1;
  }

  bool _shouldSuppressAutoPlayWhileScrolling(RemoteProtocol? remoteProtocol) {
    final isScrolling = widget.isScrollingNotifier?.value == true;
    if (!isScrolling) return false;
    if (remoteProtocol == RemoteProtocol.webdav) {
      return true;
    } else if (remoteProtocol == RemoteProtocol.ftp) {
      return true;
    } else if (remoteProtocol == RemoteProtocol.sftp) {
      return true;
    } else if (remoteProtocol == RemoteProtocol.smb) {
      return true;
    } else if (remoteProtocol == null) {
      return true;
    }
    return false;
  }

  bool _shouldSuppressPreheatedAttachWhileScrolling(RemoteProtocol? remoteProtocol) {
    final isScrolling = widget.isScrollingNotifier?.value == true;
    if (!isScrolling) return false;
    if (remoteProtocol == RemoteProtocol.webdav) {
      return true;
    } else if (remoteProtocol == RemoteProtocol.ftp) {
      return true;
    } else if (remoteProtocol == RemoteProtocol.sftp) {
      return true;
    } else if (remoteProtocol == RemoteProtocol.smb) {
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    widget.isCurrentNotifier.addListener(_onCurrentChanged);
    widget.isScrollingNotifier?.addListener(_onCurrentChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCurrentChanged());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<Settings>();
    _videoConductor = context.read<VideoConductor>();
    final viewerEntryNotifier = context.read<ViewerEntryNotifier>();
    if (!identical(_viewerEntryNotifier, viewerEntryNotifier)) {
      _viewerEntryNotifier?.removeListener(_onCurrentChanged);
      _viewerEntryNotifier = viewerEntryNotifier;
      _viewerEntryNotifier?.addListener(_onCurrentChanged);
    }
  }

  @override
  void didUpdateWidget(covariant _AutoPlayVideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCurrentNotifier != widget.isCurrentNotifier) {
      oldWidget.isCurrentNotifier.removeListener(_onCurrentChanged);
      widget.isCurrentNotifier.addListener(_onCurrentChanged);
    }
    if (oldWidget.isScrollingNotifier != widget.isScrollingNotifier) {
      oldWidget.isScrollingNotifier?.removeListener(_onCurrentChanged);
      widget.isScrollingNotifier?.addListener(_onCurrentChanged);
    }
    if (oldWidget.entry != widget.entry) {
      _unbindController(_controller);
      _controller = null;
      _videoSurfaceVisible = false;
      _ftpPreviewVisualSettled = false;
      _playRequestedForCurrentFocus = false;
      _hasPlaybackProgress = false;
      _standaloneFavouriteCoverCaptureInFlight = false;
      _standaloneFavouriteCoverCaptured = false;
      _remotePreviewCoverCaptureInFlight = false;
      _remotePreviewCoverCaptured = false;
    }
    _onCurrentChanged();
  }

  @override
  void dispose() {
    widget.isCurrentNotifier.removeListener(_onCurrentChanged);
    widget.isScrollingNotifier?.removeListener(_onCurrentChanged);
    _viewerEntryNotifier?.removeListener(_onCurrentChanged);
    _playToken++;
    _videoSurfaceRevealTimer?.cancel();
    _statusSubscription?.cancel();
    if (_controller?.isPlaying == true) {
      _controller?.pause();
    }
    super.dispose();
  }

  void _bindController(AvesVideoController? controller) {
    if (controller == null) return;
    controller.decodedVideoSizeNotifier.addListener(_onControllerVisualStateChanged);
    controller.firstFrameRenderedNotifier.addListener(_onControllerVisualStateChanged);
    _statusSubscription = controller.statusStream.listen((_) => _onControllerVisualStateChanged());
    _positionSubscription = controller.positionStream.listen((position) {
      final hadProgress = _hasPlaybackProgress;
      _hasPlaybackProgress = position > 0;
      if (hadProgress != _hasPlaybackProgress) {
        _onControllerVisualStateChanged();
      }
    });
    _hasPlaybackProgress = controller.currentPosition > 0;
    _onControllerVisualStateChanged();
  }

  void _unbindController(AvesVideoController? controller) {
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _videoSurfaceRevealTimer?.cancel();
    _ftpPreviewSettleTimer?.cancel();
    _videoSurfaceRevealTimer = null;
    _ftpPreviewSettleTimer = null;
    controller?.decodedVideoSizeNotifier.removeListener(_onControllerVisualStateChanged);
    controller?.firstFrameRenderedNotifier.removeListener(_onControllerVisualStateChanged);
    _hasPlaybackProgress = false;
  }

  void _setController(AvesVideoController controller) {
    if (identical(_controller, controller)) return;
    final previousController = _controller;
    _logControllerLifecycle(
      event: 'swap_controller',
      controller: controller,
      previousController: previousController,
    );
    _unbindController(_controller);
    _controller = controller;
    _videoSurfaceVisible = false;
    _bindController(controller);
  }

  void _logControllerLifecycle({
    required String event,
    required AvesVideoController? controller,
    AvesVideoController? previousController,
    Map<String, Object?> extra = const {},
  }) {
    if (!settings.remoteLogEnabled) return;
    final key = '$event|$entry.uri|$isCurrent|${controller?.hashCode}|${previousController?.hashCode}|${controller?.status.name}|${controller?.isPlaying}|${controller?.isReady}|${_viewerEntryNotifier?.value?.uri}|$extra';
    if (_lastControllerLifecycleKey == key) return;
    _lastControllerLifecycleKey = key;
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'grid preview controller lifecycle',
        data: {
          'entryUri': entry.uri,
          'entryPath': entry.path,
          'protocol': remoteMediaService.getRemoteProtocolForEntry(entry)?.name,
          'event': event,
          'isCurrent': isCurrent,
          'viewerEntryUri': _viewerEntryNotifier?.value?.uri,
          'controllerHash': controller?.hashCode,
          'previousControllerHash': previousController?.hashCode,
          'controllerStatus': controller?.status.name,
          'controllerIsPlaying': controller?.isPlaying,
          'controllerIsReady': controller?.isReady,
          'controllerPositionMillis': controller?.currentPosition,
          ...extra,
        },
      ),
    );
  }

  Future<bool> _tryPlayController(
    AvesVideoController controller, {
    required String stage,
    RemoteProtocol? remoteProtocol,
  }) async {
    try {
      await controller.play();
      return true;
    } catch (error) {
      _playRequestedForCurrentFocus = false;
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'grid preview play skipped because controller was no longer usable',
          data: {
            'uri': entry.uri,
            'stage': stage,
            'protocol': remoteProtocol?.name,
            'error': '$error',
          },
        ),
      );
      return false;
    }
  }

  Future<void> _applyViewerReturnResumeIfNeeded(
    AvesVideoController controller,
    RemoteProtocol? remoteProtocol,
  ) async {
    final viewerReturn = _viewerReturn;
    final positionMillis = viewerReturn?.previewPositionMillis;
    if (viewerReturn?.entry.uri != entry.uri || positionMillis == null || positionMillis <= 0) return;

    try {
      if (remoteProtocol == RemoteProtocol.webdav) {
        await controller.seekTo(positionMillis);
      } else if (remoteProtocol == RemoteProtocol.ftp) {
        await controller.seekTo(positionMillis);
      } else if (remoteProtocol == RemoteProtocol.sftp) {
        await controller.seekTo(positionMillis);
      } else if (remoteProtocol == RemoteProtocol.smb) {
        await controller.seekTo(positionMillis);
      } else {
        await controller.seekTo(positionMillis);
      }
      widget.viewerReturnNotifier?.value = null;
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'applied viewer return preview resume position',
          data: {
            'uri': entry.uri,
            'protocol': remoteProtocol?.name,
            'positionMillis': positionMillis,
          },
        ),
      );
    } catch (_) {}
  }

  void _logTileSurfaceSnapshot({
    required AvesVideoController controller,
    required RemoteProtocol? remoteProtocol,
    required bool show,
    required bool keepLastFrameVisible,
    required bool hasDecodedFrame,
    required bool hasFirstFrameRendered,
    required bool hasPreviewFrame,
    required bool hasRenderableFrame,
    required bool inChunkedErrorCooldown,
    required bool remoteForceVisible,
    required bool suppressNonCurrentChunkedPreviewSurface,
  }) {
    if (!settings.remoteLogEnabled) return;
    final key =
        '${entry.uri}|${controller.hashCode}|$show|$_videoSurfaceVisible|$keepLastFrameVisible|$hasDecodedFrame|$hasFirstFrameRendered|$hasPreviewFrame|$hasRenderableFrame|$inChunkedErrorCooldown|$remoteForceVisible|$suppressNonCurrentChunkedPreviewSurface|$isCurrent|${controller.status.name}|${controller.isPlaying}|${controller.isReady}|${controller.currentPosition}';
    if (_lastTileSurfaceSnapshotKey == key) return;
    _lastTileSurfaceSnapshotKey = key;
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'grid preview tile surface snapshot',
        data: {
          'entryUri': entry.uri,
          'entryPath': entry.path,
          'protocol': remoteProtocol?.name,
          'controllerHash': controller.hashCode,
          'controllerStatus': controller.status.name,
          'controllerIsPlaying': controller.isPlaying,
          'controllerIsReady': controller.isReady,
          'controllerPositionMillis': controller.currentPosition,
          'isCurrent': isCurrent,
          'viewerEntryUri': _viewerEntryNotifier?.value?.uri,
          'show': show,
          'surfaceVisibleFlag': _videoSurfaceVisible,
          'playRequestedForCurrentFocus': _playRequestedForCurrentFocus,
          'keepLastFrameVisible': keepLastFrameVisible,
          'hasDecodedFrame': hasDecodedFrame,
          'hasFirstFrameRendered': hasFirstFrameRendered,
          'hasPreviewFrame': hasPreviewFrame,
          'hasRenderableFrame': hasRenderableFrame,
          'inChunkedErrorCooldown': inChunkedErrorCooldown,
          'remoteForceVisible': remoteForceVisible,
          'suppressNonCurrentChunkedPreviewSurface': suppressNonCurrentChunkedPreviewSurface,
        },
      ),
    );
  }

  void _logSurfaceDecision({
    required String event,
    required AvesVideoController controller,
    required RemoteProtocol? remoteProtocol,
    required bool hasDecodedFrame,
    required bool hasFirstFrameRendered,
    required bool hasRenderableFrame,
    required bool holdLastFrame,
    required bool inChunkedErrorCooldown,
    required bool currentReadyForReveal,
    required bool canReveal,
  }) {
    if (!settings.remoteLogEnabled) return;
    final key =
        '$event|${controller.status.name}|${controller.isPlaying}|${controller.isReady}|$hasDecodedFrame|$hasFirstFrameRendered|$_hasPlaybackProgress|$hasRenderableFrame|$holdLastFrame|$inChunkedErrorCooldown|$currentReadyForReveal|$canReveal|$_videoSurfaceVisible|${_videoSurfaceRevealTimer != null}|$isCurrent|${_viewerEntryNotifier?.value != null}';
    if (_lastSurfaceDecisionKey == key) return;
    _lastSurfaceDecisionKey = key;
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'grid preview surface decision',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'protocol': remoteProtocol?.name,
          'event': event,
          'status': controller.status.name,
          'isPlaying': controller.isPlaying,
          'isReady': controller.isReady,
          'positionMillis': controller.currentPosition,
          'hasDecodedFrame': hasDecodedFrame,
          'hasFirstFrameRendered': hasFirstFrameRendered,
          'hasPlaybackProgress': _hasPlaybackProgress,
          'hasRenderableFrame': hasRenderableFrame,
          'holdLastFrame': holdLastFrame,
          'inChunkedErrorCooldown': inChunkedErrorCooldown,
          'currentReadyForReveal': currentReadyForReveal,
          'canReveal': canReveal,
          'surfaceVisible': _videoSurfaceVisible,
          'revealTimerPending': _videoSurfaceRevealTimer != null,
          'isCurrent': isCurrent,
          'viewerActive': _viewerEntryNotifier?.value != null,
          'playRequestedForCurrentFocus': _playRequestedForCurrentFocus,
        },
      ),
    );
  }

  void _onControllerVisualStateChanged() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    final decodedSize = controller.decodedVideoSizeNotifier.value;
    if (decodedSize != null && decodedSize.width > 1 && decodedSize.height > 1) {
      final nextWidth = decodedSize.width.round();
      final nextHeight = decodedSize.height.round();
      if (entry.width != nextWidth || entry.height != nextHeight) {
        entry.width = nextWidth;
        entry.height = nextHeight;
        entry.visualChangeNotifier.notify();
      }
    }
    final isViewerActive = _viewerEntryNotifier?.value != null;
    final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
    final isFtpPreview = remoteProtocol == RemoteProtocol.ftp;
    final isSftpPreview = remoteProtocol == RemoteProtocol.sftp;
    final isSmbPreview = remoteProtocol == RemoteProtocol.smb;
    final isWebdavPreview = remoteProtocol == RemoteProtocol.webdav;
    final isChunkedRemotePreview = isFtpPreview || isSftpPreview || isSmbPreview;
    final isRemoteManagedEntry = remoteProtocol != null || entry.isRemoteCachedMedia || remoteMediaService.hasVirtualRemoteRef(entry.uri);
    final hasDecodedFrame = _hasDecodedFrame(controller);
    final hasFirstFrameRendered = controller.firstFrameRenderedNotifier.value;
    final hasPreviewFrame = hasDecodedFrame || hasFirstFrameRendered;
    final hasRenderableFrame = hasDecodedFrame || hasFirstFrameRendered || _hasPlaybackProgress || controller.currentPosition > 0;
    _scheduleStandaloneFavouriteCoverCaptureIfNeeded(
      controller: controller,
      hasRenderableFrame: hasRenderableFrame,
      hasFirstFrameRendered: hasFirstFrameRendered,
    );
    _scheduleRemotePreviewCoverCaptureIfNeeded(
      controller: controller,
      hasRenderableFrame: hasRenderableFrame,
      hasFirstFrameRendered: hasFirstFrameRendered,
    );
    if (hasDecodedFrame) {
      _lastDecodedFrameAtMillisByUri[entry.uri] = DateTime.now().millisecondsSinceEpoch;
    }
    final keepLastFrameVisible = controller.status == VideoStatus.paused || controller.status == VideoStatus.completed;
    final isRemotePreviewCandidate = isRemoteManagedEntry && !controller.isPlaying;
    final keepPreviewFrameVisibleOnChunkedError = isCurrent && isChunkedRemotePreview && controller.status == VideoStatus.error && (isFtpPreview ? hasFirstFrameRendered : hasPreviewFrame);
    final holdLastFrame = (keepLastFrameVisible && hasRenderableFrame) || keepPreviewFrameVisibleOnChunkedError;
    final errorCooldownStartedAt = _lastAutoPlayErrorAtMillisByUri[entry.uri];
    final inChunkedErrorCooldown = isChunkedRemotePreview && errorCooldownStartedAt != null && DateTime.now().millisecondsSinceEpoch - errorCooldownStartedAt < 4000;
    final currentReadyForReveal = isCurrent
        ? isFtpPreview
              ? (holdLastFrame || hasFirstFrameRendered || keepPreviewFrameVisibleOnChunkedError)
              : isSftpPreview
              ? (holdLastFrame || hasPreviewFrame || keepPreviewFrameVisibleOnChunkedError)
              : isSmbPreview
              ? (holdLastFrame || hasPreviewFrame || keepPreviewFrameVisibleOnChunkedError)
              : remoteProtocol == RemoteProtocol.webdav
              ? (holdLastFrame || hasRenderableFrame)
              : isRemoteManagedEntry
              ? (holdLastFrame || hasRenderableFrame)
              : (keepLastFrameVisible || controller.isPlaying || hasDecodedFrame)
        : false;
    final suppressNonCurrentWebdavPreviewSurfaceWhileScrolling = !isCurrent && isWebdavPreview && widget.isScrollingNotifier?.value == true;
    final suppressNonCurrentFtpPreviewSurfaceWhileScrolling = !isCurrent && isFtpPreview && widget.isScrollingNotifier?.value == true;
    final suppressNonCurrentSftpPreviewSurfaceWhileScrolling = !isCurrent && isSftpPreview && widget.isScrollingNotifier?.value == true;
    final suppressNonCurrentSmbPreviewSurfaceWhileScrolling = !isCurrent && isSmbPreview && widget.isScrollingNotifier?.value == true;
    final suppressNonCurrentRemotePreviewSurfaceWhileScrolling =
        suppressNonCurrentWebdavPreviewSurfaceWhileScrolling || suppressNonCurrentFtpPreviewSurfaceWhileScrolling || suppressNonCurrentSftpPreviewSurfaceWhileScrolling || suppressNonCurrentSmbPreviewSurfaceWhileScrolling;
    final shouldKeepExistingSurfaceForHandoff =
        !isCurrent &&
        hasRenderableFrame &&
        (_videoSurfaceVisible || _playRequestedForCurrentFocus || holdLastFrame);
    final canReveal =
        !isViewerActive &&
        (!suppressNonCurrentRemotePreviewSurfaceWhileScrolling || shouldKeepExistingSurfaceForHandoff) &&
        ((currentReadyForReveal) ||
            (!isCurrent &&
                isRemotePreviewCandidate &&
                hasRenderableFrame &&
                (_videoSurfaceVisible || _playRequestedForCurrentFocus || holdLastFrame)));
    if (!canReveal) {
      _logSurfaceDecision(
        event: _videoSurfaceVisible ? 'hide_surface' : 'cannot_reveal_surface',
        controller: controller,
        remoteProtocol: remoteProtocol,
        hasDecodedFrame: hasDecodedFrame,
        hasFirstFrameRendered: hasFirstFrameRendered,
        hasRenderableFrame: hasRenderableFrame,
        holdLastFrame: holdLastFrame,
        inChunkedErrorCooldown: inChunkedErrorCooldown,
        currentReadyForReveal: currentReadyForReveal,
        canReveal: canReveal,
      );
      _videoSurfaceRevealTimer?.cancel();
      _videoSurfaceRevealTimer = null;
      if (_videoSurfaceVisible) {
        setState(() {
          _videoSurfaceVisible = false;
          _ftpPreviewVisualSettled = false;
        });
      }
      return;
    }
    if (_videoSurfaceVisible || _videoSurfaceRevealTimer != null) {
      _logSurfaceDecision(
        event: _videoSurfaceVisible ? 'surface_already_visible' : 'reveal_timer_already_pending',
        controller: controller,
        remoteProtocol: remoteProtocol,
        hasDecodedFrame: hasDecodedFrame,
        hasFirstFrameRendered: hasFirstFrameRendered,
        hasRenderableFrame: hasRenderableFrame,
        holdLastFrame: holdLastFrame,
        inChunkedErrorCooldown: inChunkedErrorCooldown,
        currentReadyForReveal: currentReadyForReveal,
        canReveal: canReveal,
      );
      return;
    }
    _logSurfaceDecision(
      event: 'schedule_reveal_timer',
      controller: controller,
      remoteProtocol: remoteProtocol,
      hasDecodedFrame: hasDecodedFrame,
      hasFirstFrameRendered: hasFirstFrameRendered,
      hasRenderableFrame: hasRenderableFrame,
      holdLastFrame: holdLastFrame,
      inChunkedErrorCooldown: inChunkedErrorCooldown,
      currentReadyForReveal: currentReadyForReveal,
      canReveal: canReveal,
    );
    _videoSurfaceRevealTimer = Timer(const Duration(milliseconds: 220), () {
      _videoSurfaceRevealTimer = null;
      final activeController = _controller;
      if (!mounted || activeController == null) return;
      final activeRemoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
      final isActiveRemoteManagedEntry = activeRemoteProtocol != null || entry.isRemoteCachedMedia || remoteMediaService.hasVirtualRemoteRef(entry.uri);
      final activeHasDecodedFrame = _hasDecodedFrame(activeController);
      final activeHasFirstFrameRendered = activeController.firstFrameRenderedNotifier.value;
      final activeHasRenderableFrame = activeHasDecodedFrame || activeHasFirstFrameRendered || _hasPlaybackProgress || activeController.currentPosition > 0;
      final activeKeepLastFrameVisible = activeController.status == VideoStatus.paused || activeController.status == VideoStatus.completed;
      final activeIsChunkedRemotePreview = activeRemoteProtocol == RemoteProtocol.ftp || activeRemoteProtocol == RemoteProtocol.sftp || activeRemoteProtocol == RemoteProtocol.smb;
      final isActiveRemotePreviewCandidate = isActiveRemoteManagedEntry && !activeController.isPlaying;
      final activeHoldLastFrame = activeKeepLastFrameVisible && activeHasRenderableFrame;
      final activeErrorCooldownStartedAt = _lastAutoPlayErrorAtMillisByUri[entry.uri];
      final activeInChunkedErrorCooldown = activeIsChunkedRemotePreview && activeErrorCooldownStartedAt != null && DateTime.now().millisecondsSinceEpoch - activeErrorCooldownStartedAt < 4000;
      final activeIsFtpPreview = activeRemoteProtocol == RemoteProtocol.ftp;
      final activeIsSftpPreview = activeRemoteProtocol == RemoteProtocol.sftp;
      final activeIsSmbPreview = activeRemoteProtocol == RemoteProtocol.smb;
      final activeIsWebdavPreview = activeRemoteProtocol == RemoteProtocol.webdav;
      final currentReadyForReveal = isCurrent
          ? activeIsFtpPreview
                ? (activeHoldLastFrame || activeController.firstFrameRenderedNotifier.value)
                : activeIsSftpPreview
                ? (activeHoldLastFrame || activeHasDecodedFrame || activeHasFirstFrameRendered || _hasPlaybackProgress || activeController.currentPosition > 0)
                : activeIsSmbPreview
                ? (activeHoldLastFrame || activeHasDecodedFrame || activeHasFirstFrameRendered || _hasPlaybackProgress || activeController.currentPosition > 0)
                : activeIsChunkedRemotePreview
                ? (activeHoldLastFrame || activeController.isPlaying || (activeInChunkedErrorCooldown && _playRequestedForCurrentFocus))
                : isActiveRemoteManagedEntry
                ? (activeHoldLastFrame || activeHasRenderableFrame)
                : (activeKeepLastFrameVisible || activeController.isPlaying || activeHasDecodedFrame)
          : false;
      final suppressNonCurrentWebdavPreviewSurfaceWhileScrolling = !isCurrent && activeIsWebdavPreview && widget.isScrollingNotifier?.value == true;
      final suppressNonCurrentFtpPreviewSurfaceWhileScrolling = !isCurrent && activeIsFtpPreview && widget.isScrollingNotifier?.value == true;
      final suppressNonCurrentSftpPreviewSurfaceWhileScrolling = !isCurrent && activeIsSftpPreview && widget.isScrollingNotifier?.value == true;
      final suppressNonCurrentSmbPreviewSurfaceWhileScrolling = !isCurrent && activeIsSmbPreview && widget.isScrollingNotifier?.value == true;
      final suppressNonCurrentRemotePreviewSurfaceWhileScrolling =
          suppressNonCurrentWebdavPreviewSurfaceWhileScrolling || suppressNonCurrentFtpPreviewSurfaceWhileScrolling || suppressNonCurrentSftpPreviewSurfaceWhileScrolling || suppressNonCurrentSmbPreviewSurfaceWhileScrolling;
      final shouldKeepExistingSurfaceForHandoff =
          !isCurrent &&
          activeHasRenderableFrame &&
          (_videoSurfaceVisible || _playRequestedForCurrentFocus || activeHoldLastFrame);
      final shouldReveal =
          (_viewerEntryNotifier?.value == null) &&
          (!suppressNonCurrentRemotePreviewSurfaceWhileScrolling || shouldKeepExistingSurfaceForHandoff) &&
          ((currentReadyForReveal) ||
              (!isCurrent &&
                  isActiveRemotePreviewCandidate &&
                  activeHasRenderableFrame &&
                  (_videoSurfaceVisible || _playRequestedForCurrentFocus || activeHoldLastFrame)));
      if (!shouldReveal || _videoSurfaceVisible) {
        _logSurfaceDecision(
          event: !shouldReveal ? 'reveal_timer_completed_without_reveal' : 'reveal_timer_completed_but_already_visible',
          controller: activeController,
          remoteProtocol: activeRemoteProtocol,
          hasDecodedFrame: activeHasDecodedFrame,
          hasFirstFrameRendered: activeHasFirstFrameRendered,
          hasRenderableFrame: activeHasRenderableFrame,
          holdLastFrame: activeHoldLastFrame,
          inChunkedErrorCooldown: activeInChunkedErrorCooldown,
          currentReadyForReveal: currentReadyForReveal,
          canReveal: shouldReveal,
        );
        return;
      }
      _logSurfaceDecision(
        event: 'reveal_surface',
        controller: activeController,
        remoteProtocol: activeRemoteProtocol,
        hasDecodedFrame: activeHasDecodedFrame,
        hasFirstFrameRendered: activeHasFirstFrameRendered,
        hasRenderableFrame: activeHasRenderableFrame,
        holdLastFrame: activeHoldLastFrame,
        inChunkedErrorCooldown: activeInChunkedErrorCooldown,
        currentReadyForReveal: currentReadyForReveal,
        canReveal: shouldReveal,
      );
      final shouldDelayFtpPreviewVisual = activeRemoteProtocol == RemoteProtocol.ftp && !activeHasRenderableFrame;
      _ftpPreviewSettleTimer?.cancel();
      setState(() {
        _videoSurfaceVisible = true;
        _ftpPreviewVisualSettled = !shouldDelayFtpPreviewVisual;
      });
      if (shouldDelayFtpPreviewVisual) {
        _ftpPreviewSettleTimer = Timer(const Duration(milliseconds: 220), () {
          if (!mounted || !_videoSurfaceVisible) return;
          setState(() => _ftpPreviewVisualSettled = true);
        });
      }
    });
  }

  void _scheduleStandaloneFavouriteCoverCaptureIfNeeded({
    required AvesVideoController controller,
    required bool hasRenderableFrame,
    required bool hasFirstFrameRendered,
  }) {
    if (_standaloneFavouriteCoverCaptured || _standaloneFavouriteCoverCaptureInFlight) return;
    final isStandaloneFavourite = remoteMediaService.isStandaloneFavouriteEntry(
      entry,
      settings.remoteStandaloneFavouritePaths,
    );
    if (!isStandaloneFavourite || !entry.isVideo) return;
    if (!hasRenderableFrame || (!hasFirstFrameRendered && controller.currentPosition <= 0)) return;
    debugPrint('STANDALONE_COVER schedule uri=${entry.uri} path=${entry.path} '
        'renderable=$hasRenderableFrame firstFrame=$hasFirstFrameRendered position=${controller.currentPosition} status=${controller.status.name}');
    unawaited(
      remoteMediaLogService.log(
        'thumbnail',
        'schedule standalone favourite cover capture from grid preview',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'hasRenderableFrame': hasRenderableFrame,
          'hasFirstFrameRendered': hasFirstFrameRendered,
          'positionMillis': controller.currentPosition,
          'status': controller.status.name,
        },
      ),
    );
    _standaloneFavouriteCoverCaptureInFlight = true;
    unawaited(_captureStandaloneFavouriteCover(controller));
  }

  Future<void> _captureStandaloneFavouriteCover(AvesVideoController controller) async {
    try {
      debugPrint('STANDALONE_COVER capture attempt uri=${entry.uri} path=${entry.path} '
          'position=${controller.currentPosition} status=${controller.status.name} '
          'isPlaying=${controller.isPlaying} isReady=${controller.isReady} firstFrame=${controller.firstFrameRenderedNotifier.value}');
      await remoteMediaLogService.log(
        'thumbnail',
        'attempt standalone favourite cover capture from controller',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'positionMillis': controller.currentPosition,
          'status': controller.status.name,
          'isPlaying': controller.isPlaying,
          'isReady': controller.isReady,
          'firstFrameRendered': controller.firstFrameRenderedNotifier.value,
        },
      );
      final bytes = await controller.captureFrame();
      if (bytes != null && bytes.isNotEmpty) {
        debugPrint('STANDALONE_COVER capture success uri=${entry.uri} bytes=${bytes.length}');
        await remoteMediaService.storeStandaloneFavouriteCapturedCover(
          entry,
          bytes,
          trigger: 'grid_preview_first_frame',
        );
        _standaloneFavouriteCoverCaptured = true;
      } else {
        debugPrint('STANDALONE_COVER capture empty uri=${entry.uri}');
        await remoteMediaLogService.log(
          'thumbnail',
          'controller returned empty standalone favourite cover capture',
          data: {
            'uri': entry.uri,
            'path': entry.path,
            'status': controller.status.name,
            'positionMillis': controller.currentPosition,
          },
        );
      }
    } catch (error, stack) {
      debugPrint('STANDALONE_COVER capture failed uri=${entry.uri} error=$error');
      await remoteMediaLogService.log(
        'thumbnail',
        'failed standalone favourite cover capture from controller',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'status': controller.status.name,
          'positionMillis': controller.currentPosition,
          'error': '$error',
        },
      );
      await reportService.recordError(error, stack);
    } finally {
      _standaloneFavouriteCoverCaptureInFlight = false;
    }
  }

  void _scheduleRemotePreviewCoverCaptureIfNeeded({
    required AvesVideoController controller,
    required bool hasRenderableFrame,
    required bool hasFirstFrameRendered,
  }) {
    if (_remotePreviewCoverCaptured || _remotePreviewCoverCaptureInFlight) return;
    if (!remoteMediaService.supportsRemotePreviewCover(entry)) return;
    if (!hasRenderableFrame || (!hasFirstFrameRendered && controller.currentPosition <= 0)) return;
    _remotePreviewCoverCaptureInFlight = true;
    unawaited(_captureRemotePreviewCover(controller));
  }

  Future<void> _captureRemotePreviewCover(AvesVideoController controller) async {
    try {
      final bytes = await controller.captureFrame();
      if (bytes != null && bytes.isNotEmpty) {
        await remoteMediaService.storeRemotePreviewCapturedCover(
          entry,
          bytes,
          trigger: 'grid_preview_first_frame',
        );
        _remotePreviewCoverCaptured = true;
      }
    } catch (error, stack) {
      await reportService.recordError(error, stack);
    } finally {
      _remotePreviewCoverCaptureInFlight = false;
    }
  }

  bool _isAutoPlayEnabled(Settings settings) {
    return settings.gridVideoAutoPlay;
  }

  bool _shouldMute(Settings settings) {
    return !settings.gridVideoSoundOn;
  }

  Future<void> _logLocalCacheUsage(String stage) async {
    if (!settings.remoteLogEnabled) return;
    if (entry.isRemoteCachedMedia || entry.uri.startsWith('http://') || entry.uri.startsWith('https://')) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastLocalCacheProbeAtMillisByUri[entry.uri];
    if (last != null && now - last < 4000 && stage == 'preview_start') return;
    if (stage == 'preview_start') {
      _lastLocalCacheProbeAtMillisByUri[entry.uri] = now;
    }
    try {
      final usage = await storageService.getDataUsage();
      final details = await storageService.getDataUsageDetails();
      await remoteMediaLogService.log(
        'local_cache_probe',
        'sampled local media cache usage',
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
      unawaited(
        remoteMediaLogService.log(
          'local_cache_probe',
          'failed to sample local media cache usage',
          data: {
            'uri': entry.uri,
            'stage': stage,
            'error': '$error',
          },
        ),
      );
    }
  }

  Future<void> _onCurrentChanged() async {
    if (_autoPlayInFlight) return;
    _autoPlayInFlight = true;
    try {
      final token = ++_playToken;
      if (!mounted) return;

      final settings = _settings;
      final isViewerActive = _viewerEntryNotifier?.value != null;
      final conductor = _videoConductor;
      final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
      _logControllerLifecycle(
        event: 'focus_evaluation',
        controller: _controller,
        extra: {
          'token': token,
          'isViewerActive': isViewerActive,
          'remoteProtocol': remoteProtocol?.name,
        },
      );
      if (!isViewerActive && !isCurrent && remoteProtocol != null) {
        final preheatedController = conductor.getController(entry);
        final shouldAttachPreheatedController =
            preheatedController != null &&
            !_shouldSuppressPreheatedAttachWhileScrolling(remoteProtocol) &&
            _shouldAttachPreheatedControllerForNonCurrentTile(
              remoteProtocol: remoteProtocol,
              preheatedController: preheatedController,
            );
        if (shouldAttachPreheatedController) {
          _logControllerLifecycle(
            event: 'attach_preheated_controller_for_non_current_tile',
            controller: preheatedController,
            previousController: _controller,
          );
          _setController(preheatedController);
          if (mounted) {
            setState(() {});
          }
        }
      }
      final suppressWhileScrolling = _shouldSuppressAutoPlayWhileScrolling(remoteProtocol) && _controller?.isPlaying != true;
      final blockRemoteGridPreviewOnNonWifi =
          remoteProtocol != null && await remoteMediaService.shouldBlockAutoLoadByWifiPolicy();
      if (!_isAutoPlayEnabled(settings) || !isCurrent || isViewerActive || suppressWhileScrolling || blockRemoteGridPreviewOnNonWifi) {
        final reason = !_isAutoPlayEnabled(settings)
            ? 'autoplay_disabled_by_setting'
            : isViewerActive
            ? 'viewer_active'
            : blockRemoteGridPreviewOnNonWifi
            ? 'remote_non_wifi_blocked'
            : suppressWhileScrolling
            ? remoteProtocol == RemoteProtocol.webdav
                  ? 'webdav_scroll_suppressed'
                  : remoteProtocol == RemoteProtocol.ftp
                  ? 'ftp_scroll_suppressed'
                  : remoteProtocol == RemoteProtocol.sftp
                  ? 'sftp_scroll_suppressed'
                  : remoteProtocol == RemoteProtocol.smb
                  ? 'smb_scroll_suppressed'
                  : 'local_scroll_suppressed'
            : 'not_current_focus_item';
        final decisionKey = '$reason:${entry.uri}';
        if (_lastDecisionKey != decisionKey) {
          _lastDecisionKey = decisionKey;
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'skipped grid preview autoplay',
              data: {
                'uri': entry.uri,
                'reason': reason,
                'isRemoteCached': entry.isRemoteCachedMedia,
                'gridAutoPlay': settings.gridVideoAutoPlay,
              },
            ),
          );
        }
        if (_controller?.isPlaying == true) {
          await _controller?.pause();
          unawaited(
            remoteMediaLogService.log(
              'focus',
              'paused grid preview because focus moved away',
              data: {'uri': entry.uri},
            ),
          );
          _logControllerLifecycle(
            event: 'paused_controller_because_focus_moved_away',
            controller: _controller,
          );
        }
        _playRequestedForCurrentFocus = false;
        return;
      }

      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final elapsedSinceAnyAttempt = nowMillis - _lastAutoPlayAnyAttemptMillis;
      if (elapsedSinceAnyAttempt < 140) {
        await Future.delayed(Duration(milliseconds: 140 - elapsedSinceAnyAttempt));
        if (!mounted || token != _playToken || !isCurrent) return;
      }
      if (_lastAutoPlayUri == entry.uri && nowMillis - _lastAutoPlayAttemptMillis < 900) {
        return;
      }
      _lastAutoPlayAnyAttemptMillis = nowMillis;
      _lastAutoPlayUri = entry.uri;
      _lastAutoPlayAttemptMillis = nowMillis;
      final isChunkedRemotePreview = remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp || remoteProtocol == RemoteProtocol.smb;
      final errorCooldownStartedAt = _lastAutoPlayErrorAtMillisByUri[entry.uri];
      if (isChunkedRemotePreview && errorCooldownStartedAt != null && nowMillis - errorCooldownStartedAt < 4000) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'skipped chunked remote preview replay during error cooldown',
            data: {
              'uri': entry.uri,
              'protocol': remoteProtocol?.name,
              'cooldownRemainingMillis': 4000 - (nowMillis - errorCooldownStartedAt),
            },
          ),
        );
        return;
      }

      if (entry.isVideo && remoteProtocol != null) {
        final existingCacheFile = await remoteMediaService.prepareEntryForPlayback(
          entry,
          trigger: 'grid_preview',
          allowDownload: false,
          bindToCachedFile: false,
        );
        if ((remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp || remoteProtocol == RemoteProtocol.smb) && existingCacheFile == null) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'grid_preview_pre_controller');
        }
        if (remoteProtocol == RemoteProtocol.smb && existingCacheFile == null) {
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'smb grid preview forced stable stream path',
              data: {
                'uri': entry.uri,
                'skipQuickCacheDownload': true,
              },
            ),
          );
        }
      }

      AvesVideoController controller;
      try {
        controller = await conductor.getOrCreateController(entry, maxControllerCount: 5);
      } catch (error) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'grid preview controller creation failed',
            data: {
              'uri': entry.uri,
              'error': '$error',
              'isRemoteCached': entry.isRemoteCachedMedia,
            },
          ),
        );
        return;
      }
      if (!mounted || token != _playToken || !isCurrent) return;
      _logControllerLifecycle(
        event: 'controller_ready_for_current_focus',
        controller: controller,
        previousController: _controller,
      );
      _setController(controller);
      if (controller.isPlaying) {
        _logControllerLifecycle(
          event: 'controller_already_playing_when_attached',
          controller: controller,
        );
        return;
      }
      final nowAfterControllerReady = DateTime.now().millisecondsSinceEpoch;
      if (isChunkedRemotePreview && errorCooldownStartedAt != null && nowAfterControllerReady - errorCooldownStartedAt < 4000) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'skipped chunked remote preview replay during error cooldown',
            data: {
              'uri': entry.uri,
              'protocol': remoteProtocol?.name,
              'cooldownRemainingMillis': 4000 - (nowAfterControllerReady - errorCooldownStartedAt),
            },
          ),
        );
        return;
      }
      final decodedFrameAt = _lastDecodedFrameAtMillisByUri[entry.uri];
      final hasRecentDecodedFrame = decodedFrameAt != null && nowMillis - decodedFrameAt < 4000;
      if (!isChunkedRemotePreview && hasRecentDecodedFrame && _hasDecodedFrame(controller)) {
        await conductor.pauseOthers(controller);
        await controller.mute(_shouldMute(settings));
        await _applyViewerReturnResumeIfNeeded(controller, remoteProtocol);
        final resumed = await _tryPlayController(
          controller,
          stage: 'resume_preheated_frame',
          remoteProtocol: remoteProtocol,
        );
        if (!resumed) return;
        _playRequestedForCurrentFocus = true;
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'grid preview resumed from preheated decoded frame',
            data: {
              'uri': entry.uri,
              'protocol': remoteProtocol?.name,
              'status': controller.status.name,
              'isPlaying': controller.isPlaying,
            },
          ),
        );
        if (mounted) setState(() {});
        return;
      }
      _lastDecisionKey = 'play:${entry.uri}';
      if (mounted) setState(() {});
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'grid preview controller ready',
          data: {
            'uri': entry.uri,
            'status': controller.status.name,
            'isRemoteCached': entry.isRemoteCachedMedia,
            'isRemoteStream': entry.uri.startsWith('http://') || entry.uri.startsWith('https://'),
          },
        ),
      );

      try {
        await controller.untilReady.timeout(const Duration(milliseconds: 1000));
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'grid preview stream/source became ready',
            data: {
              'uri': entry.uri,
              'isRemoteCached': entry.isRemoteCachedMedia,
            },
          ),
        );
      } catch (_) {
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'grid preview video not ready before autoplay timeout',
            data: {
              'uri': entry.uri,
              'status': controller.status.name,
              'isPlaying': controller.isPlaying,
            },
          ),
        );
      }

      if (!mounted || token != _playToken || !isCurrent) return;
      if (isChunkedRemotePreview && controller.status == VideoStatus.error) {
        final failedUri = entry.uri;
        _playRequestedForCurrentFocus = false;
        _lastAutoPlayErrorAtMillisByUri[failedUri] = DateTime.now().millisecondsSinceEpoch;
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'aborted chunked remote preview autoplay because controller stayed in error after readiness wait',
            data: {
              'uri': failedUri,
              'protocol': remoteProtocol?.name,
            },
          ),
        );
        return;
      }

      if (!mounted || token != _playToken || !isCurrent) return;
      await conductor.pauseOthers(controller);
      await remoteMediaService.ensureEntryMetadata(entry, trigger: 'grid_preview');
      final isStreamingEntry = entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
      if (!isStreamingEntry) {
        unawaited(_logLocalCacheUsage('preview_start'));
      }
      if (isStreamingEntry) {
        if (!isChunkedRemotePreview) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'grid_preview');
        }
        unawaited(remoteMediaService.warmupVideoCacheForEntry(entry, trigger: 'grid_preview'));
      }
      // SMB preview is more stable when we keep a single controller/source path.
      // We avoid automatic stream->cache promotion and controller recreation in grid preview.
      await controller.mute(_shouldMute(settings));
      await _applyViewerReturnResumeIfNeeded(controller, remoteProtocol);
      final started = await _tryPlayController(
        controller,
        stage: 'start_grid_preview',
        remoteProtocol: remoteProtocol,
      );
      if (!started) return;
      _playRequestedForCurrentFocus = true;
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'grid preview playback requested',
          data: {
            'uri': entry.uri,
            'isRemoteCached': entry.isRemoteCachedMedia,
            'muted': controller.isMuted,
          },
        ),
      );
      _logControllerLifecycle(
        event: 'play_requested',
        controller: controller,
      );

      await Future.delayed(const Duration(milliseconds: 350));
      if (!isStreamingEntry) {
        unawaited(_logLocalCacheUsage('preview_after_350ms'));
      }
      final hasDecodedFrameAfterPlay = _hasDecodedFrame(controller);
      if (hasDecodedFrameAfterPlay) {
        _lastDecodedFrameAtMillisByUri[entry.uri] = DateTime.now().millisecondsSinceEpoch;
      }
      if (mounted && token == _playToken && isCurrent && !controller.isPlaying && controller.status != VideoStatus.error) {
        await _tryPlayController(
          controller,
          stage: 'retry_grid_preview_after_delay',
          remoteProtocol: remoteProtocol,
        );
      } else if (mounted && token == _playToken && isCurrent && controller.status == VideoStatus.error) {
        final failedUri = entry.uri;
        _playRequestedForCurrentFocus = false;
        _lastAutoPlayErrorAtMillisByUri[failedUri] = DateTime.now().millisecondsSinceEpoch;
        unawaited(
          remoteMediaLogService.log(
            'autoplay',
            'grid preview stream failed with error status',
            data: {'uri': failedUri, 'protocol': remoteProtocol?.name},
          ),
        );
        _logControllerLifecycle(
          event: 'chunked_preview_failed_and_entered_cooldown',
          controller: controller,
          extra: {
            'failedUri': failedUri,
          },
        );
        if (isChunkedRemotePreview) {
          return;
        }
      }
    } finally {
      _autoPlayInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox();
    return AnimatedBuilder(
      animation: Listenable.merge([entry.visualChangeNotifier, controller.decodedVideoSizeNotifier]),
      builder: (context, child) {
        return StreamBuilder<VideoStatus>(
          stream: controller.statusStream,
          builder: (context, snapshot) {
            final keepLastFrameVisible = controller.status == VideoStatus.paused || controller.status == VideoStatus.completed;
            final hasDecodedFrame = _hasDecodedFrame(controller);
            final hasFirstFrameRendered = controller.firstFrameRenderedNotifier.value;
            final hasPreviewFrame = hasDecodedFrame || hasFirstFrameRendered;
            final hasRenderableFrame = hasDecodedFrame || hasFirstFrameRendered || _hasPlaybackProgress || controller.currentPosition > 0;
            final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
            final isFtpPreview = remoteProtocol == RemoteProtocol.ftp;
            final isSftpPreview = remoteProtocol == RemoteProtocol.sftp;
            final isSmbPreview = remoteProtocol == RemoteProtocol.smb;
            final isWebdavPreview = remoteProtocol == RemoteProtocol.webdav;
            final isChunkedRemotePreview = isFtpPreview || isSftpPreview || isSmbPreview;
            final isViewerActive = _viewerEntryNotifier?.value != null;
            final isRemoteManagedEntry = remoteProtocol != null || entry.isRemoteCachedMedia || remoteMediaService.hasVirtualRemoteRef(entry.uri);
            final suppressNonCurrentChunkedPreviewSurface = isChunkedRemotePreview && !isCurrent;
            final suppressNonCurrentWebdavPreviewSurfaceWhileScrolling = !isCurrent && isWebdavPreview && widget.isScrollingNotifier?.value == true;
            final suppressNonCurrentFtpPreviewSurfaceWhileScrolling = !isCurrent && isFtpPreview && widget.isScrollingNotifier?.value == true;
            final suppressNonCurrentSftpPreviewSurfaceWhileScrolling = !isCurrent && isSftpPreview && widget.isScrollingNotifier?.value == true;
            final suppressNonCurrentSmbPreviewSurfaceWhileScrolling = !isCurrent && isSmbPreview && widget.isScrollingNotifier?.value == true;
            final suppressNonCurrentRemotePreviewSurfaceWhileScrolling =
                suppressNonCurrentWebdavPreviewSurfaceWhileScrolling || suppressNonCurrentFtpPreviewSurfaceWhileScrolling || suppressNonCurrentSftpPreviewSurfaceWhileScrolling || suppressNonCurrentSmbPreviewSurfaceWhileScrolling;
            final errorCooldownStartedAt = _lastAutoPlayErrorAtMillisByUri[entry.uri];
            final inChunkedErrorCooldown = isChunkedRemotePreview && errorCooldownStartedAt != null && DateTime.now().millisecondsSinceEpoch - errorCooldownStartedAt < 4000;
            final keepPreviewFrameVisibleOnChunkedError = isCurrent && isChunkedRemotePreview && controller.status == VideoStatus.error && (isFtpPreview ? hasFirstFrameRendered : hasPreviewFrame);
            final holdLastFrame = (keepLastFrameVisible && hasRenderableFrame) || keepPreviewFrameVisibleOnChunkedError;
            final ftpForceVisible = isCurrent && _playRequestedForCurrentFocus && hasFirstFrameRendered;
            final sftpForceVisible = isCurrent && _playRequestedForCurrentFocus && hasPreviewFrame;
            final smbForceVisible = isCurrent && _playRequestedForCurrentFocus && hasPreviewFrame;
            final webdavForceVisible =
                isCurrent && _playRequestedForCurrentFocus && hasRenderableFrame && controller.status != VideoStatus.error;
            final remoteForceVisible = isFtpPreview
                ? ftpForceVisible
                : isSftpPreview
                ? sftpForceVisible
                : isSmbPreview
                ? smbForceVisible
                : isWebdavPreview
                ? webdavForceVisible
                : false;
            final currentProtocolShow = isFtpPreview
                ? holdLastFrame
                : isSftpPreview
                ? holdLastFrame
                : isSmbPreview
                ? holdLastFrame
                : isWebdavPreview
                ? holdLastFrame
                : isRemoteManagedEntry
                ? (keepLastFrameVisible && hasRenderableFrame)
                : (keepLastFrameVisible || hasDecodedFrame);
            final nonCurrentRemoteShow =
                !isCurrent &&
                isRemoteManagedEntry &&
                hasRenderableFrame &&
                (_videoSurfaceVisible || _playRequestedForCurrentFocus || holdLastFrame);
            final hideFtpPreviewWhileViewerActive = isViewerActive && isFtpPreview;
            final hideSftpPreviewWhileViewerActive = isViewerActive && isSftpPreview;
            final hideSmbPreviewWhileViewerActive = isViewerActive && isSmbPreview;
            final hideWebdavPreviewWhileViewerActive = isViewerActive && isWebdavPreview;
            final hideChunkedPreviewWhileViewerActive = hideFtpPreviewWhileViewerActive || hideSftpPreviewWhileViewerActive || hideSmbPreviewWhileViewerActive || hideWebdavPreviewWhileViewerActive;
            final baseShow = _videoSurfaceVisible || currentProtocolShow || remoteForceVisible || nonCurrentRemoteShow;
            final shouldKeepExistingSurfaceForHandoff = nonCurrentRemoteShow;
            final show = ((suppressNonCurrentChunkedPreviewSurface || suppressNonCurrentRemotePreviewSurfaceWhileScrolling) && !shouldKeepExistingSurfaceForHandoff) || hideChunkedPreviewWhileViewerActive ? false : baseShow;
            final ftpPreviewOpacityDuration = isFtpPreview ? Duration.zero : const Duration(milliseconds: 180);
            _logTileSurfaceSnapshot(
              controller: controller,
              remoteProtocol: remoteProtocol,
              show: show,
              keepLastFrameVisible: keepLastFrameVisible,
              hasDecodedFrame: hasDecodedFrame,
              hasFirstFrameRendered: hasFirstFrameRendered,
              hasPreviewFrame: hasPreviewFrame,
              hasRenderableFrame: hasRenderableFrame,
              inChunkedErrorCooldown: inChunkedErrorCooldown,
              remoteForceVisible: remoteForceVisible,
              suppressNonCurrentChunkedPreviewSurface: suppressNonCurrentChunkedPreviewSurface || suppressNonCurrentRemotePreviewSurfaceWhileScrolling,
            );
            final tileHeight = widget.tileExtent;
            final decodedSize = controller.decodedVideoSizeNotifier.value;
            final displaySize = decodedSize ?? entry.displaySize;
            final displayAspectRatio = decodedSize != null && decodedSize.height > 0 ? decodedSize.width / decodedSize.height : entry.displayAspectRatio;
            final shouldShowFtpThumbnailUnderlay = isFtpPreview && !hasFirstFrameRendered;
            final hasStableCover =
                remoteMediaService.getStandaloneFavouriteThumbnailProvider(
                  entry,
                  extent: tileHeight,
                ) !=
                null ||
                remoteMediaService.getRemotePreviewThumbnailProvider(
                  entry,
                  extent: tileHeight,
                ) !=
                null;
            final prefersStableCoverBeforePreview = hasStableCover;
            final tileWidth = widget.isMosaic
                ? tileHeight *
                      displayAspectRatio.clamp(
                        MosaicSectionLayoutBuilder.minThumbnailAspectRatio,
                        MosaicSectionLayoutBuilder.maxThumbnailAspectRatio,
                      )
                : tileHeight;
            final ftpPreviewSurfaceReady = !isFtpPreview || _ftpPreviewVisualSettled;
            final canRevealMountedPreview = prefersStableCoverBeforePreview
                ? (keepLastFrameVisible || hasDecodedFrame)
                : hasRenderableFrame;
            final canMountPreviewView = isFtpPreview
                ? (_videoSurfaceVisible && ftpPreviewSurfaceReady && hasFirstFrameRendered)
                : (show && canRevealMountedPreview);
            final previewVideoOpacity = canMountPreviewView ? 1.0 : 0.0;
            return SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (shouldShowFtpThumbnailUnderlay)
                    ThumbnailImage(
                      entry: entry,
                      extent: tileHeight,
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                      fit: widget.isMosaic ? BoxFit.cover : BoxFit.contain,
                      showLoadingBackground: false,
                    ),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: previewVideoOpacity,
                      duration: ftpPreviewOpacityDuration,
                      curve: Curves.easeOut,
                      child: FittedBox(
                        fit: widget.isMosaic ? BoxFit.cover : BoxFit.contain,
                        clipBehavior: Clip.hardEdge,
                        child: canMountPreviewView
                            ? SizedBox(
                                width: displaySize.width,
                                height: displaySize.height,
                                child: VideoView(
                                  entry: entry,
                                  controller: controller,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: IgnorePointer(
                      ignoring: !show,
                      child: AnimatedOpacity(
                        opacity: show ? 1 : 0,
                        duration: ftpPreviewOpacityDuration,
                        curve: Curves.easeOut,
                        child: Material(
                          color: Colors.black45,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () async {
                              final muted = !controller.isMuted;
                              await controller.mute(muted);
                              if (!mounted) return;
                              setState(() {});
                              unawaited(
                                remoteMediaLogService.log(
                                  'autoplay',
                                  'grid preview mute toggled',
                                  data: {
                                    'uri': entry.uri,
                                    'muted': muted,
                                  },
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: Icon(
                                controller.isMuted ? AIcons.mute : AIcons.unmute,
                                size: 14,
                                color: Colors.white,
                                semanticLabel: controller.isMuted ? context.l10n.videoActionMute : context.l10n.videoActionUnmute,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
