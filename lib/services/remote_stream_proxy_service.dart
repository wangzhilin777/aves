import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class RemoteProxyRequest {
  final String serverId;
  final String path;
  final String? rangeHeader;
  final String method;

  const RemoteProxyRequest({
    required this.serverId,
    required this.path,
    required this.method,
    this.rangeHeader,
  });
}

class RemoteProxyResponse {
  final int statusCode;
  final Stream<List<int>> stream;
  final String? contentType;
  final int? contentLength;
  final int? totalLength;
  final String? contentRange;
  final DateTime? lastModified;
  final bool acceptRanges;

  const RemoteProxyResponse({
    required this.statusCode,
    required this.stream,
    this.contentType,
    this.contentLength,
    this.totalLength,
    this.contentRange,
    this.lastModified,
    this.acceptRanges = true,
  });
}

class RemoteByteRange {
  final int start;
  final int endInclusive;
  final int totalLength;

  const RemoteByteRange({
    required this.start,
    required this.endInclusive,
    required this.totalLength,
  });

  int get contentLength => endInclusive - start + 1;

  String get contentRangeHeader => 'bytes $start-$endInclusive/$totalLength';
}

class RemoteStreamProxyService {
  static const _path = '/remote-stream';

  HttpServer? _server;
  Future<void>? _startFuture;
  Future<RemoteProxyResponse?> Function(RemoteProxyRequest request)? remoteRequestHandler;

  bool get isReady => _server != null;

  Uri? proxyUriFor(Uri remoteUri) {
    final server = _server;
    if (server == null) return null;
    final encoded = base64Url.encode(utf8.encode(remoteUri.toString()));
    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      path: _path,
      queryParameters: {'u': encoded},
    );
  }

  Uri? proxyUriForRemote({
    required String serverId,
    required String path,
  }) {
    final server = _server;
    if (server == null) return null;
    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      path: _path,
      queryParameters: {
        'sid': serverId,
        'path': base64Url.encode(utf8.encode(path)),
      },
    );
  }

  Future<void> ensureStarted() {
    final existing = _startFuture;
    if (existing != null) return existing;
    final future = _start();
    _startFuture = future;
    return future;
  }

  Future<void> _start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_listen(server));
  }

  Future<void> _listen(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != _path) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final serverId = request.uri.queryParameters['sid'];
    final encodedPath = request.uri.queryParameters['path'];
    if (serverId != null && encodedPath != null && encodedPath.isNotEmpty) {
      try {
        final decodedPath = utf8.decode(base64Url.decode(encodedPath));
        final handler = remoteRequestHandler;
        if (handler == null) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }
        final proxied = await handler(
          RemoteProxyRequest(
            serverId: serverId,
            path: decodedPath,
            method: request.method,
            rangeHeader: request.headers.value(HttpHeaders.rangeHeader),
          ),
        );
        if (proxied == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }

        final response = request.response;
        response.statusCode = proxied.statusCode;
        if (proxied.contentType != null && proxied.contentType!.isNotEmpty) {
          response.headers.set(HttpHeaders.contentTypeHeader, proxied.contentType!);
        }
        if (proxied.contentLength != null && proxied.contentLength! >= 0) {
          response.headers.set(HttpHeaders.contentLengthHeader, proxied.contentLength!);
        }
        if (proxied.acceptRanges) {
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        }
        if (proxied.contentRange != null && proxied.contentRange!.isNotEmpty) {
          response.headers.set(HttpHeaders.contentRangeHeader, proxied.contentRange!);
        }
        if (proxied.lastModified != null) {
          response.headers.set(HttpHeaders.lastModifiedHeader, HttpDate.format(proxied.lastModified!));
        }
        await proxied.stream.pipe(response);
      } catch (_) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      }
      return;
    }

    final encoded = request.uri.queryParameters['u'];
    if (encoded == null || encoded.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    Uri remoteUri;
    try {
      remoteUri = Uri.parse(utf8.decode(base64Url.decode(encoded)));
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    if (!(remoteUri.isScheme('http') || remoteUri.isScheme('https'))) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final targetUri = remoteUri.userInfo.isNotEmpty ? remoteUri.replace(userInfo: '') : remoteUri;
    final headers = <String, String>{};
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.isNotEmpty) {
      headers[HttpHeaders.rangeHeader] = range;
    }
    final userAgent = request.headers.value(HttpHeaders.userAgentHeader);
    if (userAgent != null && userAgent.isNotEmpty) {
      headers[HttpHeaders.userAgentHeader] = userAgent;
    }
    if (remoteUri.userInfo.isNotEmpty) {
      final token = base64Encode(utf8.encode(remoteUri.userInfo));
      headers[HttpHeaders.authorizationHeader] = 'Basic $token';
    }

    final client = http.Client();
    try {
      final upstreamRequest = http.Request(request.method, targetUri)..headers.addAll(headers);
      final upstreamResponse = await client.send(upstreamRequest);

      final response = request.response;
      response.statusCode = upstreamResponse.statusCode;
      for (final header in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.cacheControlHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = upstreamResponse.headers[header];
        if (value != null && value.isNotEmpty) {
          response.headers.set(header, value);
        }
      }

      await upstreamResponse.stream.pipe(response);
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    } finally {
      client.close();
    }
  }
}
