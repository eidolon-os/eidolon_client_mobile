import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/setup_fixtures.dart';

const _controllerId = 'ectrl-0123456789abcdefabcd';
const _tlsFingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';

class _Discovery implements LocalApiDiscovery {
  _Discovery(this.endpoints);

  List<LocalApiEndpoint> endpoints;

  @override
  Future<List<LocalApiEndpoint>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      endpoints;
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

LocalApiEndpoint _endpoint(String ip) => LocalApiEndpoint(
      instanceName: 'Eidolon Local API on $ip',
      baseUrl: 'https://$ip:9002',
      ipAddress: ip,
      contractVersion: '1',
    );

Map<String, dynamic> _overview({int resetEpoch = 2}) => {
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

http.Response _challenge() => http.Response(
      jsonEncode({
        'contract_version': '1',
        'purpose': 'eidolon-controller-local-auth-v1',
        'controller_id': _controllerId,
        'challenge': validHostChallenge,
        'reset_epoch': 2,
      }),
      200,
    );

http.Response _session() => http.Response(
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
      200,
    );

http.Response _workspace() => http.Response(
      jsonEncode({
        'contract_version': '1',
        'operation_id': '32c421a3-e0df-40f9-8f75-68745ae39d81',
        'state': 'absent',
        'owner': null,
        'workspace': null,
      }),
      200,
    );

MockClient _workingClient({int overviewResetEpoch = 2}) =>
    MockClient((request) async {
      return switch (request.url.path) {
        '/api/local/v1/host' => http.Response(
            jsonEncode(_overview(resetEpoch: overviewResetEpoch)), 200),
        '/api/local/v1/auth/challenges' => _challenge(),
        '/api/local/v1/auth/sessions' => _session(),
        '/api/local/v1/setup/workspace' => _workspace(),
        _ => http.Response('', 404),
      };
    });

void main() {
  test('tries the next discovered endpoint without weakening Host validation',
      () async {
    var clients = 0;
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery([
        _endpoint('192.168.1.20'),
        _endpoint('192.168.1.26'),
      ]),
      clientFactory: (_) {
        clients += 1;
        return LocalApiClient(
          httpClient: clients == 1
              ? MockClient((_) async => http.Response('', 503))
              : _workingClient(),
        );
      },
    );
    addTearDown(session.close);

    await session.connect();

    expect(clients, 2);
    expect(session.connection?.endpoint.ipAddress, '192.168.1.26');
  });

  test('reconnect replaces a stale Host IP with the newly discovered address',
      () async {
    final discovery = _Discovery([_endpoint('192.168.1.26')]);
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: discovery,
      clientFactory: (_) => LocalApiClient(httpClient: _workingClient()),
    );
    addTearDown(session.close);

    await session.connect();
    discovery.endpoints = [_endpoint('192.168.100.15')];
    await session.connect();

    expect(session.connection?.endpoint.ipAddress, '192.168.100.15');
  });

  test('rejects a Controller session from another Reset epoch', () async {
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery([_endpoint('192.168.1.26')]),
      clientFactory: (_) => LocalApiClient(
        httpClient: _workingClient(overviewResetEpoch: 3),
      ),
    );
    addTearDown(session.close);

    await expectLater(
      session.connect(),
      throwsA(isA<HostControllerAuthorizationException>()),
    );
    expect(session.connection, isNull);
  });

  test('reauthenticates once after a short-lived session returns 401',
      () async {
    var sessionCreates = 0;
    var workspaceCalls = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/local/v1/host':
          return http.Response(jsonEncode(_overview()), 200);
        case '/api/local/v1/auth/challenges':
          return _challenge();
        case '/api/local/v1/auth/sessions':
          sessionCreates += 1;
          return _session();
        case '/api/local/v1/setup/workspace':
          workspaceCalls += 1;
          return workspaceCalls == 1 ? http.Response('', 401) : _workspace();
        default:
          return http.Response('', 404);
      }
    });
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery([_endpoint('192.168.1.26')]),
      clientFactory: (_) => LocalApiClient(httpClient: client),
    );
    addTearDown(session.close);
    await session.connect();

    final result = await session.execute(
      (api, baseUrl, token) => api.fetchWorkspace(
        baseUrl,
        accessToken: token,
      ),
    );

    expect(result.isReady, isFalse);
    expect(sessionCreates, 2);
    expect(workspaceCalls, 2);
  });

  test('a Host already claimed stays reachable when discovery finds nothing',
      () async {
    // Same Wi-Fi, same subnet, the Host answering on its address — and not one
    // multicast announcement reaching this phone. Discovery is how a Host is
    // found; it must not also be the only way to reach one already known.
    final discovery = _Discovery([_endpoint('192.168.3.206')]);
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: discovery,
      clientFactory: (_) => LocalApiClient(httpClient: _workingClient()),
    );
    addTearDown(session.close);

    final connected = await session.connect();
    expect(connected.lastKnownBaseUrl, contains('192.168.3.206'));

    // The announcement stops arriving; the Host has not moved.
    discovery.endpoints = [];
    final again = HostProductSession(
      host: connected,
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: discovery,
      clientFactory: (_) => LocalApiClient(httpClient: _workingClient()),
    );
    addTearDown(again.close);

    await again.connect();

    expect(again.connection?.endpoint.ipAddress, '192.168.3.206');
  });

  test('a remembered address is a hint, not an authority', () async {
    // It goes through the same identity check as anything discovery turns up:
    // whatever answers there must still prove it is this Host.
    final discovery = _Discovery([]);
    final session = HostProductSession(
      host: _host().copyWith(lastKnownBaseUrl: 'https://192.168.3.206:9002'),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: discovery,
      clientFactory: (_) => LocalApiClient(
        httpClient: _workingClient(overviewResetEpoch: 3),
      ),
    );
    addTearDown(session.close);

    await expectLater(
      session.connect(),
      throwsA(isA<HostControllerAuthorizationException>()),
    );
    expect(session.connection, isNull);
  });
}
