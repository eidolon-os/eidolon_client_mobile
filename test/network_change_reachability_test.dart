import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_product_controller.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/network_changes.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/setup_fixtures.dart';

/// The phone saying its own network changed.
///
/// A stream this test drives by hand, because the real thing needs a phone to
/// be carried out of a building.
class _NetworkChanges implements NetworkChanges {
  final _controller = StreamController<void>.broadcast();
  var closed = false;

  void moved() => _controller.add(null);

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

class _CountingDiscovery implements LocalApiDiscovery {
  var rounds = 0;

  @override
  Future<List<LocalApiEndpoint>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    rounds += 1;
    return [
      LocalApiEndpoint(
        instanceName: 'Eidolon Local API',
        baseUrl: 'https://192.168.1.20:9002',
        ipAddress: '192.168.1.20',
        contractVersion: '1',
      ),
    ];
  }
}

class _ControllerKeys implements ControllerKeyBridge {
  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: _controllerId,
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async =>
      'valid-signature';
}

class _NoopTransport implements CommissioningTransport {
  @override
  Future<void> close() async {}

  @override
  Future<String> open({
    required String address,
    required String serviceUuid,
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) =>
      throw UnimplementedError();

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async =>
      const [];

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) =>
      throw UnimplementedError();
}

const _controllerId = 'ectrl-0123456789abcdefabcd';
const _tlsFingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';

ManagedHost _host() => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: _controllerId,
      displayName: 'Eidolon',
      claimedAt: DateTime.utc(2026, 8, 9),
      tlsSpkiFingerprint: _tlsFingerprint,
    );

MockClient _workingClient() => MockClient((request) async {
      return switch (request.url.path) {
        '/api/local/v1/host' => http.Response(
            jsonEncode({
              'contract_version': '1',
              'status': 'running',
              'mode': 'development',
              'descriptor': {
                'contract_version': '1',
                'host_id': validHostId,
                'host_public_key': validHostPublicKey,
                'host_public_key_fingerprint': validHostPublicKeyFingerprint,
                'ble_service_uuid': validBleServiceUuid,
              },
              'state': {
                'reset_epoch': 2,
                'claim_state': 'claimed',
                'network_state': 'connected',
                'workspace_state': 'ready',
                'recovery_state': 'normal',
                'updated_at': '2026-08-09T08:00:00Z',
              },
            }),
            200),
        '/api/local/v1/auth/challenges' => http.Response(
            jsonEncode({
              'contract_version': '1',
              'purpose': 'eidolon-controller-local-auth-v1',
              'controller_id': _controllerId,
              'challenge': validHostChallenge,
              'reset_epoch': 2,
            }),
            200),
        '/api/local/v1/auth/sessions' => http.Response(
            jsonEncode({
              'contract_version': '1',
              'token_type': 'Bearer',
              'access_token': validHostChallenge,
              'expires_at': '2030-08-09T09:00:00Z',
              'controller': {
                'contract_version': '1',
                'controller_id': _controllerId,
                'role': 'host_admin',
                'display_name': 'Tablet',
                'platform': 'android',
                'reset_epoch': 2,
                'owner_id': 'owner-primary',
              },
            }),
            200),
        '/api/local/v1/setup/workspace' => http.Response(
            jsonEncode({
              'contract_version': '1',
              'operation_id': '32c421a3-e0df-40f9-8f75-68745ae39d81',
              'state': 'absent',
              'owner': null,
              'workspace': null,
            }),
            200),
        _ => http.Response('', 404),
      };
    });

void main() {
  late _NetworkChanges network;
  late _CountingDiscovery discovery;
  late HostProductController controller;

  setUp(() {
    network = _NetworkChanges();
    discovery = _CountingDiscovery();
    controller = HostProductController(
      host: _host(),
      onHostUpdated: (_) async {},
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: discovery,
      localApiClientFactory: (_) =>
          LocalApiClient(httpClient: _workingClient()),
      networkChanges: network,
    );
  });

  test('this phone moving makes the next request find the Host again',
      () async {
    await controller.connect();
    expect(discovery.rounds, 1);

    network.moved();
    // The listener is synchronous on delivery, and delivery is a microtask.
    await Future<void>.delayed(Duration.zero);
    await controller.refreshWorkspace();

    // Two rounds, not one: the address learned on the old network was not
    // reused. Before this, invalidateLocation() had no caller at all — the
    // App waited for a request to time out before it would look again.
    expect(discovery.rounds, 2);
    expect(controller.connection, isNotNull);
  });

  test('a connection that nothing disturbed is not thrown away', () async {
    await controller.connect();
    await controller.refreshWorkspace();

    // Re-locating on every request would put a discovery round in front of
    // each tap, which is the cost this signal exists to avoid.
    expect(discovery.rounds, 1);
  });

  test('the phone stops being watched when the screen goes away', () async {
    await controller.connect();
    controller.dispose();
    await Future<void>.delayed(Duration.zero);

    // A subscription that outlives its controller would keep a disposed
    // session alive and invalidate a Host nobody is looking at.
    expect(network.closed, isTrue);
  });
}
