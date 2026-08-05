import 'dart:convert';

import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
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

Future<void> _useTallViewport(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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

  testWidgets('the app starts in Host Setup instead of Audio/Hub',
      (tester) async {
    await tester.pumpWidget(const EidolonMobileApp());

    expect(find.byKey(const Key('host-setup-page')), findsOneWidget);
    expect(find.text('连接你的 Eidolon 主机'), findsOneWidget);
    expect(find.text('发现并连接 Hub'), findsNothing);
  });

  testWidgets('Host Setup renders the real Local API snapshot', (tester) async {
    await _useTallViewport(tester);
    final client = LocalApiClient(
      httpClient: MockClient(
        (_) async => http.Response(jsonEncode(_hostOverview), 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSetupPage(
          localApiClient: client,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('local-api-address')),
      'http://eidolon.local:9002',
    );
    await tester.tap(find.byKey(const Key('connect-eidolon-host')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('host-overview')), findsOneWidget);
    expect(find.text('Bootstrap 可达（身份未验证）'), findsOneWidget);
    expect(find.text('ehost-0123456789abcdefabcd'), findsOneWidget);
    expect(find.text('未配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Host Setup verifies trust before matching Local API',
      (tester) async {
    await _useTallViewport(tester);
    final client = LocalApiClient(
      httpClient: MockClient(
        (request) async => request.url.path.endsWith('/proof')
            ? http.Response(jsonEncode(validHostProof), 200)
            : http.Response(jsonEncode(matchingHostOverview), 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSetupPage(
          localApiClient: client,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          hostChallengeFactory: () => validHostChallenge,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('dev-descriptor-input')),
      validDevDescriptorJson,
    );
    await tester.tap(find.byKey(const Key('verify-dev-descriptor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dev-descriptor-verified')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('local-api-address')),
      'http://eidolon.local:9002',
    );
    await tester.tap(find.byKey(const Key('connect-eidolon-host')));
    await tester.pumpAndSettle();

    expect(find.text('Bootstrap 身份已验证'), findsOneWidget);
    expect(find.text('3. 验证 Bootstrap 持有目标 Host 私钥'), findsOneWidget);
    expect(find.byKey(const Key('host-setup-error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Host Setup refuses a different Local API Host', (tester) async {
    await _useTallViewport(tester);
    final wrongOverview = Map<String, dynamic>.from(matchingHostOverview);
    final wrongHostDescriptor = Map<String, dynamic>.from(
      matchingHostOverview['descriptor']! as Map<String, dynamic>,
    )..['host_id'] = 'ehost-0123456789abcdefabcd';
    wrongOverview['descriptor'] = wrongHostDescriptor;
    final client = LocalApiClient(
      httpClient: MockClient(
        (_) async => http.Response(jsonEncode(wrongOverview), 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSetupPage(
          localApiClient: client,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          hostChallengeFactory: () => validHostChallenge,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('dev-descriptor-input')),
      validDevDescriptorJson,
    );
    await tester.tap(find.byKey(const Key('verify-dev-descriptor')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('local-api-address')),
      'http://wrong-host:9002',
    );
    await tester.tap(find.byKey(const Key('connect-eidolon-host')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('host-overview')), findsNothing);
    expect(find.textContaining('不匹配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
