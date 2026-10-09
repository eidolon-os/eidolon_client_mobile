import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/change_network_page.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_wizard_page.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_trust.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';
import 'support/setup_discovery_fixtures.dart';
import 'support/host_session_fixtures.dart' show hostFixture;

class _FakeControllerKeyBridge implements ControllerKeyBridge {
  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: 'ectrl-0123456789abcdefabcd',
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async =>
      'valid-controller-signature';
}

class _FakeCommissioningTransport implements CommissioningTransport {
  _FakeCommissioningTransport({
    this.currentNetworkState = 'unconfigured',
    this.currentSsid,
    this.hasGrant = false,
    this.failNetwork = false,
  });

  bool hasGrant;
  bool authenticated = false;
  bool failNetwork;
  final String currentNetworkState;
  final String? currentSsid;
  final operations = <String>[];
  bool closed = false;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async =>
      const [
        NearbyEidolonHost(
          address: 'AA:BB:CC:DD:EE:FF',
          name: 'Eidolon-4c0285',
          hostMarker: '4c0285',
          rssi: -44,
        ),
      ];

  @override
  Future<String> open({
    required String address,
    required String serviceUuid,
  }) async =>
      jsonEncode(validCommissioningEndpoint);

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async {
    expect(
      tlsSpkiFingerprint,
      validCommissioningEndpoint['tls_spki_fingerprint'],
    );
  }

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async {
    operations.add(operation);
    if (operation == 'controller.challenge' && !hasGrant) {
      throw const CommissioningRequestException(
          'controller_denied', 'No grant');
    }
    if (operation == 'claim.complete') hasGrant = true;
    if (operation == 'controller.authenticate') authenticated = true;
    if (operation == 'wifi.configure') {
      expect(authenticated, isTrue,
          reason: 'Network mutation requires key proof');
      if (failNetwork) {
        throw const CommissioningRequestException(
            'network_stage_failed', 'No Wi-Fi');
      }
    }
    return switch (operation) {
      'controller.challenge' => {
          'contract_version': '1',
          'purpose': 'eidolon-controller-ble-auth-v1',
          'controller_id': 'ectrl-0123456789abcdefabcd',
          'challenge': validHostChallenge,
          'reset_epoch': 0,
        },
      'controller.authenticate' => {
          'state': {'claim_state': 'claimed'}
        },
      'session.authenticate' => {
          'state': {'claim_state': 'unclaimed'},
        },
      'wifi.scan' => {
          'current_network': {
            'state': currentNetworkState,
            'ssid': currentSsid,
          },
          'networks': [
            {'ssid': 'Home', 'signal': 82, 'secured': true},
          ],
        },
      'wifi.configure' => {
          'operation': {
            'operation_id': payload['operation_id'],
            'state': 'waiting_confirmation',
          },
        },
      'wifi.confirm' => {
          'operation': {
            'operation_id': payload['operation_id'],
            'state': 'succeeded',
          },
        },
      'claim.complete' => {
          'controller': {'controller_id': 'ectrl-0123456789abcdefabcd'},
          'state': {'claim_state': 'claimed'},
        },
      _ => throw StateError('Unexpected operation $operation'),
    };
  }

  @override
  Future<void> close() async => closed = true;
}

class _FakeChangeNetworkTransport implements CommissioningTransport {
  _FakeChangeNetworkTransport({this.confirmState = 'succeeded'});
  final String confirmState;
  final operations = <String>[];

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async =>
      const [
        NearbyEidolonHost(
          address: 'AA:BB:CC:DD:EE:FF',
          name: 'Eidolon-4c0285',
          hostMarker: '4c0285',
          rssi: -41,
        ),
      ];

