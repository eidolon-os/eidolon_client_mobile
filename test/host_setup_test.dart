import 'dart:convert';

import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
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
}
