import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/development_lan_commissioning.dart';
import 'package:eidolon_client_mobile/src/features/setup/development_lan_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/local_api_fixtures.dart';
import 'support/setup_fixtures.dart';

const _controllerId = 'ectrl-0123456789abcdefabcd';

class _Discovery implements LocalApiDiscovery {
  const _Discovery(this.survey);

  final LocalApiSurvey survey;

  @override
  Future<LocalApiSurvey> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      survey;
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

/// A survey in which one source found these addresses and the others were
/// silent — the shape of every discovery before this change.
LocalApiSurvey _announced(List<String> ips) => LocalApiSurvey([
      LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.announced,
        attempted: '_eidolon-local-api._tcp',
        candidates: ips
            .map(
              (ip) => LocalApiCandidate(
                origin: LocalApiCandidateOrigin.announced,
                endpoint: _localApi(ip),
              ),
            )
            .toList(growable: false),
      ),
      const LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.hostname,
        attempted: 'eidolon-pi5.local',
      ),
      const LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.subnet,
        attempted: '192.168.1.0/24',
      ),
    ]);

/// One address per source, so a test can watch what the gate does with leads
/// of differing provenance.
LocalApiSurvey _oneFromEachSource() => LocalApiSurvey([
      LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.announced,
        attempted: '_eidolon-local-api._tcp',
        candidates: [
          LocalApiCandidate(
            origin: LocalApiCandidateOrigin.announced,
            endpoint: _localApi('192.168.1.25'),
          ),
        ],
      ),
      LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.hostname,
        attempted: 'eidolon-pi5.local',
        candidates: [
          LocalApiCandidate(
            origin: LocalApiCandidateOrigin.hostname,
            endpoint: const LocalApiEndpoint(
              instanceName: 'eidolon-pi5.local',
              baseUrl: 'https://eidolon-pi5.local:9002',
              ipAddress: '192.168.1.26',
              contractVersion: '1',
            ),
          ),
        ],
      ),
      LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.subnet,
        attempted: '192.168.1.0/24',
        candidates: [
          LocalApiCandidate(
            origin: LocalApiCandidateOrigin.subnet,
            endpoint: _localApi('192.168.1.27'),
          ),
        ],
      ),
    ]);

/// The same document with one field moved, so the Ed25519 signature over it no
/// longer verifies: an impostor answering on the Local API port.
String get _tamperedEndpoint => jsonEncode({
      ...validCommissioningEndpoint,
      'reset_epoch': 7,
    });

