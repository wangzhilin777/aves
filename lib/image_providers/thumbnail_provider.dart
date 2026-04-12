import 'dart:ui' as ui;

import 'package:aves/services/common/services.dart';
import 'package:aves_report/aves_report.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class ThumbnailProvider extends ImageProvider<ThumbnailProviderKey> {
  final ThumbnailProviderKey key;
  static const _transparentPngBytes = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ];

  ThumbnailProvider(this.key);

  @override
  Future<ThumbnailProviderKey> obtainKey(ImageConfiguration configuration) {
    // configuration can be empty (e.g. when obtaining key for eviction)
    // so we do not compute the target width/height here
    // and pass it to the key, to use it later for image loading
    return SynchronousFuture<ThumbnailProviderKey>(key);
  }

  @override
  ImageStreamCompleter loadImage(ThumbnailProviderKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: kReleaseMode ? null : [key.uri, key.extent].join('-'),
      informationCollector: () sync* {
        yield ErrorDescription('uri=${key.uri}, pageId=${key.pageId}, mimeType=${key.mimeType}, extent=${key.extent}');
      },
    );
  }

  Future<ui.Codec> _loadAsync(ThumbnailProviderKey key, ImageDecoderCallback decode) async {
    if (_isLocalProxyRemoteVideoStream(key) && !remoteMediaService.allowProxyVideoThumbnailForUri(key.uri)) {
      // For loopback remote video streams, let playback/first-frame and cached covers win.
      // Platform thumbnail extraction on the same proxy stream can contend with startup.
      return decode(await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(_transparentPngBytes)));
    }
    try {
      return await mediaFetchService.getThumbnail(
        decoded: false,
        request: key,
        decode: decode,
        taskKey: key,
      );
    } catch (error) {
      // loading may fail if the provided MIME type is incorrect (e.g. the Media Store may report a JPEG as a TIFF)
      debugPrint('$runtimeType _loadAsync failed for key=$key, error=$error');
      throw UnreportedStateError('thumbnail decoding failed for key=$key, error=$error');
    }
  }

  @override
  void resolveStreamForKey(ImageConfiguration configuration, ImageStream stream, ThumbnailProviderKey key, ImageErrorListener handleError) {
    mediaFetchService.resumeLoading(key);
    super.resolveStreamForKey(configuration, stream, key, handleError);
  }

  bool _isLocalProxyRemoteVideoStream(ThumbnailProviderKey key) {
    if (!key.mimeType.startsWith('video/')) return false;
    final uri = Uri.tryParse(key.uri);
    if (uri == null) return false;
    final isLoopbackHttp = (uri.scheme == 'http' || uri.scheme == 'https') && (uri.host == '127.0.0.1' || uri.host == 'localhost');
    return isLoopbackHttp && uri.path == '/remote-stream' && uri.queryParameters.containsKey('sid');
  }

  void pause() => mediaFetchService.cancelThumbnail(key);
}

@immutable
class ThumbnailProviderKey extends Equatable {
  // do not store the entry as it is, because the key should be constant
  // but the entry attributes may change over time
  final String uri, mimeType;
  final int? pageId;
  final int rotationDegrees;
  final bool isFlipped;
  final int dateModifiedMillis;
  final double extent;

  @override
  List<Object?> get props => [uri, pageId, dateModifiedMillis, extent];

  const ThumbnailProviderKey({
    required this.uri,
    required this.mimeType,
    required this.pageId,
    required this.rotationDegrees,
    required this.isFlipped,
    required this.dateModifiedMillis,
    this.extent = 0,
  });

  @override
  String toString() => '$runtimeType#${shortHash(this)}{uri=$uri, mimeType=$mimeType, pageId=$pageId, rotationDegrees=$rotationDegrees, isFlipped=$isFlipped, dateModifiedMillis=$dateModifiedMillis, extent=$extent}';
}
