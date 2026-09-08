import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/local_api_fixtures.dart';

import 'support/setup_fixtures.dart';

const _controllerId = 'ectrl-0123456789abcdefabcd';
const _tlsFingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';

class _Discovery implements LocalApiDiscovery {
  _Discovery(this.endpoints);

  List<LocalApiEndpoint> endpoints;

  @override
  Future<LocalApiSurvey> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      announcedSurvey(endpoints);
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
  test('reports the failure that decided the outcome, not the last one tried',
      () async {
    // A real report from a phone: 「无法连接到 Hub / 请检查局域网连接」 with
    // `Unable to resolve host "eidolon-pi5.local"` in the technical details,
    // while the Host was up and the management screens were talking to it. The
    // resolution failure belonged to an unrelated candidate; it surfaced only
    // because every failure overwrote the same variable and it happened to be
    // tried last. Whoever read that bug report was sent after the wrong thing.
    //
    // A Host that answered and refused decided something. A candidate nothing
    // answered at decided nothing.
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
              // Answered, and its identity was refused.
              ? MockClient(
                  (_) async => throw PinnedHttpException(
                    kind: PinnedHttpFailureKind.secureChannel,
                    message: 'pin mismatch',
                  ),
                )
              // Silence, tried afterwards.
              : MockClient(
                  (_) async => throw PinnedHttpException(
                    kind: PinnedHttpFailureKind.unreachable,
                    message: 'Unable to resolve host "eidolon-pi5.local"',
                  ),
                ),
        );
      },
    );
    addTearDown(session.close);

    await expectLater(
      session.connect(),
      throwsA(
        isA<PinnedHttpException>().having(
          (error) => error.kind,
          'kind',
          PinnedHttpFailureKind.secureChannel,
        ),
      ),
    );
    expect(clients, 2, reason: 'both candidates are still tried');
  });

  test('when nothing answered anywhere, silence is the answer', () async {
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery([_endpoint('192.168.1.20')]),
      clientFactory: (_) => LocalApiClient(
        httpClient: MockClient(
          (_) async => throw PinnedHttpException(
            kind: PinnedHttpFailureKind.unreachable,
            message: 'no route',
          ),
        ),
      ),
    );
    addTearDown(session.close);

    await expectLater(
      session.connect(),
      throwsA(isA<PinnedHttpException>()),
    );
  });

  test('when several addresses were silent, no one of them is the account',
      () async {
    // The single-candidate case above is entitled to name its failure: the
    // address it quotes is the only one that was tried. With several in play —
    // a multi-homed Host, or the subnet sweep turning up more than one
    // answering address — `silentFailure` held whichever candidate happened to
    // be tried last, and that one's exception was thrown verbatim. Nothing
    // chose it. It was last.
    //
    // So the person was shown one address's failure as though it were the
    // whole story, and told it in the confident, specific voice reserved for
    // things that are known. What is actually known is broader and less
    // flattering: nothing on this network answered at all. That sentence is
    // already written a few lines below the throw.
    //
    // The two candidates fail in deliberately different ways, because
    // `failureSentence` renders timeout and unreachable as different
    // sentences. If either one leaks through, this test sees a
    // PinnedHttpException instead of the honest LocalApiRequestException.
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
              ? MockClient(
                  (_) async => throw PinnedHttpException(
                    kind: PinnedHttpFailureKind.timeout,
                    message: '主机没有在预期时间内回应',
                  ),
                )
              : MockClient(
                  (_) async => throw PinnedHttpException(
                    kind: PinnedHttpFailureKind.unreachable,
                    message: 'no route to 192.168.1.26',
                  ),
                ),
        );
      },
    );
    addTearDown(session.close);

    await expectLater(
      session.connect(),
      throwsA(
        isA<LocalApiRequestException>().having(
          (error) => error.message,
          'message',
          contains('局域网里没有任何设备应答这台主机的 Local API'),
        ),
      ),
    );
    expect(clients, 2, reason: 'both candidates are still tried');
  });

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

  test('a Host address that never answers does not hold up the one that does',
      () async {
    // The board on Wi-Fi and a wired link at once. The wired address is first
    // in the list and only a laptop on that cable can reach it; the phone is on
    // the Wi-Fi. Tried in order this cost the full client timeout before the
    // working address was reached — and no ordering fixes it, because neither
    // side knows where the other is. So they are raced (RFC 8305).
    final unreachable = Completer<http.Response>();
    addTearDown(() {
      if (!unreachable.isCompleted) {
        unreachable.complete(http.Response('', 200));
      }
    });
    var clients = 0;
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery([
        _endpoint('10.42.0.2'),
        _endpoint('192.168.1.33'),
      ]),
      clientFactory: (_) {
        clients += 1;
        return LocalApiClient(
          httpClient: clients == 1
              ? MockClient((_) => unreachable.future)
              : _workingClient(),
        );
      },
    );
    addTearDown(session.close);

    final started = DateTime.now();
    await session.connect();
    final spent = DateTime.now().difference(started);

    expect(session.connection?.endpoint.ipAddress, '192.168.1.33');
    // One attempt delay, not one client timeout. Generous against a slow CI
    // machine and still an order of magnitude under the 8s it replaces.
    expect(spent, lessThan(const Duration(seconds: 3)));
    expect(clients, 2);
  });

  test('the first Host address that answers is the only one authenticated on',
      () async {
    // Racing the read is free: a GET of the overview is identical at every
    // address of one Host. Racing the authentication would not be — it would
    // mint a controller session per address.
    final sessionsMinted = <String>[];
    final session = HostProductSession(
      host: _host(),
      transport: _NoopTransport(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery([
        _endpoint('192.168.1.33'),
        _endpoint('10.42.0.2'),
      ]),
      clientFactory: (_) => LocalApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/local/v1/auth/sessions') {
            sessionsMinted.add(request.url.host);
          }
          return switch (request.url.path) {
            '/api/local/v1/host' =>
              http.Response(jsonEncode(_overview()), 200),
            '/api/local/v1/auth/challenges' => _challenge(),
            '/api/local/v1/auth/sessions' => _session(),
            '/api/local/v1/setup/workspace' => _workspace(),
            _ => http.Response('', 404),
          };
        }),
      ),
    );
    addTearDown(session.close);

    await session.connect();

    expect(sessionsMinted, ['192.168.1.33']);
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
