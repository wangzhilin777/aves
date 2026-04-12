import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/images.dart';
import 'package:aves/model/entry/extensions/multipage.dart';
import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/durations.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves_magnifier/aves_magnifier.dart';
import 'package:aves_video/aves_video.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class VideoCover extends StatefulWidget {
  final AvesEntry mainEntry, pageEntry;
  final AvesMagnifierController magnifierController;
  final AvesVideoController videoController;
  final Size videoDisplaySize;
  final void Function({Alignment? alignment}) onTap;
  final Widget Function(
    AvesMagnifierController coverController,
    Size coverSize,
    ImageProvider videoCoverUriImage,
  )
  magnifierBuilder;

  const VideoCover({
    super.key,
    required this.mainEntry,
    required this.pageEntry,
    required this.magnifierController,
    required this.videoController,
    required this.videoDisplaySize,
    required this.onTap,
    required this.magnifierBuilder,
  });

  @override
  State<VideoCover> createState() => _VideoCoverState();
}

class _VideoCoverState extends State<VideoCover> {
  ImageStream? _videoCoverStream;
  ImageStreamListener? _videoCoverStreamListener;
  final ValueNotifier<ImageInfo?> _videoCoverInfoNotifier = ValueNotifier(null);
  static const _remoteCoverGrace = Duration(milliseconds: 1400);
  static const _chunkedRemotePlaybackCoverGrace = Duration(milliseconds: 180);
  static const _chunkedRemoteProgressCoverGrace = Duration(milliseconds: 180);
  static const _largeRemotePlaybackCoverGrace = Duration(milliseconds: 420);
  static const _largeRemoteProgressCoverGrace = Duration(milliseconds: 320);

  AvesMagnifierController? _dismissedCoverMagnifierController;
  DateTime _coverGraceDeadline = DateTime.now().add(_remoteCoverGrace);
  DateTime? _chunkedPlaybackCoverDeadline;
  DateTime? _chunkedProgressCoverDeadline;
  DateTime? _largeRemotePlaybackCoverDeadline;
  DateTime? _largeRemoteProgressCoverDeadline;
  bool _wasPlaying = false;
  bool _hadPlaybackProgress = false;
  String? _lastCoverDecisionKey;

  AvesMagnifierController get dismissedCoverMagnifierController {
    _dismissedCoverMagnifierController ??= AvesMagnifierController();
    return _dismissedCoverMagnifierController!;
  }

  AvesEntry get mainEntry => widget.mainEntry;

  AvesEntry get entry => widget.pageEntry;

  AvesMagnifierController get magnifierController => widget.magnifierController;

  AvesVideoController get videoController => widget.videoController;

  Size get videoDisplaySize => widget.videoDisplaySize;

  // use the high res photo as cover for the video part of a motion photo
  ImageProvider get videoCoverUriImage => (mainEntry.isMotionPhoto ? mainEntry : entry).fullImage;

  bool get _shouldSuppressConcurrentRemoteCoverImage => remoteMediaService.isLargeRemoteVideoEntry(entry) && (entry.uri.startsWith('http://') || entry.uri.startsWith('https://'));

  @override
  void initState() {
    super.initState();
    _registerWidget(widget);
  }

