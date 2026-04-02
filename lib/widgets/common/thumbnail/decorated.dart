import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/fx/borders.dart';
import 'package:aves/widgets/common/grid/overlay.dart';
import 'package:aves/widgets/common/grid/sections/mosaic/section_layout_builder.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/common/thumbnail/notifications.dart';
import 'package:aves/widgets/common/thumbnail/overlay.dart';
import 'package:aves/widgets/viewer/video/conductor.dart';
import 'package:aves/widgets/viewer/visual/video/video_view.dart';
import 'package:aves_video/aves_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DecoratedThumbnail extends StatelessWidget {
  final AvesEntry entry;
  final double tileExtent;
  final ValueNotifier<bool>? cancellableNotifier;
  final ValueListenable<AvesEntry?>? playbackFocusNotifier;
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

        Widget child = ThumbnailImage(
          entry: entry,
          extent: tileExtent,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          isMosaic: isMosaic,
          cancellableNotifier: cancellableNotifier,
          heroTag: heroTagger?.call(),
          heroPlaceholderBuilder: heroPlaceholderBuilder,
        );

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

class _AutoPlayVideoThumbnail extends StatefulWidget {
  final AvesEntry entry;
  final ValueListenable<AvesEntry?> isCurrentNotifier;
  final bool isMosaic;
  final double tileExtent;

  const _AutoPlayVideoThumbnail({
    required this.entry,
    required this.isCurrentNotifier,
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
  String? _lastAutoPlayUri;
  String? _lastDecisionKey;
  String? _lastSmbFallbackAttemptUri;
  String? _lastSmbPromotionUri;
  int _lastAutoPlayAttemptMillis = 0;
  int _lastAutoPlayAnyAttemptMillis = 0;
  final Map<String, int> _lastAutoPlayErrorAtMillisByUri = {};
  StreamSubscription<VideoStatus>? _statusSubscription;
  Timer? _videoSurfaceRevealTimer;

  @override
  void initState() {
    super.initState();
    widget.isCurrentNotifier.addListener(_onCurrentChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCurrentChanged());
  }

  @override
  void didUpdateWidget(covariant _AutoPlayVideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCurrentNotifier != widget.isCurrentNotifier) {
      oldWidget.isCurrentNotifier.removeListener(_onCurrentChanged);
      widget.isCurrentNotifier.addListener(_onCurrentChanged);
    }
    if (oldWidget.entry != widget.entry) {
      _unbindController(_controller);
      _controller = null;
      _videoSurfaceVisible = false;
    }
    _onCurrentChanged();
  }

  @override
  void dispose() {
    widget.isCurrentNotifier.removeListener(_onCurrentChanged);
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
    _statusSubscription = controller.statusStream.listen((_) => _onControllerVisualStateChanged());
    _onControllerVisualStateChanged();
  }

  void _unbindController(AvesVideoController? controller) {
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _videoSurfaceRevealTimer?.cancel();
    _videoSurfaceRevealTimer = null;
    controller?.decodedVideoSizeNotifier.removeListener(_onControllerVisualStateChanged);
  }

  void _setController(AvesVideoController controller) {
    if (identical(_controller, controller)) return;
    _unbindController(_controller);
    _controller = controller;
    _videoSurfaceVisible = false;
    _bindController(controller);
  }

  void _onControllerVisualStateChanged() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    final keepLastFrameVisible = controller.status == VideoStatus.paused || controller.status == VideoStatus.completed;
    final hasDecodedFrame = controller.decodedVideoSizeNotifier.value != null;
    final canReveal = isCurrent && (keepLastFrameVisible || (controller.isPlaying && hasDecodedFrame));
    if (!canReveal) {
      _videoSurfaceRevealTimer?.cancel();
      _videoSurfaceRevealTimer = null;
      if (_videoSurfaceVisible) {
        setState(() => _videoSurfaceVisible = false);
      }
      return;
    }
    if (_videoSurfaceVisible || _videoSurfaceRevealTimer != null) return;
    _videoSurfaceRevealTimer = Timer(const Duration(milliseconds: 220), () {
      _videoSurfaceRevealTimer = null;
      final activeController = _controller;
      if (!mounted || activeController == null) return;
      final activeKeepLastFrameVisible = activeController.status == VideoStatus.paused || activeController.status == VideoStatus.completed;
      final activeHasDecodedFrame = activeController.decodedVideoSizeNotifier.value != null;
      final shouldReveal = isCurrent && (activeKeepLastFrameVisible || (activeController.isPlaying && activeHasDecodedFrame));
      if (!shouldReveal || _videoSurfaceVisible) return;
      setState(() => _videoSurfaceVisible = true);
    });
  }

  bool _isAutoPlayEnabled(Settings settings) {
    return settings.gridVideoAutoPlay;
  }

  bool _shouldMute(Settings settings) {
    return !settings.gridVideoSoundOn;
  }

  void _scheduleSmbCachedPromotion({
    required Settings settings,
    required VideoConductor conductor,
    required int token,
  }) {
    if (_lastSmbPromotionUri == entry.uri) return;
    _lastSmbPromotionUri = entry.uri;
    unawaited(() async {
      final cachedFile = await remoteMediaService.prepareEntryForPlayback(
        entry,
        trigger: 'grid_preview_async_promote',
        allowDownload: true,
      );
      if (cachedFile == null || !mounted || token != _playToken || !isCurrent) {
        return;
      }
      try {
        final fallbackController = await conductor.getOrCreateController(entry, maxControllerCount: 2);
        if (!mounted || token != _playToken || !isCurrent) return;
        _setController(fallbackController);
        if (mounted) setState(() {});
        try {
          await fallbackController.untilReady.timeout(const Duration(milliseconds: 1500));
        } catch (_) {}
        await conductor.pauseOthers(fallbackController);
        await fallbackController.mute(_shouldMute(settings));
        await fallbackController.play();
        await remoteMediaLogService.log(
          'autoplay',
          'grid preview promoted smb entry to cached file playback',
          data: {
            'uri': entry.uri,
            'file': cachedFile.path,
          },
        );
      } catch (error) {
        await remoteMediaLogService.log(
          'autoplay',
          'grid preview smb cached promotion failed',
          data: {
            'uri': entry.uri,
            'error': '$error',
          },
        );
      }
    }());
  }

