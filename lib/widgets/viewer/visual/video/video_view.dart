import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/remote/remote_protocol.dart';
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
  AvesEntry get entry => widget.entry;

  AvesVideoController get controller => widget.controller;
  bool _loggedSoftErrorRender = false;
  late DateTime _initialErrorGraceDeadline;

  @override
  void initState() {
    super.initState();
    _initialErrorGraceDeadline = DateTime.now().add(_remoteInitialErrorGrace);
    _registerWidget(widget);
  }

  @override
  void didUpdateWidget(covariant VideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry) {
      _initialErrorGraceDeadline = DateTime.now().add(_remoteInitialErrorGrace);
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
        final status = snapshot.data ?? controller.status;
        final decodedSize = controller.decodedVideoSizeNotifier.value;
        final hasDecodedFrame = decodedSize != null && decodedSize.width > 1 && decodedSize.height > 1;
        final isRemoteStream = entry.uri.startsWith('http://') || entry.uri.startsWith('https://');
        final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
        final isChunkedRemoteProtocol =
            remoteProtocol == RemoteProtocol.ftp || remoteProtocol == RemoteProtocol.sftp || remoteProtocol == RemoteProtocol.smb;
        final canRenderDespiteError =
            controller.isPlaying || controller.isReady || (hasDecodedFrame && !isChunkedRemoteProtocol);
        final withinRemoteInitialErrorGrace = isRemoteStream && !hasDecodedFrame && DateTime.now().isBefore(_initialErrorGraceDeadline);
        final shouldKeepPlayerHiddenDuringChunkedInit =
            widget.preferStableRemoteInit && isRemoteStream && isChunkedRemoteProtocol && !controller.isPlaying && !controller.isReady;
        if (shouldKeepPlayerHiddenDuringChunkedInit) {
          return const ColoredBox(color: Colors.transparent);
        }
        if (status == VideoStatus.error) {
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
                  },
                ),
              );
            }
            return controller.buildPlayerWidget(context);
          }
          if (withinRemoteInitialErrorGrace) {
            return const ColoredBox(color: Colors.transparent);
          }
          return const ColoredBox(color: Colors.black);
        }
        _loggedSoftErrorRender = false;
        if (status == VideoStatus.idle) return const SizedBox();
        if (widget.preferStableRemoteInit && isChunkedRemoteProtocol && !controller.isPlaying && !controller.isReady) {
          return const ColoredBox(color: Colors.transparent);
        }
        return controller.buildPlayerWidget(context);
      },
    );
  }

  // not called when looping
  void _onPlayCompleted() => controller.seekTo(0);
}
