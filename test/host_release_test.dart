import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_product_controller.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/network_changes.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_identity_summary.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/host_session_fixtures.dart';

class _Network implements NetworkChanges {
  final events = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<void> close() => events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the detail page reads the release on each connection and keeps none',
      () async {
    // Null stands for a Host from before the release read.
    String? answering = 'rk3588-home-hil-20260930-1';
    final controller = HostProductController(
      host: hostFixture(lastKnownBaseUrl: 'https://192.168.1.26:9002'),
      onHostUpdated: (_) async {},
      transport: NoopTransport(),
      controllerKeys: FakeControllerKeys(),
      networkChanges: _Network(),
      localApiClientFactory: (_) =>
          LocalApiClient(httpClient: MockClient(hostSessionResponse)),
      managementClientFactory: (_) =>
          ManagementClient(httpClient: MockClient((request) async {
        if (request.url.path != ManagementV1.hostReleasePath ||
            answering == null) {
          return http.Response('{}', 404);
        }
        return http.Response(
            jsonEncode({
              'operation': 'host.release',
              'contract_version': '1',
              'release_id': answering,
            }),
            200,
            headers: {'content-type': 'application/json'});
      })),
    );
    addTearDown(controller.dispose);

    await controller.connect(allowBle: false);
    expect(controller.connection, isNotNull);
    expect(controller.release?.releaseId, 'rk3588-home-hil-20260930-1');

    answering = null;
    await controller.connect(allowBle: false);
    expect(controller.connection, isNotNull,
        reason: 'a Host that cannot name its release is still connected');
    expect(controller.release, isNull,
        reason: 'the previous connection\'s answer is not this one\'s');
  });

  testWidgets('the compact summary says which release, or that there is none',
      (tester) async {
    Future<void> show(HostReleaseView? release) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HostIdentitySummary(
                host: hostFixture(),
                compact: true,
                currentAddress: '192.168.1.26',
                status: '已安全连接',
                release: release,
              ),
            ),
          ),
        );

    await show(const HostReleaseView(releaseId: 'rk3588-home-hil-20260930-1'));
    expect(find.text('Release 版本：rk3588-home-hil-20260930-1'), findsOneWidget);

    await show(const HostReleaseView());
    expect(find.text('Release 版本：无（源码运行）'), findsOneWidget);

    await show(null);
    expect(find.textContaining('Release 版本'), findsNothing);
  });
}
