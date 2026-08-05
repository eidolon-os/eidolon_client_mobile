import 'dart:convert';

import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
    Uri? requested;
    final client = LocalApiClient(
      httpClient: MockClient((request) async {
        requested = request.url;
        return http.Response(
          jsonEncode(_hostOverview),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final host = await client.fetchHost('http://eidolon.local:9002');

    expect(requested, Uri.parse('http://eidolon.local:9002/api/local/v1/host'));
    expect(host.descriptor.hostId, 'ehost-0123456789abcdefabcd');
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
    final client = LocalApiClient(
      httpClient: MockClient(
        (_) async => http.Response(jsonEncode(_hostOverview), 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: HostSetupPage(localApiClient: client)),
    );

    await tester.enterText(
      find.byKey(const Key('local-api-address')),
      'http://eidolon.local:9002',
    );
    await tester.tap(find.byKey(const Key('connect-eidolon-host')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('host-overview')), findsOneWidget);
    expect(find.text('Bootstrap 正在运行'), findsOneWidget);
    expect(find.text('ehost-0123456789abcdefabcd'), findsOneWidget);
    expect(find.text('未配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
