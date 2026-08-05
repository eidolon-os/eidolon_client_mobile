import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/dev_descriptor.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/change_network_page.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_wizard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';

class _FakeCommissioningTransport implements CommissioningTransport {
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
  Future<ControllerIdentity> getControllerIdentity() async =>
      const ControllerIdentity(
        controllerId: 'ectrl-0123456789abcdefabcd',
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signControllerChallenge(
    Map<String, dynamic> challenge,
  ) async =>
      'test-controller-signature';

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
  Future<String> signControllerChallenge(
    Map<String, dynamic> challenge,
  ) async =>
      'valid-controller-signature';

  @override
  Future<ControllerIdentity> getControllerIdentity() =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}

void main() {
  test('verifies the signed dynamic TLS endpoint against the Host credential',
      () async {
    final credential = await DevelopmentCommissioningDescriptor.parseAndVerify(
      validDevDescriptorJson,
      clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
    );
    final endpoint = await CommissioningEndpoint.parseAndVerify(
      jsonEncode(validCommissioningEndpoint),
      credential,
    );

    expect(endpoint.hostId, credential.hostId);
    expect(endpoint.resetEpoch, 0);

    final tampered = Map<String, dynamic>.from(validCommissioningEndpoint)
      ..['reset_epoch'] = 1;
    await expectLater(
      CommissioningEndpoint.parseAndVerify(jsonEncode(tampered), credential),
      throwsA(isA<SetupTrustException>()),
    );
  });

  testWidgets(
      'no-network wizard scans, configures Wi-Fi, and claims Controller',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = _FakeCommissioningTransport();
    ManagedHost? completed;
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizardPage(
          transport: transport,
          clock: () => DateTime.parse('2026-08-05T00:10:00Z'),
          onComplete: (host) => completed = host,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('commissioning-credential-input')),
      validDevDescriptorJson,
    );
    await tester.tap(find.byKey(const Key('verify-and-find-host')));
    await tester.pumpAndSettle();

    expect(find.text('选择附近主机'), findsOneWidget);
    expect(find.text('Eidolon-4c0285'), findsOneWidget);
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();

    expect(find.text('让主机加入 Wi-Fi'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.enterText(
      find.byKey(const Key('wifi-passphrase')),
      'correct horse battery staple',
    );
    await tester.tap(find.byKey(const Key('configure-and-claim')));
    await tester.pumpAndSettle();

    expect(find.text('主机已可以使用'), findsOneWidget);
    expect(transport.operations, [
      'session.authenticate',
      'wifi.scan',
      'wifi.configure',
      'wifi.confirm',
      'claim.complete',
    ]);
    await tester.tap(find.byKey(const Key('finish-setup')));
    expect(completed?.hostId, validDevDescriptor['host_id']);
    expect(completed?.controllerId, 'ectrl-0123456789abcdefabcd');
    expect(transport.closed, isTrue);
  });

  testWidgets('claimed Host changes Wi-Fi through Controller challenge',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = _FakeChangeNetworkTransport();
    final host = ManagedHost(
      hostId: validDevDescriptor['host_id']! as String,
      hostPublicKey: validDevDescriptor['host_public_key']! as String,
      hostFingerprint:
          validDevDescriptor['host_public_key_fingerprint']! as String,
      bleServiceUuid: validDevDescriptor['ble_service_uuid']! as String,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: 'Living room Eidolon',
      claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNetworkPage(host: host, transport: transport),
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
