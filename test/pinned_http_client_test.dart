import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('live.eidolon.mobile/test-pinned-https');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('carries every unary Local API method through one transport contract',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'protocolVersion': 1,
        'statusCode': 200,
        'headers': <String, String>{'content-type': 'application/json'},
        'bodyBase64': base64Encode(utf8.encode('{}')),
      };
    });
    final client = PlatformPinnedHttpClient(
      tlsSpkiFingerprint: 'sha256:${'a' * 43}',
      channel: channel,
    );
    final uri = Uri.parse('https://192.0.2.1/api/local/v1/resource');

    await client.get(uri);
    await client.post(uri, body: '{}');
    await client.put(uri, body: '{}');
    await client.delete(uri);

    expect(
      calls.map((call) => (call.arguments as Map)['method']),
      ['GET', 'POST', 'PUT', 'DELETE'],
    );
    expect(
      calls.every(
        (call) => (call.arguments as Map)['protocolVersion'] == 1,
      ),
      isTrue,
    );
  });

  test('preserves non-UTF8 request and response bytes', () async {
    final requestBytes = Uint8List.fromList([0, 127, 128, 255]);
    final responseBytes = Uint8List.fromList([255, 128, 1, 0]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(
        base64Decode((call.arguments as Map)['bodyBase64'] as String),
        requestBytes,
      );
      return <String, Object?>{
        'protocolVersion': 1,
        'statusCode': 200,
        'headers': <String, String>{},
        'bodyBase64': base64Encode(responseBytes),
      };
    });
    final client = PlatformPinnedHttpClient(
      tlsSpkiFingerprint: 'sha256:${'a' * 43}',
      channel: channel,
    );
    final request = http.Request(
      'PUT',
      Uri.parse('https://192.0.2.1/api/local/v1/resource'),
    )..bodyBytes = requestBytes;

    final response = await client.send(request);

    expect(await response.stream.toBytes(), responseBytes);
  });

  test('maps native failures to stable transport categories', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'PINNED_HTTPS_TIMEOUT',
        message: 'Read timed out',
      );
    });
    final client = PlatformPinnedHttpClient(
      tlsSpkiFingerprint: 'sha256:${'a' * 43}',
      channel: channel,
    );

    await expectLater(
      client.get(Uri.parse('https://192.0.2.1/api/local/v1/host')),
      throwsA(
        isA<PinnedHttpException>()
            .having(
                (error) => error.kind, 'kind', PinnedHttpFailureKind.timeout)
            .having(
              (error) => error.platformCode,
              'platformCode',
              'PINNED_HTTPS_TIMEOUT',
            ),
      ),
    );
  });

  test('rejects malformed platform responses as platform contract failures',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return <String, Object?>{
        'protocolVersion': 1,
        'statusCode': 200,
        'bodyBase64': 'not-base64%%',
      };
    });
    final client = PlatformPinnedHttpClient(
      tlsSpkiFingerprint: 'sha256:${'a' * 43}',
      channel: channel,
    );

    await expectLater(
      client.get(Uri.parse('https://192.0.2.1/api/local/v1/host')),
      throwsA(
        isA<PinnedHttpException>().having(
          (error) => error.platformCode,
          'platformCode',
          'INVALID_PLATFORM_RESPONSE_BODY',
        ),
      ),
    );
  });
}
