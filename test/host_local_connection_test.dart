import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_local_connection_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/setup_fixtures.dart';

const _tlsFingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const _controllerId = 'ectrl-0123456789abcdefabcd';

class _FakeDiscovery implements LocalApiDiscovery {
  @override
  Future<List<LocalApiEndpoint>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      const [
        LocalApiEndpoint(
          instanceName: 'Eidolon Local API on eidolon-pi5',
          baseUrl: 'https://192.168.1.26:9002',
          ipAddress: '192.168.1.26',
          contractVersion: '1',
        ),
      ];
}

class _FakeControllerKeys implements ControllerKeyBridge {
  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: _controllerId,
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async =>
      'valid-controller-signature';
}

class _LegacyHostTransport implements CommissioningTransport {
  int scans = 0;
  int opens = 0;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    scans += 1;
    return const [
      NearbyEidolonHost(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'Eidolon-4c0285',
        hostMarker: '4c0285',
        rssi: -40,
      ),
    ];
  }

  @override
  Future<String> open({
    required String address,
    required String serviceUuid,
  }) async {
    opens += 1;
    return jsonEncode(validCommissioningEndpoint);
  }

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async =>
      throw StateError('Trust refresh must not open a BLE TLS session');

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async =>
      throw StateError('Trust refresh must not mutate Bootstrap state');

  @override
  Future<void> close() async {}
}

ManagedHost _host({String? tlsSpkiFingerprint}) => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: _controllerId,
      displayName: 'Eidolon-4c0285',
      claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
      tlsSpkiFingerprint: tlsSpkiFingerprint,
    );

Map<String, dynamic> _hostOverview({String hostId = validHostId}) => {
      'contract_version': '1',
      'status': 'running',
      'mode': 'development',
      'descriptor': {
        'contract_version': '1',
        'host_id': hostId,
        'host_public_key': validHostPublicKey,
        'host_public_key_fingerprint': validHostPublicKeyFingerprint,
        'ble_service_uuid': validBleServiceUuid,
      },
      'state': {
        'reset_epoch': 2,
        'claim_state': 'claimed',
        'network_state': 'connected',
        'workspace_state': 'absent',
        'recovery_state': 'normal',
        'updated_at': '2026-08-06T08:00:00Z',
      },
    };

LocalApiClient _clientFor(Map<String, dynamic> overview) => LocalApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/local/v1/host') {
          return http.Response(jsonEncode(overview), 200);
        }
        if (request.url.path == '/api/local/v1/auth/challenges') {
          return http.Response(
            jsonEncode({
              'contract_version': '1',
              'purpose': 'eidolon-controller-local-auth-v1',
              'controller_id': _controllerId,
              'challenge': validHostChallenge,
              'reset_epoch': 2,
            }),
            200,
          );
        }
        if (request.url.path == '/api/local/v1/auth/sessions') {
          return http.Response(
            jsonEncode({
              'contract_version': '1',
              'token_type': 'Bearer',
              'access_token': validHostChallenge,
              'expires_at': '2026-08-06T09:00:00Z',
              'controller': {
                'contract_version': '1',
                'controller_id': _controllerId,
                'role': 'host_admin',
                'display_name': 'Test tablet',
                'platform': 'android',
                'reset_epoch': 2,
              },
            }),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );

void main() {
  testWidgets(
      'legacy claimed Host refreshes only TLS trust over BLE then authenticates on LAN',
      (tester) async {
    final transport = _LegacyHostTransport();
    ManagedHost? updated;
    String? pinnedFingerprint;

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(),
          transport: transport,
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (fingerprint) {
            pinnedFingerprint = fingerprint;
            return _clientFor(_hostOverview());
          },
          onHostUpdated: (host) async => updated = host,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(transport.scans, 1);
    expect(transport.opens, 1);
    expect(updated?.tlsSpkiFingerprint, _tlsFingerprint);
    expect(pinnedFingerprint, _tlsFingerprint);
    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.text('已安全连接'), findsOneWidget);
    expect(find.text('Host IP：192.168.1.26'), findsOneWidget);
    expect(find.textContaining(_controllerId), findsOneWidget);
  });

  testWidgets('LAN candidate with another Host identity is rejected',
      (tester) async {
    final transport = _LegacyHostTransport();
    const otherHostId = 'ehost-0123456789abcdefabcd';

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: transport,
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) =>
              _clientFor(_hostOverview(hostId: otherHostId)),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(transport.scans, 0);
    expect(find.byKey(const Key('local-connection-complete')), findsNothing);
    expect(find.byKey(const Key('local-connection-error')), findsOneWidget);
    expect(find.textContaining('另一台 Host'), findsOneWidget);
  });
}
