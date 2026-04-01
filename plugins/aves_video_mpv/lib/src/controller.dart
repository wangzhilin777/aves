import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/media/video/metadata.dart';
import 'package:aves_model/aves_model.dart';
import 'package:aves_utils/aves_utils.dart';
import 'package:aves_video/aves_video.dart';
import 'package:aves_video_mpv/src/tracks.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

class MpvVideoController extends AvesVideoController {
  late Player _mkPlayer;
  late VideoStatus _status;
  bool _abRepeatSeeking = false;
  final ValueNotifier<VideoController?> _mkControllerNotifier = ValueNotifier(null);
  final List<StreamSubscription> _subscriptions = [];
  final StreamController<VideoStatus> _statusStreamController = StreamController.broadcast();
  final StreamController<String?> _timedTextStreamController = StreamController.broadcast();
  final AChangeNotifier _completedNotifier = AChangeNotifier();
  final List<SubtitleTrack> _externalSubtitleTracks = [];
  List<Media> _mediaCandidates = const [];
  int _mediaCandidateIndex = 0;
  bool _recoveringFromStreamError = false;
  bool _openInProgress = false;
  bool _ignoreNextVisualRefresh = false;
  bool _metadataSyncInFlight = false;

  static final _pContext = p.Context();

  @override
  double get minSpeed => .25;

  @override
  double get maxSpeed => 4;

  @override
  final ValueNotifier<bool> canCaptureFrameNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canMuteNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canSetSpeedNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canSelectStreamNotifier = ValueNotifier(false);

  @override
  final ValueNotifier<double?> sarNotifier = ValueNotifier(null);

  MpvVideoController(
    super.entry, {
    required super.playbackStateHandler,
    required super.settings,
  }) {
    _status = VideoStatus.idle;
    _statusStreamController.add(_status);

    _mkPlayer = Player(
      configuration: PlayerConfiguration(
        title: entry.bestTitle ?? entry.uri,
        libass: false,
        logLevel: MPVLogLevel.warn,
        protocolWhitelist: [
          ...const PlayerConfiguration().protocolWhitelist,
          // Android `content` URIs are considered unsafe by default,
          // as they are transferred via a custom `fd` protocol
          'fd',
        ],
      ),
    );
    _initController();
    _init();

    _startListening();
  }

  @override
  Future<void> dispose() async {
    _stopListening();
    _stopStreamFetchTimer();
    await _statusStreamController.close();
    await _timedTextStreamController.close();
    await _mkPlayer.dispose();

    final _mkController = _mkControllerNotifier.value;
    _mkControllerNotifier.dispose();
    _mkController?.dispose();

    _completedNotifier.dispose();
    canCaptureFrameNotifier.dispose();
    canMuteNotifier.dispose();
    canSetSpeedNotifier.dispose();
    canSelectStreamNotifier.dispose();
    sarNotifier.dispose();

    await super.dispose();
  }

