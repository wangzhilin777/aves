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
  static const _ftpVisibleProgressThreshold = 160;
  AvesEntry get entry => widget.entry;

  AvesVideoController get controller => widget.controller;
  bool _loggedSoftErrorRender = false;
  late DateTime _initialErrorGraceDeadline;
  DateTime? _chunkedProgressRevealDeadline;
  bool _hadPlaybackProgress = false;
  String? _lastLocalRenderDecision;
  String? _lastRemoteRenderDecision;

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

  void _logRenderDecision({
    required String decision,
    required VideoStatus status,
    required int currentPosition,
    required bool isRemoteManagedEntry,
    required RemoteProtocol? remoteProtocol,
    required bool hasDecodedFrame,
    required bool hasFirstFrameRendered,
    required bool hasStableDetailFrame,
    required bool withinRemoteInitialErrorGrace,
    required bool withinChunkedProgressRevealGrace,
    required bool shouldKeepPlayerHiddenDuringChunkedInit,
  }) {
    if (!settings.remoteLogEnabled) return;
    final key =
        '$decision|${status.name}|${controller.isPlaying}|${controller.isReady}|$hasDecodedFrame|$hasFirstFrameRendered|${currentPosition > 0}|$hasStableDetailFrame|$withinRemoteInitialErrorGrace|$withinChunkedProgressRevealGrace|$shouldKeepPlayerHiddenDuringChunkedInit';
    if (isRemoteManagedEntry) {
      if (_lastRemoteRenderDecision == key) return;
      _lastRemoteRenderDecision = key;
    } else {
      if (_lastLocalRenderDecision == key) return;
      _lastLocalRenderDecision = key;
    }
    unawaited(
      remoteMediaLogService.log(
        'autoplay',
        'video view render decision',
        data: {
          'uri': entry.uri,
          'path': entry.path,
          'protocol': remoteProtocol?.name,
          'preferStableRemoteInit': widget.preferStableRemoteInit,
          'decision': decision,
          'status': status.name,
          'isPlaying': controller.isPlaying,
          'isReady': controller.isReady,
          'positionMillis': currentPosition,
          'hasDecodedFrame': hasDecodedFrame,
          'hasFirstFrameRendered': hasFirstFrameRendered,
          'hasStableDetailFrame': hasStableDetailFrame,
          'withinRemoteInitialErrorGrace': withinRemoteInitialErrorGrace,
          'withinChunkedProgressRevealGrace': withinChunkedProgressRevealGrace,
          'shouldKeepPlayerHiddenDuringChunkedInit': shouldKeepPlayerHiddenDuringChunkedInit,
        },
      ),
    );
  }

  Widget _buildFtpMountedPlayer({required bool visible}) {
    return IgnorePointer(
      ignoring: !visible,
      child: Opacity(
        opacity: visible ? 1 : 0,
        child: controller.buildPlayerWidget(context),
      ),
    );
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
            final isFtpProtocol = remoteProtocol == RemoteProtocol.ftp;
            final isSftpProtocol = remoteProtocol == RemoteProtocol.sftp;
            final isSmbProtocol = remoteProtocol == RemoteProtocol.smb;
            final isChunkedRemoteProtocol = isFtpProtocol || isSftpProtocol || isSmbProtocol;
            final isChunkedRemotePreview = isChunkedRemoteProtocol && !widget.preferStableRemoteInit;
            final isLargeWebdavDetail = widget.preferStableRemoteInit && isRemoteStream && remoteProtocol == RemoteProtocol.webdav && remoteMediaService.isLargeRemoteVideoEntry(entry);
            final hasRenderableFrame = hasDecodedFrame || hasFirstFrameRendered;
            final hasStableDetailFrame = controller.isPlaying && currentPosition > 0 && (hasFirstFrameRendered || hasDecodedFrame);
            final gainedPlaybackProgress = currentPosition > 0 && !_hadPlaybackProgress;
            if (gainedPlaybackProgress && widget.preferStableRemoteInit && isRemoteStream && isChunkedRemoteProtocol) {
              _chunkedProgressRevealDeadline = DateTime.now().add(_chunkedRemoteProgressRevealGrace);
            }
            _hadPlaybackProgress = currentPosition > 0;
            final allowDecodedFrameRenderOnError = !widget.preferStableRemoteInit || !isChunkedRemoteProtocol;
            final hasLocalRecoverableFrame = !isRemoteManagedEntry && (hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0);
            final hasRemotePreviewFrame = hasDecodedFrame || hasFirstFrameRendered || currentPosition > 0;
            final hasFtpVisibleFrame = currentPosition >= _ftpVisibleProgressThreshold && (hasDecodedFrame || hasFirstFrameRendered);
            final hasFtpPreviewFrame = hasFtpVisibleFrame;
            final shouldKeepFtpPlayerHiddenUntilStableProgress = isFtpProtocol && !hasFtpVisibleFrame;
            final withinRemoteInitialErrorGrace = isRemoteStream && !hasDecodedFrame && DateTime.now().isBefore(_initialErrorGraceDeadline);
            final withinChunkedProgressRevealGrace = widget.preferStableRemoteInit && isRemoteStream && isChunkedRemoteProtocol && _chunkedProgressRevealDeadline != null && DateTime.now().isBefore(_chunkedProgressRevealDeadline!);
            final allowFtpStableDetailRender = widget.preferStableRemoteInit && isFtpProtocol && hasFtpVisibleFrame;
            final allowSftpStableDetailRender = widget.preferStableRemoteInit && isSftpProtocol && (hasDecodedFrame || hasFirstFrameRendered || (currentPosition > 0 && !withinChunkedProgressRevealGrace));
            final allowSmbStableDetailRender = widget.preferStableRemoteInit && isSmbProtocol && (hasDecodedFrame || hasFirstFrameRendered || (currentPosition > 0 && !withinChunkedProgressRevealGrace));
            final allowLargeWebdavDetailRender = isLargeWebdavDetail && hasRenderableFrame;
            final canRenderDespiteError = isRemoteManagedEntry
                ? isChunkedRemoteProtocol
                      ? (widget.preferStableRemoteInit ? allowFtpStableDetailRender || allowSftpStableDetailRender || allowSmbStableDetailRender || hasStableDetailFrame : false)
                      : (widget.preferStableRemoteInit ? (isLargeWebdavDetail ? allowLargeWebdavDetailRender || hasStableDetailFrame : hasStableDetailFrame) : controller.isPlaying || hasRemotePreviewFrame)
                : controller.isPlaying || controller.isReady || hasLocalRecoverableFrame || (hasDecodedFrame && allowDecodedFrameRenderOnError);
            final shouldKeepPlayerHiddenDuringStableRemoteInit =
                widget.preferStableRemoteInit &&
                isRemoteStream &&
                ((isChunkedRemoteProtocol && ((isFtpProtocol && !allowFtpStableDetailRender) || (isSftpProtocol && !allowSftpStableDetailRender) || (isSmbProtocol && !allowSmbStableDetailRender))) ||
                    (isLargeWebdavDetail && !allowLargeWebdavDetailRender));
            final shouldKeepLocalPlayerHiddenUntilFrame = !isRemoteManagedEntry && !hasLocalRecoverableFrame;
            if (allowFtpStableDetailRender) {
              _logRenderDecision(
                decision: 'ftp_detail_render_player_with_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return _buildFtpMountedPlayer(visible: true);
            }
            if (allowSftpStableDetailRender) {
              _logRenderDecision(
                decision: 'sftp_detail_render_player_with_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return controller.buildPlayerWidget(context);
            }
            if (allowSmbStableDetailRender) {
              _logRenderDecision(
                decision: 'smb_detail_render_player_with_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return controller.buildPlayerWidget(context);
            }
            if (isLargeWebdavDetail && allowLargeWebdavDetailRender) {
              _logRenderDecision(
                decision: 'large_webdav_detail_render_player_with_stable_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return controller.buildPlayerWidget(context);
            }
            if (shouldKeepPlayerHiddenDuringStableRemoteInit) {
              _logRenderDecision(
                decision: isLargeWebdavDetail ? 'large_webdav_hide_player_for_stable_init' : 'chunked_hide_player_for_stable_init',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              if (isFtpProtocol) {
                return _buildFtpMountedPlayer(visible: false);
              }
              return const ColoredBox(color: Colors.transparent);
            }
            if (status == VideoStatus.error) {
              if (isLargeWebdavDetail && hasRemotePreviewFrame) {
                _logRenderDecision(
                  decision: 'large_webdav_detail_render_player_with_preview_frame',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                return controller.buildPlayerWidget(context);
              }
              if (widget.preferStableRemoteInit && isFtpProtocol && hasFtpPreviewFrame) {
                _logRenderDecision(
                  decision: 'ftp_detail_render_player_with_preview_frame',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                return _buildFtpMountedPlayer(visible: true);
              }
              if (widget.preferStableRemoteInit && isSftpProtocol && hasRemotePreviewFrame) {
                _logRenderDecision(
                  decision: 'sftp_detail_render_player_with_preview_frame',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                return controller.buildPlayerWidget(context);
              }
              if (widget.preferStableRemoteInit && isSmbProtocol && hasRemotePreviewFrame) {
                _logRenderDecision(
                  decision: 'smb_detail_render_player_with_preview_frame',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                return controller.buildPlayerWidget(context);
              }
              if (isChunkedRemotePreview) {
                if (hasRemotePreviewFrame) {
                  _logRenderDecision(
                    decision: 'chunked_error_render_player_with_preview_frame',
                    status: status,
                    currentPosition: currentPosition,
                    isRemoteManagedEntry: isRemoteManagedEntry,
                    remoteProtocol: remoteProtocol,
                    hasDecodedFrame: hasDecodedFrame,
                    hasFirstFrameRendered: hasFirstFrameRendered,
                    hasStableDetailFrame: hasStableDetailFrame,
                    withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                    withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                    shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                  );
                  return isFtpProtocol ? _buildFtpMountedPlayer(visible: true) : controller.buildPlayerWidget(context);
                }
                if (isFtpProtocol) {
                  _logRenderDecision(
                    decision: 'ftp_error_hide_until_preview_frame',
                    status: status,
                    currentPosition: currentPosition,
                    isRemoteManagedEntry: isRemoteManagedEntry,
                    remoteProtocol: remoteProtocol,
                    hasDecodedFrame: hasDecodedFrame,
                    hasFirstFrameRendered: hasFirstFrameRendered,
                    hasStableDetailFrame: hasStableDetailFrame,
                    withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                    withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                    shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                  );
                  return _buildFtpMountedPlayer(visible: false);
                }
                if (isSftpProtocol) {
                  _logRenderDecision(
                    decision: 'sftp_error_hide_until_preview_frame',
                    status: status,
                    currentPosition: currentPosition,
                    isRemoteManagedEntry: isRemoteManagedEntry,
                    remoteProtocol: remoteProtocol,
                    hasDecodedFrame: hasDecodedFrame,
                    hasFirstFrameRendered: hasFirstFrameRendered,
                    hasStableDetailFrame: hasStableDetailFrame,
                    withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                    withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                    shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                  );
                  return const ColoredBox(color: Colors.transparent);
                }
                if (isSmbProtocol) {
                  _logRenderDecision(
                    decision: 'smb_error_hide_until_preview_frame',
                    status: status,
                    currentPosition: currentPosition,
                    isRemoteManagedEntry: isRemoteManagedEntry,
                    remoteProtocol: remoteProtocol,
                    hasDecodedFrame: hasDecodedFrame,
                    hasFirstFrameRendered: hasFirstFrameRendered,
                    hasStableDetailFrame: hasStableDetailFrame,
                    withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                    withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                    shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                  );
                  return const ColoredBox(color: Colors.transparent);
                }
                _logRenderDecision(
                  decision: 'chunked_error_black_fallback',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                return const ColoredBox(color: Colors.transparent);
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
                _logRenderDecision(
                  decision: 'error_render_player_despite_error',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                return isFtpProtocol ? _buildFtpMountedPlayer(visible: true) : controller.buildPlayerWidget(context);
              }
              if (withinRemoteInitialErrorGrace || (isRemoteStream && isChunkedRemoteProtocol)) {
                _logRenderDecision(
                  decision: 'error_hide_player_during_grace',
                  status: status,
                  currentPosition: currentPosition,
                  isRemoteManagedEntry: isRemoteManagedEntry,
                  remoteProtocol: remoteProtocol,
                  hasDecodedFrame: hasDecodedFrame,
                  hasFirstFrameRendered: hasFirstFrameRendered,
                  hasStableDetailFrame: hasStableDetailFrame,
                  withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                  withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                  shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
                );
                if (isFtpProtocol) {
                  return _buildFtpMountedPlayer(visible: false);
                }
                return const ColoredBox(color: Colors.transparent);
              }
              _logRenderDecision(
                decision: 'error_hide_player',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const ColoredBox(color: Colors.transparent);
            }
            _loggedSoftErrorRender = false;
            if (status == VideoStatus.idle) {
              _logRenderDecision(
                decision: 'idle_hide_player',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const SizedBox();
            }
            if (shouldKeepFtpPlayerHiddenUntilStableProgress) {
              _logRenderDecision(
                decision: 'ftp_hide_player_until_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return _buildFtpMountedPlayer(visible: false);
            }
            if (isSftpProtocol && !hasRemotePreviewFrame) {
              _logRenderDecision(
                decision: 'sftp_hide_player_until_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const ColoredBox(color: Colors.transparent);
            }
            if (isSmbProtocol && !hasRemotePreviewFrame) {
              _logRenderDecision(
                decision: 'smb_hide_player_until_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const ColoredBox(color: Colors.transparent);
            }
            if (isChunkedRemotePreview) {
              _logRenderDecision(
                decision: 'chunked_render_player',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return isFtpProtocol ? _buildFtpMountedPlayer(visible: true) : controller.buildPlayerWidget(context);
            }
            if (isLargeWebdavDetail && !hasRenderableFrame) {
              _logRenderDecision(
                decision: 'large_webdav_hide_player_until_displayable_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const ColoredBox(color: Colors.transparent);
            }
            if (!widget.preferStableRemoteInit && isRemoteManagedEntry && !hasRemotePreviewFrame) {
              _logRenderDecision(
                decision: 'remote_hide_player_until_preview_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const ColoredBox(color: Colors.transparent);
            }
            if (!widget.preferStableRemoteInit && !isRemoteManagedEntry) {
              _logRenderDecision(
                decision: 'local_render_player',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return controller.buildPlayerWidget(context);
            }
            if (shouldKeepLocalPlayerHiddenUntilFrame) {
              _logRenderDecision(
                decision: 'local_hide_player_until_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              return const ColoredBox(color: Colors.transparent);
            }
            if (widget.preferStableRemoteInit && isChunkedRemoteProtocol && !hasStableDetailFrame) {
              _logRenderDecision(
                decision: 'chunked_hide_player_until_stable_detail_frame',
                status: status,
                currentPosition: currentPosition,
                isRemoteManagedEntry: isRemoteManagedEntry,
                remoteProtocol: remoteProtocol,
                hasDecodedFrame: hasDecodedFrame,
                hasFirstFrameRendered: hasFirstFrameRendered,
                hasStableDetailFrame: hasStableDetailFrame,
                withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
                withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
                shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
              );
              if (isFtpProtocol) {
                return _buildFtpMountedPlayer(visible: false);
              }
              return const ColoredBox(color: Colors.transparent);
            }
            _logRenderDecision(
              decision: 'render_player',
              status: status,
              currentPosition: currentPosition,
              isRemoteManagedEntry: isRemoteManagedEntry,
              remoteProtocol: remoteProtocol,
              hasDecodedFrame: hasDecodedFrame,
              hasFirstFrameRendered: hasFirstFrameRendered,
              hasStableDetailFrame: hasStableDetailFrame,
              withinRemoteInitialErrorGrace: withinRemoteInitialErrorGrace,
              withinChunkedProgressRevealGrace: withinChunkedProgressRevealGrace,
              shouldKeepPlayerHiddenDuringChunkedInit: shouldKeepPlayerHiddenDuringStableRemoteInit,
            );
            return isFtpProtocol ? _buildFtpMountedPlayer(visible: true) : controller.buildPlayerWidget(context);
          },
        );
      },
    );
  }

  // not called when looping
  void _onPlayCompleted() => controller.seekTo(0);
}
