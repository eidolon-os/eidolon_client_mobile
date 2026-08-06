import 'dart:convert';

import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_identity.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/setup_fixtures.dart';

const _hostOverview = <String, dynamic>{
  'contract_version': '1',
  'status': 'running',
  'mode': 'development',
  'descriptor': {
    'contract_version': '1',
    'host_id': 'ehost-0123456789abcdefabcd',
    'host_public_key': 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN1234',
    'host_public_key_fingerprint': 'sha256:0123456789abcdef',
    'ble_service_uuid': '179e2e95-b1ee-5aa5-8dcf-7519b6c7ac52',
  },
  'state': {
    'reset_epoch': 0,
    'claim_state': 'unclaimed',
    'network_state': 'unconfigured',
    'workspace_state': 'absent',
    'recovery_state': 'normal',
    'updated_at': '2026-08-05T00:00:00Z',
  },
};

class _FakeControllerKeys implements ControllerKeyBridge {
  Map<String, dynamic>? signed;

  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: 'ectrl-0123456789abcdefabcd',
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async {
    signed = Map<String, dynamic>.from(challenge);
    return 'valid_controller_signature';
  }
}

void main() {
  test('parses the Admin Local API host contract', () {
    final host = HostOverview.fromJson(_hostOverview);

    expect(host.mode, BootstrapMode.development);
    expect(host.descriptor.hostId, 'ehost-0123456789abcdefabcd');
    expect(host.state.claim, HostClaimState.unclaimed);
    expect(host.state.network, HostNetworkState.unconfigured);
  });

  test('rejects an unknown contract version instead of guessing', () {
    final payload = Map<String, dynamic>.from(_hostOverview)
      ..['contract_version'] = '2';

    expect(
      () => HostOverview.fromJson(payload),
      throwsA(isA<FormatException>()),
    );
  });

  test('LocalApiClient calls only the versioned host endpoint', () async {
    final requested = <Uri>[];
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        requested.add(request.url);
        if (request.url.path == '/api/local/v1/host/proof') {
          expect(
            jsonDecode(request.body),
            {
              'contract_version': '1',
              'challenge': validHostChallenge,
            },
          );
          return http.Response(jsonEncode(validHostProof), 200);
        }
        return http.Response(
          jsonEncode(_hostOverview),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final host = await client.fetchHost('http://eidolon.local:9002');
    final proof = await client.fetchHostProof(
      'http://eidolon.local:9002',
      validHostChallenge,
    );

    expect(requested, [
      Uri.parse('http://eidolon.local:9002/api/local/v1/host'),
      Uri.parse('http://eidolon.local:9002/api/local/v1/host/proof'),
    ]);
    expect(host.descriptor.hostId, 'ehost-0123456789abcdefabcd');
    expect(proof.challenge, validHostChallenge);
  });

  test('LocalApiClient refuses credentials and paths in a base URL', () {
    expect(
      () => LocalApiClient.parseBaseUri('http://user:pass@host:9002'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LocalApiClient.parseBaseUri('http://host:9002/api/admin'),
      throwsA(isA<FormatException>()),
    );
  });

  test('LocalApiClient creates a reset-bound Controller session', () async {
    final requested = <String>[];
    final keys = _FakeControllerKeys();
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        requested.add(request.url.path);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path == '/api/local/v1/auth/challenges') {
          expect(body, {
            'contract_version': '1',
            'controller_id': 'ectrl-0123456789abcdefabcd',
          });
          return http.Response(
            jsonEncode({
              'contract_version': '1',
              'purpose': 'eidolon-controller-local-auth-v1',
              'controller_id': 'ectrl-0123456789abcdefabcd',
              'challenge': validHostChallenge,
              'reset_epoch': 2,
            }),
            200,
          );
        }
        expect(body['signature'], 'valid_controller_signature');
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'token_type': 'Bearer',
            'access_token': validHostChallenge,
            'expires_at': '2026-08-06T01:00:00Z',
            'controller': {
              'contract_version': '1',
              'controller_id': 'ectrl-0123456789abcdefabcd',
              'role': 'host_admin',
              'display_name': 'Primary phone',
              'platform': 'android',
              'reset_epoch': 2,
            },
          }),
          200,
        );
      }),
    );

    final session = await client.authenticateController(
      'https://eidolon.local:9002',
      expectedControllerId: 'ectrl-0123456789abcdefabcd',
      controllerKeys: keys,
    );

    expect(requested, [
      '/api/local/v1/auth/challenges',
      '/api/local/v1/auth/sessions',
    ]);
    expect(keys.signed?['purpose'], 'eidolon-controller-local-auth-v1');
    expect(session.controllerId, 'ectrl-0123456789abcdefabcd');
    expect(session.resetEpoch, 2);
    expect(session.accessToken, validHostChallenge);
  });

  test('uses the BLE Host marker as the canonical generated display name', () {
    expect(defaultHostDisplayName(validHostId), 'Eidolon-4c0285');
    expect(
      normalizeHostDisplayName(validHostId, 'Eidolon 56475a'),
      'Eidolon-4c0285',
    );
    expect(
      normalizeHostDisplayName(validHostId, 'Living room Eidolon'),
      'Living room Eidolon',
    );
    expect(() => hostMarker('invalid-host'), throwsFormatException);

    final restored = ManagedHost.fromJson({
      'host_id': validHostId,
      'host_public_key': validHostPublicKey,
      'host_fingerprint': validHostPublicKeyFingerprint,
      'ble_service_uuid': validBleServiceUuid,
      'controller_id': 'ectrl-0123456789abcdefabcd',
      'display_name': 'Eidolon 56475a',
      'claimed_at': '2026-08-05T00:20:00Z',
    });
    expect(restored.displayName, 'Eidolon-4c0285');
  });

  testWidgets(
      'the app starts in the first-use Setup entry instead of Audio/Hub',
      (tester) async {
    await tester.pumpWidget(
      EidolonMobileApp(hostRegistry: InMemoryHostRegistry()),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('eidolon-welcome-page')), findsOneWidget);
    expect(find.text('设置新主机'), findsOneWidget);
    expect(find.text('发现并连接 Hub'), findsNothing);
  });

  testWidgets('managed Host exposes only implemented management actions',
      (tester) async {
    final host = ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: 'Eidolon-4c0285',
      claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
    );
    await tester.pumpWidget(
      EidolonMobileApp(hostRegistry: InMemoryHostRegistry([host])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('change-host-network')), findsOneWidget);
    expect(find.byKey(const Key('connect-local-host')), findsOneWidget);
    expect(
      find.byKey(const Key('manage-controllers-unavailable')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('controller-recovery-unavailable')),
      findsOneWidget,
    );
    expect(find.text('尚未开放'), findsNWidgets(2));
    expect(find.byType(AlertDialog), findsNothing);
  });
}
