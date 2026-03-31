import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/widgets/common/fx/borders.dart';
import 'package:aves/widgets/common/grid/overlay.dart';
import 'package:aves/widgets/common/grid/sections/mosaic/section_layout_builder.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/common/thumbnail/notifications.dart';
import 'package:aves/widgets/common/thumbnail/overlay.dart';
import 'package:aves/widgets/viewer/video/conductor.dart';
import 'package:aves/widgets/viewer/visual/video/video_view.dart';
import 'package:aves_model/aves_model.dart';
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
        if (playbackFocusNotifier != null && entry.isVideo)
          _AutoPlayVideoThumbnail(
            entry: entry,
            isCurrentNotifier: playbackFocusNotifier!,
            isMosaic: isMosaic,
            tileExtent: tileExtent,
          ),
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
        if (highlightable) ThumbnailHighlightOverlay(entry: entry),
      ],
    );

    return Container(
      // `decoration` with sub logical pixel width yields scintillating borders
      // so we use `foregroundDecoration` instead
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
  String? _lastAutoPlayUri;
  int _lastAutoPlayAttemptMillis = 0;
  int _lastAutoPlayAnyAttemptMillis = 0;

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
      _controller = null;
    }
    _onCurrentChanged();
  }

  @override
  void dispose() {
    widget.isCurrentNotifier.removeListener(_onCurrentChanged);
    _playToken++;
    if (_controller?.isPlaying == true) {
      _controller?.pause();
    }
    super.dispose();
  }

  bool _isAutoPlayEnabled(Settings settings) {
    if (entry.isRemoteCachedMedia) {
      return settings.remoteGridVideoAutoPlay;
    }
    return settings.videoAutoPlayMode != VideoAutoPlayMode.disabled;
  }

  bool _shouldMute(Settings settings) {
    if (entry.isRemoteCachedMedia) {
      return !settings.remoteGridVideoSoundOn;
    }
    return settings.videoAutoPlayMode != VideoAutoPlayMode.playWithSound;
  }

  Future<void> _onCurrentChanged() async {
    final token = ++_playToken;
    if (!mounted) return;

    final settings = context.read<Settings>();
    if (!_isAutoPlayEnabled(settings) || !isCurrent) {
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
    if (_lastAutoPlayUri == entry.uri && nowMillis - _lastAutoPlayAttemptMillis < 250) {
      return;
    }
    _lastAutoPlayAnyAttemptMillis = nowMillis;
    _lastAutoPlayUri = entry.uri;
    _lastAutoPlayAttemptMillis = nowMillis;

    final conductor = context.read<VideoConductor>();
    final controller = await conductor.getOrCreateController(entry, maxControllerCount: 2);
    if (!mounted || token != _playToken || !isCurrent) return;
    _controller = controller;
    if (mounted) setState(() {});

    try {
      await controller.untilReady.timeout(const Duration(milliseconds: 1000));
    } catch (_) {
      unawaited(
        remoteMediaLogService.log(
          'autoplay',
          'grid preview video not ready before autoplay timeout',
          data: {'uri': entry.uri},
        ),
      );
    }

    if (!mounted || token != _playToken || !isCurrent) return;
    await conductor.pauseAll();
    await controller.mute(_shouldMute(settings));
    await controller.seekTo(0);
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
      await controller.seekTo(0);
      await controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox();
    return StreamBuilder<VideoStatus>(
      stream: controller.statusStream,
      builder: (context, snapshot) {
        final show = isCurrent && controller.isReady;
        final tileHeight = widget.tileExtent;
        final tileWidth = widget.isMosaic
            ? tileHeight *
                entry.displayAspectRatio.clamp(
                  MosaicSectionLayoutBuilder.minThumbnailAspectRatio,
                  MosaicSectionLayoutBuilder.maxThumbnailAspectRatio,
                )
            : tileHeight;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: entry.displaySize.width,
                  height: entry.displaySize.height,
                  child: VideoView(
                    entry: entry,
                    controller: controller,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