  Future<void> _onCurrentChanged() async {
    if (_autoPlayInFlight) return;
    _autoPlayInFlight = true;
    try {
      final token = ++_playToken;
      if (!mounted) return;

      final settings = context.read<Settings>();
      if (!_isAutoPlayEnabled(settings) || !isCurrent) {
        final reason = !_isAutoPlayEnabled(settings) ? 'autoplay_disabled_by_setting' : 'not_current_focus_item';
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
        }
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

      final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
      if (entry.isVideo && remoteProtocol != null) {
        await remoteMediaService.prepareEntryForPlayback(
          entry,
          trigger: 'grid_preview',
          allowDownload: false,
        );
      }

      final conductor = context.read<VideoConductor>();
      AvesVideoController controller;
      try {
        controller = await conductor.getOrCreateController(entry, maxControllerCount: 2);
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
      _controller = controller;
      _setController(controller);
      if (controller.isPlaying) {
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

      final errorCooldownStartedAt = _lastAutoPlayErrorAtMillisByUri[entry.uri];
      final nowAfterControllerReady = DateTime.now().millisecondsSinceEpoch;
      if (errorCooldownStartedAt != null && nowAfterControllerReady - errorCooldownStartedAt < 4000) {
        return;
      }

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
      await conductor.pauseOthers(controller);
      await remoteMediaService.ensureEntryMetadata(entry, trigger: 'grid_preview');
      await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'grid_preview');
      unawaited(remoteMediaService.warmupVideoCacheForEntry(entry, trigger: 'grid_preview'));
      if (remoteProtocol == RemoteProtocol.smb) {
        _scheduleSmbCachedPromotion(
          settings: settings,
          conductor: conductor,
          token: token,
        );
      }
      await controller.mute(_shouldMute(settings));
      await controller.play();
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

      await Future.delayed(const Duration(milliseconds: 350));
      if (mounted && token == _playToken && isCurrent && !controller.isPlaying && controller.status != VideoStatus.error) {
        await controller.play();
      } else if (mounted && token == _playToken && isCurrent && controller.status == VideoStatus.error) {
        final failedUri = entry.uri;
        final canTrySmbFallback = remoteProtocol == RemoteProtocol.smb && _lastSmbFallbackAttemptUri != failedUri;
        var recovered = false;
        if (canTrySmbFallback) {
          _lastSmbFallbackAttemptUri = failedUri;
          final cachedFile = await remoteMediaService.prepareEntryForPlayback(
            entry,
            trigger: 'grid_preview_error_fallback',
            allowDownload: true,
          );
          if (cachedFile != null && mounted && token == _playToken && isCurrent) {
            try {
              final fallbackController = await conductor.getOrCreateController(entry, maxControllerCount: 2);
              if (mounted && token == _playToken && isCurrent) {
                _setController(fallbackController);
                if (mounted) setState(() {});
                try {
                  await fallbackController.untilReady.timeout(const Duration(milliseconds: 1500));
                } catch (_) {}
                await conductor.pauseOthers(fallbackController);
                await fallbackController.mute(_shouldMute(settings));
                await fallbackController.play();
                recovered = true;
                unawaited(
                  remoteMediaLogService.log(
                    'autoplay',
                    'grid preview recovered with smb cached file fallback',
                    data: {
                      'uri': entry.uri,
                      'file': cachedFile.path,
                    },
                  ),
                );
              }
            } catch (error) {
              unawaited(
                remoteMediaLogService.log(
                  'autoplay',
                  'grid preview smb cached file fallback failed',
                  data: {
                    'uri': entry.uri,
                    'error': '$error',
                  },
                ),
              );
            }
          }
        }
        if (!recovered) {
          _lastAutoPlayErrorAtMillisByUri[failedUri] = DateTime.now().millisecondsSinceEpoch;
          unawaited(
            remoteMediaLogService.log(
              'autoplay',
              'grid preview stream failed with error status',
              data: {'uri': failedUri},
            ),
          );
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
            final show = _videoSurfaceVisible || keepLastFrameVisible;
            final tileHeight = widget.tileExtent;
            final decodedSize = controller.decodedVideoSizeNotifier.value;
            final displaySize = decodedSize ?? entry.displaySize;
            final displayAspectRatio = decodedSize != null && decodedSize.height > 0 ? decodedSize.width / decodedSize.height : entry.displayAspectRatio;
            final tileWidth = widget.isMosaic
                ? tileHeight *
                      displayAspectRatio.clamp(
                        MosaicSectionLayoutBuilder.minThumbnailAspectRatio,
                        MosaicSectionLayoutBuilder.maxThumbnailAspectRatio,
                      )
                : tileHeight;
            return SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: FittedBox(
                        fit: widget.isMosaic ? BoxFit.cover : BoxFit.contain,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: displaySize.width,
                          height: displaySize.height,
                          child: VideoView(
                            entry: entry,
                            controller: controller,
                          ),
                        ),
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
                        duration: const Duration(milliseconds: 180),
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
