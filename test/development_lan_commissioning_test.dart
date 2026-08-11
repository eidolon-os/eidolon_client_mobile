import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/development_lan_commissioning.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/setup_fixtures.dart';

const _controllerId = 'ectrl-0123456789abcdefabcd';

class _Discovery implements LocalApiDiscovery {
  const _Discovery(this.endpoints);

  final List<LocalApiEndpoint> endpoints;

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
  Future<String> signChallenge(Map<String, dynamic> challenge) =>
      throw UnimplementedError();
}

LocalApiEndpoint _localApi(String ip) => LocalApiEndpoint(
      instanceName: 'Eidolon Local API',
      baseUrl: 'https://$ip:9002',
      ipAddress: ip,
      contractVersion: '1',
    );

void main() {
  test(
      'discovers a signed development endpoint and claims through pinned HTTPS',
      () async {
    String? pinnedFingerprint;
    http.Request? claimRequest;
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery([_localApi('192.168.1.25')]),
      controllerKeys: _ControllerKeys(),
      endpointFetcher: (_) async => jsonEncode(validCommissioningEndpoint),
      pinnedClientFactory: (fingerprint) {
        pinnedFingerprint = fingerprint;
        return MockClient((request) async {
          claimRequest = request;
          return http.Response(
            jsonEncode({
              'contract_version': '1',
              'operation': 'local.development-lan-commissioning-claim',
              'host_id': validHostId,
              'controller': {'controller_id': _controllerId},
              'state': {
                'claim_state': 'claimed',
                'network_state': 'connected',
              },
            }),
            200,
          );
        });
      },
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );

    final hosts = await service.discover();
    expect(hosts, hasLength(1));
    expect(hosts.single.endpoint.hostId, validHostId);

    final claimed = await service.claim(
      hosts.single,
      setupCode: '12345678',
      controllerName: 'My Pad',
    );

    expect(
      pinnedFingerprint,
      validCommissioningEndpoint['tls_spki_fingerprint'],
    );
    expect(
      claimRequest?.url.path,
      '/api/local/v1/development/commissioning/claim',
    );
    final payload = jsonDecode(claimRequest!.body) as Map<String, dynamic>;
    expect(payload['commissioning_id'], '123e4567-e89b-42d3-a456-426614174000');
    expect(payload['setup_code'], '12345678');
    expect((payload['controller'] as Map)['controller_id'], _controllerId);
    expect(claimed.hostId, validHostId);
    expect(claimed.controllerId, _controllerId);
    expect(
      claimed.tlsSpkiFingerprint,
      validCommissioningEndpoint['tls_spki_fingerprint'],
    );
  });

  test('ignores unsigned, production and expired LAN candidates', () async {
    final expired = Map<String, dynamic>.from(validCommissioningEndpoint)
      ..['setup_session'] = {
        'commissioning_id': '123e4567-e89b-42d3-a456-426614174000',
        'expires_at': '2026-08-05T00:00:00Z',
      };
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery([
        _localApi('192.168.1.25'),
        _localApi('192.168.1.26'),
        _localApi('192.168.1.27'),
      ]),
      endpointFetcher: (baseUrl) async => switch (baseUrl) {
        'https://192.168.1.25:9002' => '{invalid',
        'https://192.168.1.26:9002' => jsonEncode({
            ...validCommissioningEndpoint,
            'setup_session': null,
          }),
        _ => jsonEncode(expired),
      },
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );

    expect(await service.discover(), isEmpty);
  });

  test('rejects invalid code before creating a pinned client', () async {
    var clients = 0;
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery([_localApi('192.168.1.25')]),
      endpointFetcher: (_) async => jsonEncode(validCommissioningEndpoint),
      pinnedClientFactory: (_) {
        clients += 1;
        return MockClient((_) async => http.Response('{}', 500));
      },
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );
    final host = (await service.discover()).single;

    await expectLater(
      service.claim(host, setupCode: '12345', controllerName: 'Pad'),
      throwsA(
        isA<CommissioningRequestException>().having(
          (error) => error.code,
          'code',
          'invalid_setup_code',
        ),
      ),
    );
    expect(clients, 0);
  });
}
