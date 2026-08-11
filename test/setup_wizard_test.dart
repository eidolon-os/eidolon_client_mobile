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
  });

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
    return switch (operation) {
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
          'operation': {'state': 'succeeded'},
        },
      _ => throw StateError('Unexpected operation $operation'),
    };
  }

  @override
  Future<void> close() async {}
}

void main() {
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
          transport: transport,
          controllerKeys: controllerKeys,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          onComplete: (host) => completed = host,
        ),
      ),
    );

    expect(find.byKey(const Key('open-development-lan-setup')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();

    expect(find.text('查找附近主机'), findsOneWidget);
    expect(find.text('Eidolon-4c0285'), findsOneWidget);
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();

    expect(find.text('输入 Setup 码'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('configure-and-claim')));
    await tester.pumpAndSettle();

    expect(find.text('主机接入已完成'), findsOneWidget);
    expect(transport.operations, [
      'session.authenticate',
      'wifi.scan',
      'wifi.configure',
      'wifi.confirm',
      'claim.complete',
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
    final keepNetwork = find.byKey(const Key('keep-network-and-claim'));
    await tester.ensureVisible(keepNetwork);
    await tester.tap(keepNetwork);
    await tester.pumpAndSettle();

    expect(find.text('主机接入已完成'), findsOneWidget);
    expect(transport.operations, [
      'session.authenticate',
      'wifi.scan',
      'claim.complete',
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
}
