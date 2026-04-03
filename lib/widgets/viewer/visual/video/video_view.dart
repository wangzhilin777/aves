import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves_video/aves_video.dart';
import 'package:flutter/material.dart';

class VideoView extends StatefulWidget {
  final AvesEntry entry;
  final AvesVideoController controller;
  final bool preferStableRemoteInit;

  const VideoView({
    super.key,
    required this.entry,
    required this.controller,
    this.preferStableRemoteInit = false,
  });

  @override
  State<StatefulWidget> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  static const _remoteInitialErrorGrace = Duration(milliseconds: 1400);
  static const _chunkedRemoteProgressRevealGrace = Duration(milliseconds: 180);
  AvesEntry get entry => widget.entry;

  AvesVideoController get controller => widget.controller;
  bool _loggedSoftErrorRender = false;
  late DateTime _initialErrorGraceDeadline;
  DateTime? _chunkedProgressRevealDeadline;
  bool _hadPlaybackProgress = false;
  String? _lastLocalRenderDecision;

  @override
  void initState() {
    super.initState();
    _initialErrorGraceDeadline = DateTime.now().add(_remoteInitialErrorGrace);
    _chunkedProgressRevealDeadline = null;
    _hadPlaybackProgress = false;
    _registerWidget(widget);
  }

