import 'dart:async';
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

  test('deadline cancels the native request and does not block a second client',
      () async {
    final pending = Completer<Object?>();
    final ids = <String>[];
    final cancelled = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'cancelPinnedHttpsRequest') {
        cancelled.add(args['requestId'] as String);
        pending
            .completeError(PlatformException(code: 'PINNED_HTTPS_CANCELLED'));
        return null;
      }
      ids.add(args['requestId'] as String);
      if ((args['url'] as String).contains('slow')) return pending.future;
      return {'protocolVersion': 1, 'statusCode': 200, 'bodyBase64': ''};
    });
    final slow = PlatformPinnedHttpClient(
        tlsSpkiFingerprint: 'pin',
        channel: channel,
        requestTimeout: const Duration(milliseconds: 30));
    final fast =
        PlatformPinnedHttpClient(tlsSpkiFingerprint: 'pin', channel: channel);
    final failed = expectLater(
        slow.get(Uri.parse('https://slow/')),
        throwsA(isA<PinnedHttpException>()
            .having((e) => e.kind, 'kind', PinnedHttpFailureKind.timeout)));
    expect((await fast.get(Uri.parse('https://fast/'))).statusCode, 200);
    await failed;
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, [ids.first]);
    slow.close();
    fast.close();
  });

  test('closing a client cancels only its requests and rejects future sends',
      () async {
    final pending = <String, Completer<Object?>>{};
    final cancelled = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = (call.arguments as Map)['requestId'] as String;
      if (call.method == 'cancelPinnedHttpsRequest') {
        cancelled.add(id);
        pending[id]!
            .completeError(PlatformException(code: 'PINNED_HTTPS_CANCELLED'));
        return null;
      }
      return (pending[id] = Completer<Object?>()).future;
    });
    final first =
        PlatformPinnedHttpClient(tlsSpkiFingerprint: 'pin', channel: channel);
    final second =
        PlatformPinnedHttpClient(tlsSpkiFingerprint: 'pin', channel: channel);
    final closed = expectLater(
        first.get(Uri.parse('https://first/')),
        throwsA(isA<PinnedHttpException>()
            .having((e) => e.kind, 'kind', PinnedHttpFailureKind.cancelled)));
    final reply = second.get(Uri.parse('https://second/'));
    await Future<void>.delayed(Duration.zero);
    first.close();
    first.close();
    await closed;
    expect(cancelled, [pending.keys.first]);
    pending.values.last
        .complete({'protocolVersion': 1, 'statusCode': 200, 'bodyBase64': ''});
    expect((await reply).statusCode, 200);
    await expectLater(first.get(Uri.parse('https://first/')),
        throwsA(isA<PinnedHttpException>()));
    second.close();
  });

  test(
      'Owner address hint leaves signed URL and root intact and is scoped to its hostname',
      () async {
    final calls = <Map>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      return {
        'protocolVersion': 1,
        'statusCode': 200,
        'headers': {},
        'bodyBase64': base64Encode(utf8.encode('{}'))
      };
    });
    final client = PlatformPinnedHttpClient.ownerDomain(
        ownerRootCertificate: 'owner-root',
        addressHints: {'hub.local': '192.0.2.10'},
        channel: channel);
    await client.get(Uri.parse(
        'https://hub.local:8443/api/device-control/v1/configuration:pull'));
    await client.get(Uri.parse(
        'https://remote.example/api/device-control/v1/configuration:pull'));
    expect(calls.first['url'], startsWith('https://hub.local:8443/'));
    expect(calls.first['ownerRootCertificate'], 'owner-root');
    expect(calls.first['connectionAddress'], '192.0.2.10');
    expect(calls.last.containsKey('connectionAddress'), false);
    expect(calls.every((c) => !c.containsKey('tlsSpkiFingerprint')), true);
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
