import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class PlatformPinnedHttpClient extends http.BaseClient {
  PlatformPinnedHttpClient({
    required this.tlsSpkiFingerprint,
    MethodChannel? channel,
  }) : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final String tlsSpkiFingerprint;
  final MethodChannel _channel;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'UNSUPPORTED_PLATFORM',
        message: 'Pinned Local API HTTPS currently requires Android',
      );
    }
    if (request.url.scheme != 'https' || request.url.userInfo.isNotEmpty) {
      throw const FormatException('Pinned Local API requests require HTTPS');
    }
    final bodyBytes = await request.finalize().toBytes();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'pinnedHttpsRequest',
      {
        'url': request.url.toString(),
        'method': request.method,
        'headers': request.headers,
        'body': utf8.decode(bodyBytes),
        'tlsSpkiFingerprint': tlsSpkiFingerprint,
      },
    );
    if (result == null ||
        result['statusCode'] is! int ||
        result['body'] is! String) {
      throw const FormatException(
          'Platform returned an invalid HTTPS response');
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
    return http.StreamedResponse(
      Stream.value(utf8.encode(result['body'] as String)),
      result['statusCode'] as int,
      headers: headers,
      request: request,
    );
  }
}
