import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_system_page.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';

import 'support/setup_fixtures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HostService _service({
  String serviceId = 'eidolon-hub',
  int revision = 4,
  HostServiceRuntimeState state = HostServiceRuntimeState.ready,
}) =>
    HostService(
      serviceId: serviceId,
      required: true,
      enabled: true,
      revision: revision,
      runtimeState: state,
      detail: null,
      observedAt: DateTime.utc(2026, 8, 11),
    );

ManagedHost _host() => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: '客厅主机',
      claimedAt: DateTime.utc(2026, 8, 5),
    );

HostProductConnection _connection() => HostProductConnection(
      endpoint: const LocalApiEndpoint(
        instanceName: 'eidolon-local-api',
        baseUrl: 'https://192.168.1.26:9002',
        ipAddress: '192.168.1.26',
        contractVersion: '1',
      ),
      overview: HostOverview.fromJson({
        'contract_version': '1',
        'status': 'running',
        'mode': 'production',
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
          'updated_at': '2026-08-11T00:00:00Z',
        },
      }),
      controllerId: 'ectrl-0123456789abcdefabcd',
      ownerId: 'owner-1',
      sessionExpiresAt: DateTime.utc(2026, 8, 11, 1),
    );

Future<void> _pumpSystemPage(
  WidgetTester tester, {
  required HostServiceLister listServices,
  HostServiceChanger? changeService,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: HostSystemPage(
        host: _host(),
        connection: _connection(),
        listServices: listServices,
        changeService: changeService,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the Owner sees Host services and can restart one',
      (tester) async {
    var revision = 4;
    final calls = <(String, String, int)>[];

    await _pumpSystemPage(
      tester,
      listServices: () async => HostServiceInventory(
        services: [_service(revision: revision)],
      ),
      changeService: ({
        required String serviceId,
        required String operation,
        required int expectedRevision,
      }) async {
        calls.add((serviceId, operation, expectedRevision));
        revision = expectedRevision + 1;
        return HostServiceChange(
          serviceId: serviceId,
          operation: operation,
          enabled: true,
          revision: revision,
        );
      },
    );

    expect(find.text('主机服务'), findsOneWidget);
    expect(find.text('eidolon-hub'), findsOneWidget);

    await tester.tap(find.text('重启'));
    await tester.pumpAndSettle();

    // The revision on screen is what gets sent, not a fresh read.
    expect(calls, [('eidolon-hub', 'restart', 4)]);
  });

  testWidgets('a Host that reports no services says so instead of failing',
      (tester) async {
    await _pumpSystemPage(
      tester,
      listServices: () async => const HostServiceInventory(services: []),
    );

    expect(find.textContaining('没有报告任何服务'), findsOneWidget);
  });

  testWidgets('an unreachable service list stays recoverable', (tester) async {
    var attempts = 0;
    await _pumpSystemPage(
      tester,
      listServices: () async {
        attempts += 1;
        if (attempts == 1) throw Exception('主机服务不可达');
        return HostServiceInventory(services: [_service()]);
      },
    );

    expect(find.textContaining('主机服务不可达'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('eidolon-hub'), findsOneWidget);
  });

  testWidgets('a read-only session shows state without a restart control',
      (tester) async {
    await _pumpSystemPage(
      tester,
      listServices: () async => HostServiceInventory(
        services: [_service(state: HostServiceRuntimeState.failed)],
      ),
    );

    expect(find.text('失败'), findsOneWidget);
    expect(find.text('重启'), findsNothing);
  });
}