  @override
  Future<String> open({
    required String address,
    required String serviceUuid,
  }) async =>
      jsonEncode(validCommissioningEndpoint);

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async {}

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async {
    operations.add(operation);
    return switch (operation) {
      'controller.challenge' => {
          'contract_version': '1',
          'purpose': 'eidolon-controller-ble-auth-v1',
          'controller_id': 'ectrl-0123456789abcdefabcd',
          'challenge': validHostChallenge,
          'reset_epoch': 0,
        },
      'controller.authenticate' => {
          'state': {'claim_state': 'claimed'},
        },
      'wifi.scan' => {
          'networks': [
            {'ssid': 'New Home', 'signal': 90, 'secured': true},
          ],
        },
      'wifi.configure' => {
          'operation': {'state': 'waiting_confirmation'},
        },
      'wifi.confirm' => {
          'operation': {'state': confirmState},
        },
      'wifi.rollback' => {
          'operation': {'state': 'rolled_back'}
        },
      _ => throw StateError('Unexpected operation $operation'),
    };
  }

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets(
      'forgotten Host restores its grant even with an open Setup window',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final registry = InMemoryHostRegistry();
    final transport = _FakeCommissioningTransport(hasGrant: true);
    await tester.pumpWidget(MaterialApp(
        home: SetupWizardPage(
      registry: registry,
      transport: transport,
      controllerKeys: _FakeControllerKeyBridge(),
      developmentLanCommissioning: emptyLanCommissioning(),
      onComplete: (_) {},
    )));
    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('development-setup-code')), findsNothing);
    expect(transport.operations,
        ['controller.challenge', 'controller.authenticate', 'wifi.scan']);
    expect((await registry.load()).single.hostId, validHostId);
    await tester.tap(find.byKey(const Key('finish-without-network-change')));
    await tester.pumpAndSettle();
    expect(find.text('主机接入已完成'), findsOneWidget);
  });

  testWidgets(
      'network failure retains the enrolled peer and retry does not reenroll',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final registry = InMemoryHostRegistry();
    final transport = _FakeCommissioningTransport(failNetwork: true);
    await tester.pumpWidget(MaterialApp(
        home: SetupWizardPage(
      registry: registry,
      transport: transport,
      controllerKeys: _FakeControllerKeyBridge(),
      developmentLanCommissioning: emptyLanCommissioning(),
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
      onComplete: (_) {},
    )));
    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('development-setup-code')), '12345678');
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();
    expect((await registry.load()).single.hostId, validHostId);
    await tester.tap(find.text('Home'));
    await tester.enterText(
        find.byKey(const Key('wifi-passphrase')), 'wifi-password');
    await tester.tap(find.byKey(const Key('configure-host-network')));
    await tester.pumpAndSettle();
    expect((await registry.load()).single.hostId, validHostId);
    expect(find.byKey(const Key('setup-error')), findsOneWidget);
    transport.failNetwork = false;
    await tester.tap(find.byKey(const Key('configure-host-network')));
    await tester.pumpAndSettle();
    expect(find.text('主机接入已完成'), findsOneWidget);
    expect(transport.operations.where((op) => op == 'claim.complete'),
        hasLength(1));
  });

  testWidgets(
      'scanning a saved Host reconnects without Setup commands or replacing metadata',
      (tester) async {
    final saved = hostFixture(lastKnownBaseUrl: 'https://192.168.1.9:9002')
        .copyWith(displayName: '书房 Mac');
    final registry = InMemoryHostRegistry([saved]);
    final transport = _FakeCommissioningTransport();
    ManagedHost? selected;
    await tester.pumpWidget(MaterialApp(
        home: SetupWizardPage(
      developmentLanCommissioning: emptyLanCommissioning(),
      registry: registry,
      transport: transport,
      controllerKeys: _FakeControllerKeyBridge(),
      onComplete: (host) => selected = host,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();
    expect(find.text('已添加的主机'), findsOneWidget);
    expect(find.text('发现 1 台已添加主机，未发现新的主机。'), findsOneWidget);
    expect(find.text('书房 Mac'), findsOneWidget);
    expect(find.text('可添加的主机'), findsNothing);
    expect(find.text('已连接'), findsNothing);
    expect(transport.operations, isEmpty);
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(identical(selected, saved), isTrue);
    expect((await registry.load()).single.displayName, '书房 Mac');
    expect((await registry.load()).single.claimedAt, saved.claimedAt);
  });

  testWidgets(
      'saved BLE Host opens authenticated Wi-Fi recovery without reclaiming',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saved = hostFixture(lastKnownBaseUrl: 'https://192.168.100.19:9002');
    final registry = InMemoryHostRegistry([saved]);
    final transport = _FakeChangeNetworkTransport();
    ManagedHost? selected;
    await tester.pumpWidget(MaterialApp(
        home: SetupWizardPage(
      registry: registry,
      transport: transport,
      controllerKeys: _FakeControllerKeyBridge(),
      developmentLanCommissioning: emptyLanCommissioning(),
      onComplete: (host) => selected = host,
    )));
    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未确认局域网连接'), findsOneWidget);
    await tester
        .tap(find.byKey(ValueKey('restore-host-network-${saved.hostId}')));
    await tester.pumpAndSettle();
    expect(find.text('New Home'), findsOneWidget);
    expect(transport.operations,
        ['controller.challenge', 'controller.authenticate', 'wifi.scan']);
    expect(selected, isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect((await registry.load()).single.lastKnownBaseUrl,
        saved.lastKnownBaseUrl);
  });

  testWidgets(
      'unconfirmed Wi-Fi change rolls back instead of reporting success',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport =
        _FakeChangeNetworkTransport(confirmState: 'waiting_confirmation');
    await tester.pumpWidget(MaterialApp(
        home: ChangeNetworkPage(
      host: hostFixture(),
      transport: transport,
      controllerKeys: _FakeControllerKeyBridge(),
      nearbyHost: const NearbyEidolonHost(
          address: 'AA:BB', name: 'Eidolon', hostMarker: '4c0285', rssi: -41),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Home'));
    await tester.enterText(find.byType(TextField).last, 'new-network-secret');
    await tester.tap(find.byKey(const Key('confirm-network-change')));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi 已更换'), findsNothing);
    expect(transport.operations.last, 'wifi.rollback');
  });

  test('verifies the signed dynamic TLS endpoint against the Host credential',
      () async {
    final endpoint = await CommissioningEndpoint.parseAndVerifyDiscovered(
      jsonEncode(validCommissioningEndpoint),
    );

    expect(endpoint.hostId, validHostId);
    expect(endpoint.resetEpoch, 0);

    final tampered = Map<String, dynamic>.from(validCommissioningEndpoint)
      ..['reset_epoch'] = 1;
    await expectLater(
      CommissioningEndpoint.parseAndVerifyDiscovered(jsonEncode(tampered)),
      throwsA(isA<SetupTrustException>()),
    );
  });

  testWidgets(
      'no-network wizard scans, configures Wi-Fi, and claims Controller',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = _FakeCommissioningTransport();
    final controllerKeys = _FakeControllerKeyBridge();
    ManagedHost? completed;
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizardPage(
          developmentLanCommissioning: emptyLanCommissioning(),
          transport: transport,
          controllerKeys: controllerKeys,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          onComplete: (host) => completed = host,
        ),
      ),
    );

    expect(find.byKey(const Key('open-development-lan-setup')), findsNothing);

    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();

    expect(find.text('查找主机'), findsOneWidget);
    expect(find.text('Eidolon-4c0285'), findsOneWidget);
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('setup-code-title')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('development-setup-code')),
      '12345678',
    );
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();

    expect(find.text('让主机加入 Wi-Fi'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.enterText(
      find.byKey(const Key('wifi-passphrase')),
      'correct horse battery staple',
    );
    await tester.tap(find.byKey(const Key('configure-host-network')));
    await tester.pumpAndSettle();

    expect(find.text('主机接入已完成'), findsOneWidget);
    expect(transport.operations, [
      'controller.challenge',
      'session.authenticate',
      'claim.complete',
      'controller.challenge',
      'controller.authenticate',
      'wifi.scan',
      'wifi.configure',
      'wifi.confirm',
    ]);
    await tester.tap(find.byKey(const Key('finish-setup')));
    expect(completed?.hostId, validHostId);
    expect(completed?.controllerId, 'ectrl-0123456789abcdefabcd');
    expect(completed?.displayName, 'Eidolon-4c0285');
    expect(
      completed?.tlsSpkiFingerprint,
      validCommissioningEndpoint['tls_spki_fingerprint'],
    );
    expect(transport.closed, isTrue);
  });

  testWidgets('already-networked Host keeps Wi-Fi and claims Controller',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = _FakeCommissioningTransport(
      currentNetworkState: 'connected',
      currentSsid: 'Existing Home',
    );
    final controllerKeys = _FakeControllerKeyBridge();
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizardPage(
          developmentLanCommissioning: emptyLanCommissioning(),
          transport: transport,
          controllerKeys: controllerKeys,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          onComplete: (_) {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('development-setup-code')),
      '12345678',
    );
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();

    expect(find.text('确认主机网络'), findsOneWidget);
    expect(find.text('主机已连接 Existing Home'), findsOneWidget);
    final keepNetwork = find.byKey(const Key('finish-without-network-change'));
    await tester.ensureVisible(keepNetwork);
    await tester.tap(keepNetwork);
    await tester.pumpAndSettle();

    expect(find.text('主机接入已完成'), findsOneWidget);
    expect(transport.operations, [
      'controller.challenge',
      'session.authenticate',
      'claim.complete',
      'controller.challenge',
      'controller.authenticate',
      'wifi.scan',
    ]);
    expect(transport.closed, isTrue);
  });

  testWidgets('claimed Host changes Wi-Fi through Controller challenge',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = _FakeChangeNetworkTransport();
    final controllerKeys = _FakeControllerKeyBridge();
    final host = ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: 'Living room Eidolon',
      claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNetworkPage(
          host: host,
          transport: transport,
          controllerKeys: controllerKeys,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('scan-host-for-network-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Home'));
    await tester.enterText(find.byType(TextField).last, 'new-network-secret');
    await tester.tap(find.byKey(const Key('confirm-network-change')));
    await tester.pumpAndSettle();

    expect(find.text('Wi-Fi 已更换'), findsOneWidget);
    expect(transport.operations, [
      'controller.challenge',
      'controller.authenticate',
      'wifi.scan',
      'wifi.configure',
      'wifi.confirm',
    ]);
  });

  testWidgets('the progress bar counts what the person does, not our phases', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizardPage(
          developmentLanCommissioning: emptyLanCommissioning(),
          transport: _FakeCommissioningTransport(),
          controllerKeys: _FakeControllerKeyBridge(),
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          onComplete: (_) {},
        ),
      ),
    );

    // Three things happen here and one waits on the other side. 认领 is the
    // phone and the Host talking to each other and 主机接入 is the outcome of
    // that conversation; listing them beside "choose a Wi-Fi network" made
    // setup look half again as long as it is, while the naming step that
    // actually follows went unmentioned.
    // The row itself, exactly: three things done here and the one waiting
    // after. Not 认领 (the phone and the Host talking to each other) and not
    // 主机接入 (the outcome of that conversation) — listing those made setup
    // look half again as long as it is, while the naming step that actually
    // follows went unmentioned.
    // The steps are drawn as one chip each now, so the row is read chip by
    // chip rather than as a single joined string.
    for (final step in ['选一台主机', '确认管理权限', '设置 Wi-Fi（可选）']) {
      expect(find.text(step), findsOneWidget, reason: step);
    }
    expect(find.text('认领'), findsNothing);
    expect(find.text('主机接入'), findsNothing);
  });
}
