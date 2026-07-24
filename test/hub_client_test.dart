import 'dart:convert';

import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:eidolon_client_mobile/src/services/hub_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('register declares full duplex and retries with a fresh signature',
      () async {
    final platform = _SigningPlatform();
    final requests = <http.Request>[];
    var attempt = 0;
    final client = HubClient(
      platform: platform,
      httpClientFactory: () => MockClient((request) async {
        requests.add(request);
        attempt += 1;
        if (attempt == 1) {
          throw http.ClientException(
            'Connection closed before full header was received',
            request.url,
          );
        }
        return http.Response(
          jsonEncode({
            'success': true,
            'status': 'pending_approval',
            'config': {
              'server_url': '',
              'token': '',
              'identity': 'mobile-test',
              'room_name': 'eidolon-pending',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await client.register(
      'http://192.168.100.10:8082/api/device/register',
    );

    expect(result.status, HubConfigStatus.pendingApproval);
    expect(requests, hasLength(2));
    expect(platform.signCount, 2);
    expect(
        platform.pathQueries,
        everyElement(
          '/api/device/register?agent_mode=streaming&avatar=1',
        ));
    expect(
      requests.map((request) => request.headers['x-device-interaction-mode']),
      everyElement(mobileInteractionMode),
    );
    expect(
      requests.map((request) => request.headers['connection']),
      everyElement('close'),
    );
    expect(
      requests.map((request) => request.headers['x-device-nonce']),
      ['nonce-1', 'nonce-2'],
    );
    final registration = jsonDecode(requests.last.body) as Map<String, dynamic>;
    final capabilities = registration['capabilities'] as List<dynamic>;
    expect(
      capabilities
          .cast<Map<String, dynamic>>()
          .map((capability) => capability['name']),
      containsAll(['device.identify', 'body.presence.set']),
    );
  });

  test('HTTP protocol errors are surfaced without a transport retry', () async {
    final platform = _SigningPlatform();
    var requests = 0;
    final client = HubClient(
      platform: platform,
      httpClientFactory: () => MockClient((request) async {
        requests += 1;
        return http.Response('{"detail":"replayed device nonce"}', 409);
      }),
    );

    await expectLater(
      client.register('http://hub.local/api/device/register'),
      throwsA(
        isA<HubRequestException>()
            .having((error) => error.statusCode, 'statusCode', 409),
      ),
    );
    expect(requests, 1);
    expect(platform.signCount, 1);
  });
}

class _SigningPlatform extends PlatformBridge {
  int signCount = 0;
  final List<String> pathQueries = [];

  @override
  Future<SignedRequest> signRequest({
    required String method,
    required String pathQuery,
    required String body,
  }) async {
    signCount += 1;
    pathQueries.add(pathQuery);
    return SignedRequest(
      deviceId: 'mobile-test',
      nonce: 'nonce-$signCount',
      timestamp: '1784736000',
      publicKey: 'public-key',
      signature: 'signature-$signCount',
    );
  }
}
