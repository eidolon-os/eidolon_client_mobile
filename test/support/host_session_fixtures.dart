import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:http/http.dart' as http;

import 'setup_fixtures.dart';

const controllerIdFixture = 'ectrl-0123456789abcdefabcd';
const tlsFingerprintFixture =
    'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';

ManagedHost hostFixture({String? lastKnownBaseUrl}) => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: controllerIdFixture,
      displayName: 'Eidolon',
      claimedAt: DateTime.utc(2026, 8, 9),
      tlsSpkiFingerprint: tlsFingerprintFixture,
      lastKnownBaseUrl: lastKnownBaseUrl,
    );

class FakeControllerKeys implements ControllerKeyBridge {
  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: 'ectrl-0123456789abcdefabcd',
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async =>
      'valid-signature';
}

class NoopTransport implements CommissioningTransport {
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

Map<String, dynamic> overviewBody({int resetEpoch = 2}) => {
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
        'reset_epoch': resetEpoch,
        'claim_state': 'claimed',
        'network_state': 'connected',
        'workspace_state': 'ready',
        'recovery_state': 'normal',
        'updated_at': '2026-08-09T08:00:00Z',
      },
    };

Map<String, dynamic> workspaceBody() => {
      'contract_version': '1',
      'operation_id': '32c421a3-e0df-40f9-8f75-68745ae39d81',
      'state': 'absent',
      'owner': null,
      'workspace': null,
    };

/// A Host that answers everything a session needs, wherever it is asked.
Future<http.Response> hostSessionResponse(http.Request request) async =>
    switch (request.url.path) {
      '/api/local/v1/host' =>
        http.Response(jsonEncode(overviewBody()), 200),
      '/api/local/v1/auth/challenges' => http.Response(
          jsonEncode({
            'contract_version': '1',
            'purpose': 'eidolon-controller-local-auth-v1',
            'controller_id': controllerIdFixture,
            'challenge': validHostChallenge,
            'reset_epoch': 2,
          }),
          200,
        ),
      '/api/local/v1/auth/sessions' => http.Response(
          jsonEncode({
            'contract_version': '1',
            'token_type': 'Bearer',
            'access_token': validHostChallenge,
            'expires_at': '2030-08-09T09:00:00Z',
            'controller': {
              'contract_version': '1',
              'controller_id': controllerIdFixture,
              'role': 'host_admin',
              'display_name': 'Tablet',
              'platform': 'android',
              'reset_epoch': 2,
              'owner_id': 'owner-primary',
            },
          }),
          200,
        ),
      '/api/local/v1/setup/workspace' =>
        http.Response(jsonEncode(workspaceBody()), 200),
      _ => http.Response('', 404),
    };