  @override
  void didUpdateWidget(covariant VideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry) {
      _initialErrorGraceDeadline = DateTime.now().add(_remoteInitialErrorGrace);
      _chunkedProgressRevealDeadline = null;
      _hadPlaybackProgress = false;
    }
    _unregisterWidget(oldWidget);
    _registerWidget(widget);
  }

  @override
  void dispose() {
    _unregisterWidget(widget);
    super.dispose();
  }

  void _registerWidget(VideoView widget) {
    widget.controller.playCompletedListenable.addListener(_onPlayCompleted);
  }

  void _unregisterWidget(VideoView widget) {
    widget.controller.playCompletedListenable.removeListener(_onPlayCompleted);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VideoStatus>(
      stream: controller.statusStream,
      builder: (context, snapshot) {
        return StreamBuilder<int>(
          stream: controller.positionStream,
          initialData: controller.currentPosition,
          builder: (context, positionSnapshot) {
            final status = snapshot.data ?? controller.status;
            final currentPosition = positionSnapshot.data ?? controller.currentPosition;
            final decodedSize = controller.decodedVideoSizeNotifier.value;
            final hasDecodedFrame = decodedSize != null && decodedSize.width > 1 && decodedSize.height > 1;
            final hasFirstFrameRendered = controller.firstFrameRenderedNotifier.value;
            final isRemoteStream = entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
            final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
            final isRemoteManagedEntry = remoteProtocol != null || entry.isRemoteCachedMedia || remoteMediaService.hasVirtualRemoteRef(entry.uri);
            final isChunkedRemoteProtocol = remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp || remoteProtocol == RemoteProtocol.smb;
            final isChunkedRemotePreview = isChunkedRemoteProtocol && !widget.preferStableRemoteInit;
            final hasStableDetailFrame = controller.isPlaying && currentPosition > 0 && (hasFirstFrameRendered || hasDecodedFrame);
            final gainedPlaybackProgress = currentPosition > 0 && !_hadPlaybackProgress;
            if (gainedPlaybackProgress && widget.preferStableRemoteInit && isRemoteStream && isChunkedRemoteProtocol) {
              _chunkedProgressRevealDeadline = DateTime.now().add(_chunkedRemoteProgressRevealGrace);
            }
            _hadPlaybackProgress = currentPosition > 0;
            final allowDecodedFrameRenderOnError = !widget.preferStableRemoteInit || !isChunkedRemoteProtocol;
            final hasLocalRecoverableFrame = !isRemoteManagedEntry && (hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
            final hasRemotePreviewFrame = hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0;
            final canRenderDespiteError = isRemoteManagedEntry
                ? isChunkedRemoteProtocol
                    ? widget.preferStableRemoteInit
                          ? hasStableDetailFrame
                          : false
                    : widget.preferStableRemoteInit
                        ? hasStableDetailFrame
                        : controller.isPlaying || hasRemotePreviewFrame
                : controller.isPlaying || controller.isReady || hasLocalRecoverableFrame || (hasDecodedFrame && allowDecodedFrameRenderOnError);
            final withinRemoteInitialErrorGrace = isRemoteStream && !hasDecodedFrame && DateTime.now().isBefore(_initialErrorGraceDeadline);
            final withinChunkedProgressRevealGrace = widget.preferStableRemoteInit && isRemoteStream && isChunkedRemoteProtocol && _chunkedProgressRevealDeadline != null && DateTime.now().isBefore(_chunkedProgressRevealDeadline!);
            final shouldKeepPlayerHiddenDuringChunkedInit = widget.preferStableRemoteInit && isRemoteStream && isChunkedRemoteProtocol && (!hasStableDetailFrame || withinChunkedProgressRevealGrace);
            final shouldKeepLocalPlayerHiddenUntilFrame = !isRemoteManagedEntry && !hasLocalRecoverableFrame;
            if (!isRemoteManagedEntry && settings.remoteLogEnabled) {
              final decision = status == VideoStatus.error
                  ? (canRenderDespiteError ? 'local_error_render_player' : 'local_error_hide_player')
                  : status == VideoStatus.idle
                      ? 'local_idle_hide_player'
                      : 'local_render_player';
              if (_lastLocalRenderDecision != decision) {
                _lastLocalRenderDecision = decision;
                unawaited(
                  remoteMediaLogService.log(
                    'autoplay',
                    'local video view render decision',
                    data: {
                      'uri': entry.uri,
                      'path': entry.path,
                      'decision': decision,
                      'status': status.name,
                      'isPlaying': controller.isPlaying,
                      'isReady': controller.isReady,
                      'positionMillis': currentPosition,
                      'hasDecodedFrame': hasDecodedFrame,
                      'hasFirstFrameRendered': hasFirstFrameRendered,
                    },
                  ),
                );
              }
            }
            if (shouldKeepPlayerHiddenDuringChunkedInit) {
              return const ColoredBox(color: Colors.transparent);
            }
            if (status == VideoStatus.error) {
              if (isChunkedRemotePreview) {
                return const ColoredBox(color: Colors.black);
              }
              if (canRenderDespiteError) {
                if (!_loggedSoftErrorRender) {
                  _loggedSoftErrorRender = true;
                  unawaited(
                    remoteMediaLogService.log(
                      'autoplay',
                      'video view keeps rendering despite controller error status',
                      data: {
                        'uri': entry.uri,
                        'isPlaying': controller.isPlaying,
                        'isReady': controller.isReady,
                        'hasDecodedFrame': hasDecodedFrame,
                        'hasFirstFrameRendered': hasFirstFrameRendered,
                      },
                    ),
                  );
                }
                return controller.buildPlayerWidget(context);
              }
              if (withinRemoteInitialErrorGrace || (isRemoteStream && isChunkedRemoteProtocol)) {
                return const ColoredBox(color: Colors.transparent);
              }
              return const ColoredBox(color: Colors.transparent);
            }
            _loggedSoftErrorRender = false;
            if (status == VideoStatus.idle) return const SizedBox();
            if (isChunkedRemotePreview) {
              return controller.buildPlayerWidget(context);
            }
            if (!widget.preferStableRemoteInit && isRemoteManagedEntry && !hasRemotePreviewFrame) {
              return const ColoredBox(color: Colors.transparent);
            }
            if (!widget.preferStableRemoteInit && !isRemoteManagedEntry) {
              return controller.buildPlayerWidget(context);
            }
            if (shouldKeepLocalPlayerHiddenUntilFrame) {
              return const ColoredBox(color: Colors.transparent);
            }
            if (widget.preferStableRemoteInit && isChunkedRemoteProtocol && !hasStableDetailFrame) {
              return const ColoredBox(color: Colors.transparent);
            }
            return controller.buildPlayerWidget(context);
          },
        );
      },
    );
  }

  // not called when looping
  void _onPlayCompleted() => controller.seekTo(0);
}