  void _startListening() {
    _subscriptions.add(statusStream.listen((v) => _status = v));

    final playerStream = _mkPlayer.stream;
    _subscriptions.add(
      playerStream.completed.listen((completed) {
        if (completed) {
          _statusStreamController.add(VideoStatus.completed);
          _completedNotifier.notify();

          // the player incorrectly loop for some videos
          // even when the playlist mode is configured not to loop
          // so we explicitly stop on completion
          final shouldStop = _mkPlayer.platform?.state.playlistMode == PlaylistMode.none;
          if (shouldStop) {
            pause();
          }
        }
      }),
    );
    _subscriptions.add(
      playerStream.playing.listen((playing) {
        if (status == VideoStatus.idle) return;
        _statusStreamController.add(playing ? VideoStatus.playing : VideoStatus.paused);
      }),
    );
    _subscriptions.add(
      playerStream.position.listen((v) {
        final abRepeat = abRepeatNotifier.value;
        if (abRepeat != null && status == VideoStatus.playing) {
          final start = abRepeat.start;
          final end = abRepeat.end;
          if (start != null && end != null) {
            if (v.inMilliseconds < end) {
              _abRepeatSeeking = false;
            } else if (!_abRepeatSeeking) {
              _abRepeatSeeking = true;
              _mkPlayer.seek(Duration(milliseconds: start));
            }
          }
        }
      }),
    );
    _subscriptions.add(playerStream.subtitle.listen((v) => _timedTextStreamController.add(v.isEmpty ? null : v[0])));
    _subscriptions.add(
      playerStream.videoParams.listen((v) {
        sarNotifier.value = v.par;
        _syncEntryGeometry(v);
        unawaited(_syncEntryPlaybackMetadata());
      }),
    );
    _subscriptions.add(playerStream.log.listen((v) => debugPrint('libmpv log: $v')));
    _subscriptions.add(
      playerStream.error.listen((v) {
        debugPrint('libmpv error: $v');
        unawaited(_recoverFromRemoteStreamError());
      }),
    );

    final settingsStream = settings.updateStream;
    _subscriptions.add(settingsStream.where((event) => event.key == SettingKeys.videoHardwareAccelerationKey).listen((_) => _initController()));
    _subscriptions.add(settingsStream.where((event) => event.key == SettingKeys.videoLoopModeKey).listen((_) => _applyLoop()));

    final path = entry.path;
    if (path != null) {
      final sourceFile = File(path);
      if (sourceFile.existsSync()) {
        final videoBasename = _pContext.basenameWithoutExtension(path);
        // list subtitle files in the same directory
        // some files may be visible to the app (e.g. SRT) while others may not (e.g. SUB, VTT)
        _subscriptions.add(
          sourceFile.parent.list().where((v) => v is File && _isSubtitle(v.path)).listen(
            (v) {
              final subtitleBasename = _pContext.basename(v.path);
              if (subtitleBasename.startsWith(videoBasename)) {
                _externalSubtitleTracks.add(
                  SubtitleTrack.uri(
                    v.uri.toString(),
                    title: 'File ${subtitleBasename.substring(videoBasename.length)}',
                  ),
                );
                _externalSubtitleTracks.sort((a, b) => a.title!.compareTo(b.title!));
              }
            },
            onError: (_) {},
          ),
        );
      }
    }
  }

  void _stopListening() {
    _subscriptions
      ..forEach((sub) => sub.cancel())
      ..clear();
  }

  Future<void> _applyLoop() async {
    final loopEnabled = settings.videoLoopMode.shouldLoop(entry);
    await _mkPlayer.setPlaylistMode(loopEnabled ? PlaylistMode.single : PlaylistMode.none);
  }

  Future<void> _init({int startMillis = 0}) async {
    if (_openInProgress) return;
    _openInProgress = true;
    try {
      final playing = _mkPlayer.state.playing;

      // Audio quality is better with `audiotrack` than `opensles` (the default).
      // Calling `setAudioDevice` does not seem to work.
      // As of 2025/01/13, directly setting audio output via property works for some files but not all,
      // and switching from a supported file to an unsupported file crashes:
      // cf https://github.com/media-kit/media-kit/issues/1061

      await _applyLoop();
      _mediaCandidates = _buildMediaCandidatesForPlayback();
      if (_mediaCandidates.isEmpty) {
        _mediaCandidates = [Media(entry.uri)];
      }
      _mediaCandidateIndex = 0;
      await _mkPlayer.open(_mediaCandidates[_mediaCandidateIndex], play: playing);
      await _mkPlayer.setSubtitleTrack(SubtitleTrack.no());
      if (startMillis > 0) {
        await seekTo(startMillis);
      }

      _fetchStreams();
      _statusStreamController.add(_mkPlayer.state.playing ? VideoStatus.playing : VideoStatus.paused);
    } finally {
      _openInProgress = false;
    }
  }

