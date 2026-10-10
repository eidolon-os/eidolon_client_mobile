import 'dart:convert';
import 'package:eidolon_client_mobile/src/features/setup/eidolon_app_shell.dart';

import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_wizard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';
import 'support/setup_discovery_fixtures.dart';

final _host = ManagedHost(
  hostId: validHostId,
  hostPublicKey: validHostPublicKey,
  hostFingerprint: validHostPublicKeyFingerprint,
  bleServiceUuid: validBleServiceUuid,
  controllerId: 'ectrl-0123456789abcdefabcd',
  displayName: 'Eidolon-4c0285',
  claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
);

class _RefusingKeyBridge implements ControllerKeyBridge {
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

/// A Host that has been claimed and no longer knows this phone: the exact
/// state a reinstalled App reaches, refusing the claim with controller_denied.
class _RefusingTransport implements CommissioningTransport {
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
  Future<void> secure({required String tlsSpkiFingerprint}) async {}

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async =>
      switch (operation) {
        'session.authenticate' => {
            'state': {'claim_state': 'claimed'},
          },
        'wifi.scan' => {
            'current_network': {'state': 'connected', 'ssid': 'Home'},
            'networks': const [
              {'ssid': 'Home', 'signal': 82, 'secured': true},
            ],
          },
        _ => throw const CommissioningRequestException(
            'controller_denied',
            'Controller is not authorized for this Host',
          ),
      };

  @override
  Future<void> close() async {}
}

Future<void> _openHostDetail(WidgetTester tester) async {
  await tester.pumpWidget(
    EidolonMobileApp(hostRegistry: InMemoryHostRegistry([_host])),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Eidolon-4c0285'));
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView), const Offset(0, -420));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open-host-settings')));
  await tester.pumpAndSettle();
  await tester.dragUntilVisible(
    find.byKey(const Key('open-managed-controllers')),
    find.byType(Scrollable).last,
    const Offset(0, -250),
  );
}

void main() {
  testWidgets(
      'common search replaces an existing Controller and preserves the local name',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final registry = InMemoryHostRegistry([_host]);
    String? enteredController;
    await tester.pumpWidget(MaterialApp(
        home: EidolonAppShell(
      registry: registry,
      conversationBuilder: (_, controller) {
        enteredController = controller.host.controllerId;
        return const Scaffold(body: Text('准备对话'));
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-another-host')));
    await tester.pumpAndSettle();
    final restored = ManagedHost.fromJson({
      ..._host.toJson(),
      'controller_id': 'ectrl-fedcba9876543210abcd',
      'display_name': 'Host 默认名'
    });
    tester
        .widget<SetupWizardPage>(find.byType(SetupWizardPage))
        .onComplete(restored);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-local-connection-page')), findsOneWidget);
    expect(find.byKey(const Key('host-settings-page')), findsNothing);
    expect(find.byType(SetupWizardPage), findsNothing);
    expect((await registry.load()).single.displayName, _host.displayName);
    expect((await registry.load()).single.controllerId, restored.controllerId);
    await tester.tap(find.byKey(const Key('open-conversation')));
    await tester.pumpAndSettle();
    expect(enteredController, restored.controllerId);
  });

  testWidgets('settings do not expose a separate recovery route',
      (tester) async {
    await _openHostDetail(tester);
    expect(find.byKey(const Key('controller-recovery')), findsNothing);
    expect(find.byKey(const Key('open-managed-controllers')), findsOneWidget);
  });

  testWidgets('a refused claim names the recovery instead of ending there',
      (tester) async {
    // Tall surface so the whole wizard step, error notice included, is built:
    // a lazily built ListView does not create the rows nobody can see.
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SetupWizardPage(
          developmentLanCommissioning: emptyLanCommissioning(),
          onComplete: (_) {},
          transport: _RefusingTransport(),
          controllerKeys: _RefusingKeyBridge(),
          clock: () => DateTime.parse('2026-08-05T00:00:00Z'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eidolon-4c0285'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('development-setup-code')),
      '13572468',
    );
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('setup-error')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('setup-error')),
        matching: find.byType(Text),
      ),
    );
    expect(notice.data, isNot(contains('controller-reset')));
    expect(notice.data, contains('重新搜索主机'));
  });
}
