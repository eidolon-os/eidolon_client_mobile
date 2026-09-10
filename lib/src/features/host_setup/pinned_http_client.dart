import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum PinnedHttpFailureKind {
  cancelled,
  invalidRequest,
  unsupportedPlatform,
  secureChannel,
  timeout,
  unreachable,
  io,
  platform,
}

class PinnedHttpException extends http.ClientException {
  PinnedHttpException({
    required this.kind,
    required String message,
    Uri? uri,
    this.platformCode,
  }) : super(message, uri);

  final PinnedHttpFailureKind kind;
  final String? platformCode;

  factory PinnedHttpException.fromPlatform(
    PlatformException error, {
    required Uri uri,
  }) {
    final kind = switch (error.code) {
      'PINNED_HTTPS_CANCELLED' => PinnedHttpFailureKind.cancelled,
      'PINNED_HTTPS_INVALID_REQUEST' => PinnedHttpFailureKind.invalidRequest,
      'PINNED_HTTPS_SECURE_CHANNEL_FAILED' =>
        PinnedHttpFailureKind.secureChannel,
      'PINNED_HTTPS_TIMEOUT' => PinnedHttpFailureKind.timeout,
      'PINNED_HTTPS_UNREACHABLE' => PinnedHttpFailureKind.unreachable,
      'PINNED_HTTPS_IO_FAILED' => PinnedHttpFailureKind.io,
      _ => PinnedHttpFailureKind.platform,
    };
    return PinnedHttpException(
      kind: kind,
      message: error.message ?? 'Pinned HTTPS platform request failed',
      uri: uri,
      platformCode: error.code,
    );
  }
}

/// Android-backed, Host-SPKI-pinned transport for bounded unary Local API calls.
///
/// This layer transports HTTP semantics but does not duplicate the Local API's
/// route/method allowlist. Long-lived streams such as Mission Control SSE use a
/// separate lifecycle-aware transport.
class PlatformPinnedHttpClient extends http.BaseClient {
  PlatformPinnedHttpClient({
    required this.tlsSpkiFingerprint,
    this.requestTimeout = const Duration(seconds: 8),
    MethodChannel? channel,
  })  : ownerRootCertificate = null,
        addressHints = const {},
        _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  PlatformPinnedHttpClient.ownerDomain({
    required this.ownerRootCertificate,
    this.addressHints = const {},
    this.requestTimeout = const Duration(seconds: 8),
    MethodChannel? channel,
  })  : tlsSpkiFingerprint = null,
        _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  static const _protocolVersion = 1;
  static const _maxBodyBytes = 1024 * 1024;

  final String? tlsSpkiFingerprint;
  final String? ownerRootCertificate;
  final Map<String, String> addressHints;
  final MethodChannel _channel;
  final Duration requestTimeout;
  static int _nextRequest = 0;
  final Set<String> _pending = {};
  bool _closed = false;

  void _ensureOpen(Uri uri) {
    if (_closed) {
      throw PinnedHttpException(
          kind: PinnedHttpFailureKind.cancelled,
          message: 'Pinned HTTPS client is closed',
          uri: uri);
    }
  }

  Future<void> _cancel(String id) async {
    try {
      await _channel
          .invokeMethod<void>('cancelPinnedHttpsRequest', {'requestId': id});
    } on PlatformException {
      // Engine shutdown can remove the bridge; native teardown also cancels calls.
    } on MissingPluginException {
      // No native request exists when the plugin is unavailable.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final id in _pending.toList()) {
      unawaited(_cancel(id));
    }
    super.close();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _ensureOpen(request.url);
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.unsupportedPlatform,
        message: 'Pinned Local API HTTPS currently requires Android',
        uri: request.url,
      );
    }
    if (request.url.scheme != 'https' || request.url.userInfo.isNotEmpty) {
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.invalidRequest,
        message: 'Pinned Local API requests require an HTTPS origin',
        uri: request.url,
      );
    }
    final bodyBytes = await request.finalize().toBytes();
    if (bodyBytes.length > _maxBodyBytes) {
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.invalidRequest,
        message: 'Local API request body is too large',
        uri: request.url,
      );
    }
    _ensureOpen(request.url);
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextRequest++}';
    _pending.add(requestId);
    Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>(
        'pinnedHttpsRequest',
        {
          'protocolVersion': _protocolVersion,
          'requestId': requestId,
          'url': request.url.toString(),
          'method': request.method,
          if (addressHints[request.url.host] != null)
            'connectionAddress': addressHints[request.url.host],
          'headers': request.headers,
          'bodyBase64': base64Encode(bodyBytes),
          if (tlsSpkiFingerprint != null)
            'tlsSpkiFingerprint': tlsSpkiFingerprint,
          if (ownerRootCertificate != null)
            'ownerRootCertificate': ownerRootCertificate,
        },
      ).timeout(requestTimeout, onTimeout: () {
        unawaited(_cancel(requestId));
        throw PinnedHttpException(
            kind: PinnedHttpFailureKind.timeout,
            message: 'Pinned HTTPS request deadline exceeded',
            uri: request.url);
      });
      _ensureOpen(request.url);
    } on PlatformException catch (error) {
      throw PinnedHttpException.fromPlatform(error, uri: request.url);
    } on MissingPluginException catch (error) {
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.platform,
        message: error.message ?? 'Pinned HTTPS platform bridge is unavailable',
        uri: request.url,
        platformCode: 'MISSING_PLUGIN',
      );
    } finally {
      _pending.remove(requestId);
    }
    if (result == null ||
        result['protocolVersion'] != _protocolVersion ||
        result['statusCode'] is! int ||
        result['bodyBase64'] is! String) {
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.platform,
        message: 'Platform returned an invalid pinned HTTPS response',
        uri: request.url,
        platformCode: 'INVALID_PLATFORM_RESPONSE',
      );
    }
    final rawHeaders = result['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }
    late final List<int> responseBody;
    try {
      responseBody = base64Decode(result['bodyBase64'] as String);
    } on FormatException {
      throw PinnedHttpException(
        kind: PinnedHttpFailureKind.platform,
        message: 'Platform returned an invalid pinned HTTPS response body',
        uri: request.url,
        platformCode: 'INVALID_PLATFORM_RESPONSE_BODY',
      );
    }
    return http.StreamedResponse(
      Stream.value(responseBody),
      result['statusCode'] as int,
      headers: headers,
      request: request,
    );
  }
}