  @override
  void didUpdateWidget(covariant VideoCover oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.pageEntry != widget.pageEntry) {
      _unregisterWidget(oldWidget);
      _registerWidget(widget);
    }
  }

  @override
  void dispose() {
    _unregisterWidget(widget);
    _dismissedCoverMagnifierController?.dispose();
    _videoCoverInfoNotifier.dispose();
    super.dispose();
  }

  void _registerWidget(VideoCover widget) {
    _coverGraceDeadline = DateTime.now().add(_remoteCoverGrace);
    _chunkedPlaybackCoverDeadline = null;
    _chunkedProgressCoverDeadline = null;
    _largeRemotePlaybackCoverDeadline = null;
    _largeRemoteProgressCoverDeadline = null;
    _wasPlaying = false;
    _hadPlaybackProgress = false;
    if (_shouldSuppressConcurrentRemoteCoverImage) {
      _videoCoverStream = null;
      _videoCoverInfoNotifier.value = null;
      return;
    }
    _videoCoverStreamListener = ImageStreamListener((image, _) => _videoCoverInfoNotifier.value = image);
    _videoCoverStream = videoCoverUriImage.resolve(ImageConfiguration.empty);
    _videoCoverStream!.addListener(_videoCoverStreamListener!);
  }

  void _unregisterWidget(VideoCover oldWidget) {
    final listener = _videoCoverStreamListener;
    if (listener != null) {
      _videoCoverStream?.removeListener(listener);
    }
    _videoCoverStream = null;
    _videoCoverStreamListener = null;
    _videoCoverInfoNotifier.value = null;
  }

  void _logCoverDecision({
    required VideoStatus status,
    required int currentPosition,
    required RemoteProtocol? remoteProtocol,
    required bool hasDecodedFrame,
    required bool hasFirstFrameRendered,
    required bool hasStableDetailFrame,
    required bool withinRemoteCoverGrace,
    required bool withinChunkedPlaybackCoverGrace,
    required bool withinChunkedProgressCoverGrace,
    required bool keepRemoteCoverUntilPlaying,
    required bool keepRemoteCoverUntilProgressSettles,
    required bool showCover,
    required bool effectiveShowCover,
    required bool hasCoverVisual,
    required bool shouldDisplayCoverVisual,
  }) {
    final key =
        '${status.name}|${videoController.isPlaying}|${videoController.isReady}|${currentPosition > 0}|$hasDecodedFrame|$hasFirstFrameRendered|$hasStableDetailFrame|$withinRemoteCoverGrace|$withinChunkedPlaybackCoverGrace|$withinChunkedProgressCoverGrace|$keepRemoteCoverUntilPlaying|$keepRemoteCoverUntilProgressSettles|$showCover|$effectiveShowCover|$hasCoverVisual|$shouldDisplayCoverVisual';
    if (_lastCoverDecisionKey == key || !settings.remoteLogEnabled) return;
    _lastCoverDecisionKey = key;
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'video cover decision',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'protocol': remoteProtocol?.name,
          'status': status.name,
          'isPlaying': videoController.isPlaying,
          'isReady': videoController.isReady,
          'positionMillis': currentPosition,
          'hasDecodedFrame': hasDecodedFrame,
          'hasFirstFrameRendered': hasFirstFrameRendered,
          'hasStableDetailFrame': hasStableDetailFrame,
          'withinRemoteCoverGrace': withinRemoteCoverGrace,
          'withinChunkedPlaybackCoverGrace': withinChunkedPlaybackCoverGrace,
          'withinChunkedProgressCoverGrace': withinChunkedProgressCoverGrace,
          'keepRemoteCoverUntilPlaying': keepRemoteCoverUntilPlaying,
          'keepRemoteCoverUntilProgressSettles': keepRemoteCoverUntilProgressSettles,
          'showCover': showCover,
          'effectiveShowCover': effectiveShowCover,
          'hasCoverVisual': hasCoverVisual,
          'shouldDisplayCoverVisual': shouldDisplayCoverVisual,
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // fade out image to ease transition with the player
    return AnimatedBuilder(
      animation: Listenable.merge([videoController.decodedVideoSizeNotifier, videoController.firstFrameRenderedNotifier]),
      builder: (context, _) {
        final decodedVideoSize = videoController.decodedVideoSizeNotifier.value;
        final hasDecodedFrame = decodedVideoSize != null && decodedVideoSize.width > 1 && decodedVideoSize.height > 1;
        final hasFirstFrameRendered = videoController.firstFrameRenderedNotifier.value;
        return StreamBuilder<VideoStatus>(
          stream: videoController.statusStream,
          builder: (context, snapshot) {
            return StreamBuilder<int>(
              stream: videoController.positionStream,
              initialData: videoController.currentPosition,
              builder: (context, positionSnapshot) {
                final status = snapshot.data ?? videoController.status;
                final currentPosition = positionSnapshot.data ?? videoController.currentPosition;
                final isRemoteStream = entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
                final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
                final isLargeRemoteDetail = isRemoteStream && remoteMediaService.isLargeRemoteVideoEntry(entry);
                final isChunkedRemoteProtocol = remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp || remoteProtocol == RemoteProtocol.smb;
                final hasStableDetailFrame = hasFirstFrameRendered && videoController.isPlaying && currentPosition > 0;
                final withinRemoteCoverGrace = isRemoteStream && !hasDecodedFrame && DateTime.now().isBefore(_coverGraceDeadline);
                final startedPlayingNow = videoController.isPlaying && !_wasPlaying;
                final gainedPlaybackProgress = currentPosition > 0 && !_hadPlaybackProgress;
                if (startedPlayingNow && isRemoteStream && isChunkedRemoteProtocol) {
                  _chunkedPlaybackCoverDeadline = DateTime.now().add(_chunkedRemotePlaybackCoverGrace);
                }
                if (gainedPlaybackProgress && isRemoteStream && isChunkedRemoteProtocol) {
                  _chunkedProgressCoverDeadline = DateTime.now().add(_chunkedRemoteProgressCoverGrace);
                }
                if (startedPlayingNow && isLargeRemoteDetail) {
                  _largeRemotePlaybackCoverDeadline = DateTime.now().add(_largeRemotePlaybackCoverGrace);
                }
                if (gainedPlaybackProgress && isLargeRemoteDetail) {
                  _largeRemoteProgressCoverDeadline = DateTime.now().add(_largeRemoteProgressCoverGrace);
                }
                _wasPlaying = videoController.isPlaying;
                _hadPlaybackProgress = currentPosition > 0;
                final withinChunkedPlaybackCoverGrace = isRemoteStream && isChunkedRemoteProtocol && _chunkedPlaybackCoverDeadline != null && DateTime.now().isBefore(_chunkedPlaybackCoverDeadline!);
                final withinChunkedProgressCoverGrace = isRemoteStream && isChunkedRemoteProtocol && _chunkedProgressCoverDeadline != null && DateTime.now().isBefore(_chunkedProgressCoverDeadline!);
                final withinLargeRemotePlaybackCoverGrace = isLargeRemoteDetail && _largeRemotePlaybackCoverDeadline != null && DateTime.now().isBefore(_largeRemotePlaybackCoverDeadline!);
                final withinLargeRemoteProgressCoverGrace = isLargeRemoteDetail && _largeRemoteProgressCoverDeadline != null && DateTime.now().isBefore(_largeRemoteProgressCoverDeadline!);
                final hasFtpRenderableVisual = remoteProtocol == RemoteProtocol.ftp && (hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final allowFtpDetailCoverDismiss = hasFtpRenderableVisual;
                final allowSftpDetailCoverDismiss = remoteProtocol == RemoteProtocol.sftp && (hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final allowSmbDetailCoverDismiss = remoteProtocol == RemoteProtocol.smb && (hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final allowLargeRemoteDetailCoverDismiss = isLargeRemoteDetail && (hasDecodedFrame || hasFirstFrameRendered || (currentPosition > 0 && !withinLargeRemoteProgressCoverGrace));
                final keepRemoteCoverUntilPlaying =
                    isRemoteStream &&
                    (isChunkedRemoteProtocol
                        ? (remoteProtocol == RemoteProtocol.ftp
                              ? (!allowFtpDetailCoverDismiss && withinChunkedPlaybackCoverGrace)
                              : remoteProtocol == RemoteProtocol.sftp
                              ? (!allowSftpDetailCoverDismiss && withinChunkedPlaybackCoverGrace)
                              : remoteProtocol == RemoteProtocol.smb
                              ? (!allowSmbDetailCoverDismiss && withinChunkedPlaybackCoverGrace)
                              : (!hasStableDetailFrame || withinChunkedPlaybackCoverGrace))
                        : isLargeRemoteDetail
                        ? (!allowLargeRemoteDetailCoverDismiss || withinLargeRemotePlaybackCoverGrace)
                        : !videoController.isPlaying);
                final keepRemoteCoverUntilProgressSettles =
                    isRemoteStream &&
                    ((isChunkedRemoteProtocol &&
                            (remoteProtocol == RemoteProtocol.ftp
                                ? (withinChunkedProgressCoverGrace && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0))
                                : remoteProtocol == RemoteProtocol.sftp
                                ? (withinChunkedProgressCoverGrace && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0))
                                : remoteProtocol == RemoteProtocol.smb
                                ? (withinChunkedProgressCoverGrace && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0))
                                : withinChunkedProgressCoverGrace)) ||
                        (!isChunkedRemoteProtocol && isLargeRemoteDetail && withinLargeRemoteProgressCoverGrace && !allowLargeRemoteDetailCoverDismiss));
                final shouldShowFtpErrorCover = remoteProtocol == RemoteProtocol.ftp && status == VideoStatus.error && isRemoteStream && !hasFtpRenderableVisual;
                final shouldShowSftpErrorCover = remoteProtocol == RemoteProtocol.sftp && status == VideoStatus.error && isRemoteStream && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final shouldShowSmbErrorCover = remoteProtocol == RemoteProtocol.smb && status == VideoStatus.error && isRemoteStream && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final shouldShowGenericRemoteErrorCover = status == VideoStatus.error && isRemoteStream && !isChunkedRemoteProtocol;
                final shouldShowFtpNotReadyCover = remoteProtocol == RemoteProtocol.ftp && !videoController.isReady && !hasFtpRenderableVisual;
                final shouldShowSftpNotReadyCover = remoteProtocol == RemoteProtocol.sftp && !videoController.isReady && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final shouldShowSmbNotReadyCover = remoteProtocol == RemoteProtocol.smb && !videoController.isReady && !(hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
                final shouldShowGenericNotReadyCover = !videoController.isReady && !isChunkedRemoteProtocol;
                final showCover =
                    shouldShowFtpNotReadyCover ||
                    shouldShowSftpNotReadyCover ||
                    shouldShowSmbNotReadyCover ||
                    shouldShowGenericNotReadyCover ||
                    !hasDecodedFrame && (videoController.isPlaying || isRemoteStream) ||
                    keepRemoteCoverUntilPlaying ||
                    shouldShowFtpErrorCover ||
                    shouldShowSftpErrorCover ||
                    shouldShowSmbErrorCover ||
                    shouldShowGenericRemoteErrorCover ||
                    withinRemoteCoverGrace;
                final cachedCoverExtent = entry.cachedThumbnails.firstOrNull?.key.extent;
                final hasPotentialCoverVisual = _videoCoverInfoNotifier.value != null || (cachedCoverExtent != null && cachedCoverExtent > 0);
                final effectiveShowCover = (showCover || keepRemoteCoverUntilProgressSettles) && hasPotentialCoverVisual;
                if (withinRemoteCoverGrace || withinChunkedPlaybackCoverGrace || withinChunkedProgressCoverGrace || withinLargeRemotePlaybackCoverGrace || withinLargeRemoteProgressCoverGrace) {
                  SchedulerBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                }
                return IgnorePointer(
                  ignoring: !effectiveShowCover,
                  child: AnimatedOpacity(
                    opacity: effectiveShowCover ? 1 : 0,
                    curve: Curves.easeInCirc,
                    duration: ADurations.viewerVideoPlayerTransition,
                    onEnd: () {
                      final boundaries = magnifierController.scaleBoundaries;
                      if (boundaries != null) {
                        magnifierController.setScaleBoundaries(
                          boundaries.copyWith(
                            contentSize: videoDisplaySize,
                          ),
                        );
                      }
                    },
                    child: ValueListenableBuilder<ImageInfo?>(
                      valueListenable: _videoCoverInfoNotifier,
                      builder: (context, videoCoverInfo, child) {
                        final extent = cachedCoverExtent;
                        final hasCoverVisual = videoCoverInfo != null || (extent != null && extent > 0);
                        final shouldDisplayCoverVisual =
                            hasCoverVisual &&
                            effectiveShowCover &&
                            (!isChunkedRemoteProtocol || currentPosition <= 0 || !videoController.isPlaying || !isRemoteStream || !hasFirstFrameRendered || withinChunkedProgressCoverGrace) &&
                            (!isLargeRemoteDetail || currentPosition <= 0 || !videoController.isPlaying || !isRemoteStream || !hasFirstFrameRendered || withinLargeRemoteProgressCoverGrace);
                        final shouldInterceptPointer = effectiveShowCover && shouldDisplayCoverVisual;
                        _logCoverDecision(
                          status: status,
                          currentPosition: currentPosition,
                          remoteProtocol: remoteProtocol,
                          hasDecodedFrame: hasDecodedFrame,
                          hasFirstFrameRendered: hasFirstFrameRendered,
                          hasStableDetailFrame: hasStableDetailFrame,
                          withinRemoteCoverGrace: withinRemoteCoverGrace,
                          withinChunkedPlaybackCoverGrace: withinChunkedPlaybackCoverGrace,
                          withinChunkedProgressCoverGrace: withinChunkedProgressCoverGrace,
                          keepRemoteCoverUntilPlaying: keepRemoteCoverUntilPlaying,
                          keepRemoteCoverUntilProgressSettles: keepRemoteCoverUntilProgressSettles,
                          showCover: showCover,
                          effectiveShowCover: effectiveShowCover,
                          hasCoverVisual: hasCoverVisual,
                          shouldDisplayCoverVisual: shouldDisplayCoverVisual,
                        );
                        if (videoCoverInfo != null) {
                          final coverSize = Size(
                            videoCoverInfo.image.width.toDouble(),
                            videoCoverInfo.image.height.toDouble(),
                          );
                          final coverController = shouldDisplayCoverVisual || coverSize == videoDisplaySize ? magnifierController : dismissedCoverMagnifierController;
                          return IgnorePointer(
                            ignoring: !shouldInterceptPointer,
                            child: widget.magnifierBuilder(coverController, coverSize, videoCoverUriImage),
                          );
                        }

                        if (extent != null && extent > 0) {
                          return IgnorePointer(
                            ignoring: !shouldInterceptPointer,
                            child: GestureDetector(
                              onTap: widget.onTap,
                              child: ThumbnailImage(
                                entry: entry,
                                extent: extent,
                                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                                fit: BoxFit.contain,
                                showLoadingBackground: false,
                              ),
                            ),
                          );
                        }

                        return const ColoredBox(color: Colors.transparent);
                      },
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}