void main() {
  test(
      'discovers a signed development endpoint and claims through pinned HTTPS',
      () async {
    String? pinnedFingerprint;
    http.Request? claimRequest;
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery(_announced(['192.168.1.25'])),
      controllerKeys: _ControllerKeys(),
      endpointFetcher: (_) async => jsonEncode(validCommissioningEndpoint),
      pinnedClientFactory: (fingerprint) {
        pinnedFingerprint = fingerprint;
        return MockClient((request) async {
          claimRequest = request;
          return http.Response(
            jsonEncode({
              'contract_version': '1',
              'operation': 'local.lan-commissioning-claim',
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

    final discovered = await service.discover();
    expect(discovered.failure, isNull);
    expect(discovered.hosts, hasLength(1));
    expect(discovered.hosts.single.endpoint.hostId, validHostId);

    final claimed = await service.claim(
      discovered.hosts.single,
      setupCode: '12345678',
      controllerName: 'My Pad',
    );

    expect(
      pinnedFingerprint,
      validCommissioningEndpoint['tls_spki_fingerprint'],
    );
    expect(
      claimRequest?.url.path,
      '/api/local/v1/commissioning/claim',
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
      discovery: _Discovery(
        _announced(['192.168.1.25', '192.168.1.26', '192.168.1.27']),
      ),
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

    expect((await service.discover()).hosts, isEmpty);
  });

  test('rejects invalid code before creating a pinned client', () async {
    var clients = 0;
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery(_announced(['192.168.1.25'])),
      endpointFetcher: (_) async => jsonEncode(validCommissioningEndpoint),
      pinnedClientFactory: (_) {
        clients += 1;
        return MockClient((_) async => http.Response('{}', 500));
      },
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );
    final host = (await service.discover()).hosts.single;

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

  group('the verification gate', () {
    test('puts every candidate through it, whatever source produced it',
        () async {
      final fetched = <String>[];
      final service = DevelopmentLanCommissioning(
        discovery: _Discovery(_oneFromEachSource()),
        endpointFetcher: (baseUrl) async {
          fetched.add(baseUrl);
          return baseUrl == 'https://192.168.1.27:9002'
              ? jsonEncode(validCommissioningEndpoint)
              : _tamperedEndpoint;
        },
        clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
      );

      final discovered = await service.discover();

      expect(fetched, [
        'https://192.168.1.25:9002',
        'https://eidolon-pi5.local:9002',
        'https://192.168.1.27:9002',
      ]);
      expect(
        discovered.hosts.map((host) => host.localApi.baseUrl),
        ['https://192.168.1.27:9002'],
      );
      expect(
        discovered.hosts.single.candidate.origin,
        LocalApiCandidateOrigin.subnet,
      );
    });

    test('a swept address that cannot prove the Host is refused, not admitted',
        () async {
      final service = DevelopmentLanCommissioning(
        discovery: _Discovery(
          LocalApiSurvey([
            LocalApiSourceReport(
              origin: LocalApiCandidateOrigin.subnet,
              attempted: '192.168.1.0/24',
              candidates: [
                LocalApiCandidate(
                  origin: LocalApiCandidateOrigin.subnet,
                  endpoint: _localApi('192.168.1.99'),
                ),
              ],
            ),
          ]),
        ),
        endpointFetcher: (_) async => _tamperedEndpoint,
        clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
      );

      final discovered = await service.discover();

      expect(discovered.hosts, isEmpty);
      expect(discovered.rejections, hasLength(1));
      expect(
        discovered.rejections.single.candidate.origin,
        LocalApiCandidateOrigin.subnet,
      );
      final failure = discovered.failure!;
      expect(failure.code, 'host_identity_unverified');
      expect(failure.message, contains('签名'));
    });
  });

  group('why there is nothing to claim', () {
    DevelopmentLanCommissioning silent(LocalApiSurvey survey) =>
        DevelopmentLanCommissioning(
          discovery: _Discovery(survey),
          endpointFetcher: (_) async =>
              throw const CommissioningRequestException('unreachable', 'no'),
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
        );

    test('silence names every source that was tried', () async {
      final discovered = await silent(
        LocalApiSurvey([
          const LocalApiSourceReport(
            origin: LocalApiCandidateOrigin.announced,
            attempted: '_eidolon-local-api._tcp',
          ),
          const LocalApiSourceReport(
            origin: LocalApiCandidateOrigin.hostname,
            attempted: 'eidolon-pi5.local',
          ),
          const LocalApiSourceReport(
            origin: LocalApiCandidateOrigin.subnet,
            attempted: '192.168.3.0/24 共 253 个地址',
          ),
        ]),
      ).discover();

      final failure = discovered.failure!;
      expect(failure.code, 'host_not_found');
      expect(failure.message, contains('mDNS 服务浏览'));
      expect(failure.message, contains('按名解析'));
      expect(failure.message, contains('本网段探测'));
      expect(failure.message, contains('192.168.3.0/24'));
      // The Owner-side way back in is invisible on the phone unless it is said.
      expect(failure.message, contains('eidolon-ops controller-reset'));
    });

    test('an answer on another contract is not a missing Host', () async {
      final discovered = await silent(
        LocalApiSurvey([
          const LocalApiSourceReport(
            origin: LocalApiCandidateOrigin.announced,
            attempted: '_eidolon-local-api._tcp',
            incompatible: [
              IncompatibleLocalApi(
                baseUrl: 'https://192.168.3.206:9002',
                contractVersion: '9',
              ),
            ],
          ),
        ]),
      ).discover();

      final failure = discovered.failure!;
      expect(failure.code, 'local_api_incompatible');
      expect(failure.message, contains('9'));
    });

    test('a Host that does not carry this entrance says which door to use',
        () async {
      // A Host older than the release that opened this route on every Host
      // answers 404. Counting that as one more silent address is how "局域网里
      // 没有任何设备应答" came to be printed under two addresses the App had
      // just resolved and talked to.
      final service = DevelopmentLanCommissioning(
        discovery: _Discovery(_announced(['192.168.3.206'])),
        endpointFetcher: (baseUrl) async => throw DevelopmentEndpointRefused(
          baseUrl: baseUrl,
          statusCode: 404,
          detail: 'development LAN commissioning is unavailable on this Host',
        ),
        clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
      );

      final discovered = await service.discover();

      expect(
        discovered.rejections.single.refusal,
        DevelopmentLanRefusal.entranceUnavailable,
      );
      final failure = discovered.failure!;
      expect(failure.code, 'development_lan_entrance_absent');
      expect(failure.message, contains('192.168.3.206'));
      expect(failure.message, contains('development LAN commissioning'));
      expect(failure.message, contains('查找附近 Eidolon 主机'));
      expect(failure.message, contains('更新到同一版本'));
      // The old sentence was not merely unhelpful, it was false.
      expect(failure.message, isNot(contains('没有任何设备应答')));
    });

    test('a Host that errored on the probe is not reported as absent',
        () async {
      final service = DevelopmentLanCommissioning(
        discovery: _Discovery(_announced(['192.168.3.206'])),
        endpointFetcher: (baseUrl) async => throw DevelopmentEndpointRefused(
          baseUrl: baseUrl,
          statusCode: 503,
        ),
        clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
      );

      final discovered = await service.discover();

      expect(
        discovered.rejections.single.refusal,
        DevelopmentLanRefusal.endpointRefused,
      );
      final failure = discovered.failure!;
      expect(failure.code, 'development_lan_endpoint_refused');
      expect(failure.message, contains('503'));
      expect(failure.message, contains('不是找不到 Host'));
    });

    test('candidates that never answered are counted, named and quoted',
        () async {
      final discovered = await silent(
        _announced(['192.168.3.206', '192.168.3.207']),
      ).discover();

      final failure = discovered.failure!;
      // An address that was resolved and then went quiet is a different claim
      // from an empty network, and the reason it gave is the lead.
      expect(failure.code, 'host_unreachable');
      expect(failure.message, contains('2 个候选地址'));
      expect(failure.message, contains('https://192.168.3.206:9002'));
      expect(failure.message, contains('https://192.168.3.207:9002'));
      expect(failure.message, isNot(contains('没有任何设备应答')));
    });

    test('a verified Host without an open Setup session says so', () async {
      final service = DevelopmentLanCommissioning(
        discovery: _Discovery(_announced(['192.168.1.25'])),
        endpointFetcher: (_) async => signedEndpointDocument(),
        clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
      );

      final failure = (await service.discover()).failure!;
      expect(failure.code, 'setup_session_missing');
      expect(failure.message, contains('Setup'));
    });
  });

  test('a Host that refuses this phone points at the operator recovery',
      () async {
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery(_announced(['192.168.1.25'])),
      controllerKeys: _ControllerKeys(),
      endpointFetcher: (_) async => jsonEncode(validCommissioningEndpoint),
      pinnedClientFactory: (_) =>
          MockClient((_) async => http.Response('{}', 401)),
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );
    final host = (await service.discover()).hosts.single;

    await expectLater(
      service.claim(host, setupCode: '12345678', controllerName: 'Pad'),
      throwsA(
        isA<CommissioningRequestException>()
            .having((error) => error.code, 'code', 'commissioning_denied')
            .having(
              (error) => error.message,
              'message',
              contains('eidolon-ops controller-reset'),
            ),
      ),
    );
  });

  testWidgets('the setup page shows which sources were tried', (tester) async {
    final service = DevelopmentLanCommissioning(
      discovery: _Discovery(
        LocalApiSurvey([
          const LocalApiSourceReport(
            origin: LocalApiCandidateOrigin.announced,
            attempted: '_eidolon-local-api._tcp',
          ),
          const LocalApiSourceReport(
            origin: LocalApiCandidateOrigin.subnet,
            attempted: '192.168.3.0/24 共 253 个地址',
          ),
        ]),
      ),
      endpointFetcher: (_) async => throw StateError('unreachable'),
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );

    await tester.pumpWidget(
      MaterialApp(home: DevelopmentLanSetupPage(commissioning: service)),
    );
    await tester.tap(find.byKey(const Key('discover-development-lan-hosts')));
    await tester.pumpAndSettle();

    final error = tester.widget<Text>(
      find.byKey(const Key('development-lan-error')),
    );
    expect(error.data, contains('本网段探测'));
    expect(error.data, contains('eidolon-ops controller-reset'));
  });
}