  List<Media> _buildMediaCandidatesForPlayback() {
    final rawUri = entry.uri;
    final uri = Uri.tryParse(rawUri);
    if (uri == null) {
      return [Media(rawUri)];
    }
    if ((uri.isScheme('http') || uri.isScheme('https')) && uri.userInfo.isNotEmpty) {
      final auth = base64Encode(utf8.encode(uri.userInfo));
      return [
        Media(
          uri.replace(userInfo: '').toString(),
          httpHeaders: {
            'Authorization': 'Basic $auth',
          },
        ),
        // fallback for servers/player paths that reject header auth
        Media(rawUri),
      ];
    }
    return [Media(rawUri)];
  }

  Future<void> _recoverFromRemoteStreamError() async {
    if (_recoveringFromStreamError || _openInProgress) {
      return;
    }
    final uri = Uri.tryParse(entry.uri);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      _statusStreamController.add(VideoStatus.error);
      return;
    }
    if (_mediaCandidateIndex + 1 >= _mediaCandidates.length) {
      _statusStreamController.add(VideoStatus.error);
      return;
    }

    _recoveringFromStreamError = true;
    try {
      _mediaCandidateIndex += 1;
      final shouldPlay = _mkPlayer.state.playing || _status == VideoStatus.playing;
      await _mkPlayer.open(_mediaCandidates[_mediaCandidateIndex], play: shouldPlay);
      await _mkPlayer.setSubtitleTrack(SubtitleTrack.no());
      _statusStreamController.add(_mkPlayer.state.playing ? VideoStatus.playing : VideoStatus.paused);
    } catch (_) {
      _statusStreamController.add(VideoStatus.error);
    } finally {
      _recoveringFromStreamError = false;
    }
  }

  void _initController() {
    final hardwareAcceleration = settings.videoHardwareAcceleration;
    String hwdec;
    switch (settings.videoHardwareAcceleration) {
      case .disabled:
        hwdec = 'no';
      case .enabled:
        hwdec = 'auto-safe';
      case .forced:
        hwdec = 'mediacodec';
    }
    final oldController = _mkControllerNotifier.value;
    final newController =
        VideoController(
            _mkPlayer,
            configuration: VideoControllerConfiguration(
              hwdec: hwdec,
              enableHardwareAcceleration: hardwareAcceleration != VideoHardwareAcceleration.disabled,
            ),
          )
          ..waitUntilFirstFrameRendered.then((v) {
            _statusStreamController.add(_status);
          });
    _mkControllerNotifier.value = newController;
    oldController?.dispose();
  }

  void _syncEntryGeometry(VideoParams params) {
    if (entry is! AvesEntry) {
      return;
    }
    final mediaEntry = entry as AvesEntry;
    final width = params.w;
    final height = params.h;
    final rotate = params.rotate;
    var changed = false;

    if (width != null && height != null && width > 1 && height > 1 && (mediaEntry.width != width || mediaEntry.height != height)) {
      mediaEntry.width = width;
      mediaEntry.height = height;
      changed = true;
    }
    if (rotate != null && rotate != mediaEntry.sourceRotationDegrees) {
      mediaEntry.sourceRotationDegrees = rotate;
      changed = true;
    }

    if (changed) {
      _ignoreNextVisualRefresh = true;
      mediaEntry.visualChangeNotifier.notify();
      _statusStreamController.add(_status);
    }
  }

  @override
  void onVisualChanged() {
    if (_ignoreNextVisualRefresh) {
      _ignoreNextVisualRefresh = false;
      return;
    }
    _init(startMillis: currentPosition);
  }

  @override
  Future<void> play() async {
    if (status == VideoStatus.error) {
      await _recoverFromRemoteStreamError();
      if (status == VideoStatus.error) {
        await _init(startMillis: currentPosition);
      }
    }
    try {
      await untilReady.timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _mkPlayer.play();
  }

  @override
  Future<void> pause() => _mkPlayer.pause();

  @override
  Future<void> seekTo(int targetMillis) async {
    if (!isReady) {
      await untilReady;
      // When the player gets ready, it can play from the beginning right away,
      // but trying to seek then just plays from the start.
      // There is no state or hook identifying readiness to seek on start,
      // and `PlayerConfiguration.ready` hook is useless.
      await Future.delayed(const Duration(milliseconds: 500));
    }
    targetMillis = abRepeatNotifier.value?.clamp(targetMillis) ?? targetMillis;
    await _mkPlayer.seek(Duration(milliseconds: targetMillis));
  }

  @override
  Future<void> skipFrames(int frameCount) async {
    final platform = _mkPlayer.platform;
    if (platform is NativePlayer) {
      if (frameCount > 0) {
        await platform.command(['frame-step']);
      } else if (frameCount < 0) {
        await platform.command(['frame-back-step']);
      }
    } else {
      throw Exception('Platform player ${platform.runtimeType} does not support frame stepping');
    }
  }

  @override
  Listenable get playCompletedListenable => _completedNotifier;

  @override
  VideoStatus get status => _status;

  @override
  Stream<VideoStatus> get statusStream => _statusStreamController.stream;

  @override
  Stream<double> get volumeStream => _mkPlayer.stream.volume;

  @override
  Stream<double> get speedStream => _mkPlayer.stream.rate;

  @override
  bool get isReady {
    switch (_status) {
      case .error:
      case .idle:
      case .initialized:
        return false;
      case .paused:
      case .playing:
      case .completed:
        return true;
    }
  }

  @override
  int get duration => _mkPlayer.state.duration.inMilliseconds;

  @override
  int get currentPosition => _mkPlayer.state.position.inMilliseconds;

  @override
  Stream<int> get positionStream => _mkPlayer.stream.position.map((pos) => pos.inMilliseconds);

  @override
  Stream<String?> get timedTextStream => _timedTextStreamController.stream;

  @override
  bool get isMuted => _mkPlayer.state.volume == 0;

  @override
  Future<void> mute(bool muted) => _mkPlayer.setVolume(muted ? 0 : 100);

  @override
  double get speed => _mkPlayer.state.rate;

  @override
  set speed(double speed) => _mkPlayer.setRate(speed);

  @override
  Future<Uint8List?> captureFrame() => _mkPlayer.screenshot();

  @override
  Widget buildPlayerWidget(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: sarNotifier,
      builder: (context, sar, child) {
        // derive DAR (Display Aspect Ratio) from SAR (Storage Aspect Ratio), if any
        // e.g. 960x536 (~16:9) with SAR 4:3 should be displayed as ~2.39:1
        final dar = entry.displayAspectRatio * (sar ?? 1);
        return ValueListenableBuilder<VideoController?>(
          valueListenable: _mkControllerNotifier,
          builder: (context, controller, child) {
            if (controller == null) return const SizedBox();
            return Video(
              controller: controller,
              fill: Colors.transparent,
              aspectRatio: dar,
              controls: NoVideoControls,
              wakelock: false,
              subtitleViewConfiguration: const SubtitleViewConfiguration(
                visible: false,
              ),
            );
          },
        );
      },
    );
  }

  // streams (aka tracks)

  // `auto` and `no` are the first 2 tracks in the player state track lists
  static const int fakeTrackCount = 2;

  Tracks get _tracks => _mkPlayer.state.tracks;

  List<VideoTrack> get _videoTracks => _tracks.video.skip(fakeTrackCount).toList();

  List<AudioTrack> get _audioTracks => _tracks.audio.skip(fakeTrackCount).toList();

  List<SubtitleTrack> get _subtitleTracks {
    final externalTitles = _externalSubtitleTracks.map((v) => v.title).toSet();
    return [
      ..._tracks.subtitle.skip(fakeTrackCount).where((v) => !externalTitles.contains(v.title)),
      ..._externalSubtitleTracks,
    ];
  }

  @override
  List<MediaStreamSummary> get streams {
    return {
      ..._videoTracks.mapIndexed((i, v) => v.toAves(i)),
      ..._audioTracks.mapIndexed((i, v) => v.toAves(i)),
      ..._subtitleTracks.mapIndexed((i, v) => v.toAves(i)),
    }.toList();
  }

  Timer? _streamFetchTimer;

  void _stopStreamFetchTimer() {
    _streamFetchTimer?.cancel();
    _streamFetchTimer = null;
  }

  void _fetchStreams() {
    _stopStreamFetchTimer();
    _streamFetchTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (status != VideoStatus.error) {
        if (_videoTracks.isEmpty && _audioTracks.isEmpty) return;

        final videoStreamCount = _videoTracks.length;
        final audioStreamCount = _audioTracks.length;
        final textStreamCount = _subtitleTracks.length;
        canSelectStreamNotifier.value = videoStreamCount > 1 || audioStreamCount > 1 || textStreamCount > 0;
        unawaited(_syncEntryPlaybackMetadata());
      }
      _stopStreamFetchTimer();
    });
  }

  Future<void> _syncEntryPlaybackMetadata() async {
    if (_metadataSyncInFlight || entry is! AvesEntry) {
      return;
    }
    final mediaEntry = entry as AvesEntry;
    _metadataSyncInFlight = true;
    try {
      var changed = false;

      final durationMillis = _mkPlayer.state.duration.inMilliseconds;
      if (durationMillis > 0 && mediaEntry.durationMillis != durationMillis) {
        mediaEntry.durationMillis = durationMillis;
        changed = true;
      }

      if (mediaEntry.catalogDateMillis == null && mediaEntry.sourceDateTakenMillis == null) {
        try {
          final catalogMetadata = await VideoMetadataFormatter.completeCatalogMetadata(mediaEntry);
          if (catalogMetadata != null) {
            mediaEntry.catalogMetadata = catalogMetadata;
            changed = true;
          }
        } catch (_) {}
      }

      if (changed) {
        mediaEntry.metadataChangeNotifier.notify();
      }
    } finally {
      _metadataSyncInFlight = false;
    }
  }

  @override
  Future<MediaStreamSummary?> getSelectedStream(MediaStreamType type) async {
    final track = _mkPlayer.state.track;
    switch (type) {
      case .video:
        final video = track.video;
        if (video != VideoTrack.no()) {
          final index = video == VideoTrack.auto() ? 0 : _videoTracks.indexOf(video);
          return video.toAves(index);
        }
      case .audio:
        final audio = track.audio;
        if (audio != AudioTrack.no()) {
          final index = audio == AudioTrack.auto() ? 0 : _audioTracks.indexOf(audio);
          return audio.toAves(index);
        }
      case .text:
        final subtitle = track.subtitle;
        if (subtitle != SubtitleTrack.no()) {
          final index = subtitle == SubtitleTrack.auto() ? 0 : _subtitleTracks.indexOf(subtitle);
          return subtitle.toAves(index);
        }
    }
    return null;
  }

  @override
  Future<void> selectStream(MediaStreamType type, MediaStreamSummary? selected) async {
    final current = await getSelectedStream(type);
    if (current == selected) return;

    if (selected != null) {
      final newIndex = selected.index;
      if (newIndex != null) {
        // select track
        switch (type) {
          case .video:
            await _mkPlayer.setVideoTrack(_videoTracks[selected.index ?? 0]);
            break;
          case .audio:
            await _mkPlayer.setAudioTrack(_audioTracks[selected.index ?? 0]);
            break;
          case .text:
            await _mkPlayer.setSubtitleTrack(_subtitleTracks[selected.index ?? 0]);
            break;
        }
      }
    } else if (current != null) {
      // deselect track
      switch (type) {
        case .video:
          await _mkPlayer.setVideoTrack(VideoTrack.no());
          break;
        case .audio:
          await _mkPlayer.setAudioTrack(AudioTrack.no());
          break;
        case .text:
          await _mkPlayer.setSubtitleTrack(SubtitleTrack.no());
          break;
      }
    }
  }

  static const Set<String> _subtitleExtensions = {'.srt', '.sub', '.vtt'};

  static bool _isSubtitle(String path) => _subtitleExtensions.contains(_pContext.extension(path));
}
