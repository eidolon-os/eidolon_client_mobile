import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/hub_models.dart';
import '../platform/platform_bridge.dart';

typedef HttpClientFactory = http.Client Function();

/// The mobile client always has platform AEC and supports simultaneous capture
/// and playback, so this is a hardware/client capability rather than a session
/// preference.
const mobileInteractionMode = 'full_duplex';

class HubClient {
  HubClient({
    PlatformBridge? platform,
    HttpClientFactory? httpClientFactory,
  })  : _platform = platform ?? const PlatformBridge(),
        _httpClientFactory = httpClientFactory ?? http.Client.new;

  final PlatformBridge _platform;
  final HttpClientFactory _httpClientFactory;

  Future<HubConfig> register(
    String registerUrl, {
    String sessionIntent = '',
  }) async {
    final uri = _registrationUri(registerUrl);
    final body = jsonEncode({
      'capabilities': [
        {
          'name': 'device.identify',
          'version': 1,
          'description': 'Identify this Eidolon mobile client',
          'input_schema': {
            'type': 'object',
            'properties': {
              'reason': {'type': 'string', 'maxLength': 128},
            },
            'additionalProperties': false,
          },
          'result_schema': {
            'type': 'object',
            'properties': {
              'played': {'type': 'boolean'},
            },
            'required': ['played'],
            'additionalProperties': false,
          },
        },
        {
          'name': 'body.presence.set',
          'version': 1,
          'description': 'Wake and animate this Eidolon mobile client',
          'input_schema': {
            'type': 'object',
            'properties': {
              'state': {
                'type': 'string',
                'enum': ['awake'],
              },
              'guard_epoch': {'type': 'integer', 'minimum': 0},
              'correlation_id': {'type': 'string', 'minLength': 1},
              'action_id': {'type': 'string', 'minLength': 1},
            },
            'required': [
              'state',
              'guard_epoch',
              'correlation_id',
              'action_id',
            ],
            'additionalProperties': false,
          },
          'result_schema': {
            'type': 'object',
            'properties': {
              'action_id': {'type': 'string'},
              'state': {
                'type': 'string',
                'enum': ['awake'],
              },
              'applied': {'type': 'boolean'},
            },
            'required': ['action_id', 'state', 'applied'],
            'additionalProperties': false,
          },
        },
      ],
      'device': {'name': 'Eidolon Mobile Demo', 'kind': 'mobile'},
      'guard': false,
      'guard_protocol_versions': <int>[],
    });
    final response = await _postWithRetry(
      uri,
      body,
      sessionIntent: sessionIntent,
    );
    if (response.statusCode != 200) {
      final detail = _errorDetail(response.body);
      throw HubRequestException(response.statusCode, detail);
    }
    return HubConfig.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }

  Future<http.Response> _postWithRetry(
    Uri uri,
    String body, {
    required String sessionIntent,
  }) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _signedPost(
          uri,
          body,
          sessionIntent: sessionIntent,
          attempt: attempt,
        );
      } on http.ClientException catch (exception) {
        if (attempt == 2) rethrow;
        // A POST may have reached the Hub even when its response was lost. The
        // next attempt must be signed again so it uses a fresh anti-replay nonce.
        debugPrint('Hub register transport retry: $exception');
      }
    }
    throw StateError('Hub register retry loop exhausted');
  }

  Future<http.Response> _signedPost(
    Uri uri,
    String body, {
    required String sessionIntent,
    required int attempt,
  }) async {
    final signed = await _platform.signRequest(
      method: 'POST',
      pathQuery: uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
      body: body,
    );
    final headers = <String, String>{
      'X-Device-ID': signed.deviceId,
      'X-Device-Nonce': signed.nonce,
      'X-Device-Timestamp': signed.timestamp,
      'X-Device-Public-Key': signed.publicKey,
      'X-Device-Signature': signed.signature,
      'X-Device-Interaction-Mode': mobileInteractionMode,
      'Device-Id': signed.deviceId,
      'Client-Id': signed.deviceId,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Connection': 'close',
      'User-Agent': 'eidolon-client-mobile/0.1.0 (Android)',
    };
    if (sessionIntent.isNotEmpty) {
      headers['X-Device-Session-Intent'] = sessionIntent;
    }

    // Registration is infrequent control-plane traffic. A one-shot client
    // avoids racing Uvicorn's 5-second keep-alive timeout with our 5-second
    // approval/binding poll and mirrors the ESP32 client's connection lifetime.
    final client = _httpClientFactory();
    try {
      debugPrint(
        'Hub register attempt=$attempt device=${signed.deviceId} '
        'interaction=$mobileInteractionMode uri=$uri',
      );
      final response = await client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 5));
      debugPrint('Hub register response status=${response.statusCode}');
      return response;
    } finally {
      client.close();
    }
  }

  Uri _registrationUri(String registerUrl) {
    final uri = Uri.parse(registerUrl);
    final query = Map<String, String>.from(uri.queryParameters)
      ..['agent_mode'] = 'streaming'
      // Request the digital-human video avatar: hub stamps ``avatar`` into the
      // voice token's participant metadata and channel runs the avatar worker.
      ..['avatar'] = '1';
    return uri.replace(queryParameters: query);
  }

  String _errorDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded['detail']?.toString() ?? body;
      }
    } catch (_) {
      // Return the raw body below.
    }
    return body;
  }

  void dispose() {}
}

class HubRequestException implements Exception {
  const HubRequestException(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  @override
  String toString() => 'Hub request failed ($statusCode): $detail';
}
