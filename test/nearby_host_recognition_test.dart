import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_wizard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_session_fixtures.dart';
import 'support/local_api_fixtures.dart';
import 'support/setup_fixtures.dart';
import 'support/setup_discovery_fixtures.dart';

class _Transport implements CommissioningTransport {
  _Transport(this.documents);

  final Map<String, Future<String> Function()> documents;
  final opened = <String>[];
  bool linkOpen = false;
  int closeCount = 0;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async =>
      [
        for (final address in documents.keys)
          NearbyEidolonHost(
            address: address,
            // Deliberately identical: a matching advertisement is not identity.
            name: 'Eidolon-4c0285',
            hostMarker: '4c0285',
            rssi: -30 - documents.keys.toList().indexOf(address),
          ),
      ];

  @override
  Future<String> open({required String address, required String serviceUuid}) {
    expect(linkOpen, isFalse, reason: 'Only one native GATT link is available');
    linkOpen = true;
    opened.add(address);
    return documents[address]!();
  }

  @override
  Future<void> close() async {
    linkOpen = false;
    closeCount++;
  }

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async =>
      fail('Discovery must not authenticate or claim');

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async =>
      fail('Discovery must not issue Setup commands');
}

Future<void> _scan(WidgetTester tester, _Transport transport) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: SetupWizardPage(
      developmentLanCommissioning: emptyLanCommissioning(),
      registry: InMemoryHostRegistry([
        hostFixture().copyWith(displayName: '书房 Mac'),
      ]),
      transport: transport,
      onComplete: (_) {},
    ),
  ));
  await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
  await tester.pump();
}

void main() {
  testWidgets('signed identity groups new Hosts first and merges saved aliases',
      (tester) async {
    final newEndpoint = await signedEndpointDocument(
        setupSession: validCommissioningEndpoint['setup_session']);
    final transport = _Transport({
      'saved': () async => jsonEncode(validCommissioningEndpoint),
      'alias': () async => jsonEncode(validCommissioningEndpoint),
      'new': () async => newEndpoint,
    });
    await _scan(tester, transport);
    await tester.pumpAndSettle();

    expect(find.text('书房 Mac'), findsOneWidget);
    expect(find.text('Eidolon-4c0285'), findsOneWidget);
    expect(find.text('可添加的主机'), findsOneWidget);
    expect(find.text('已添加的主机'), findsOneWidget);
    expect(tester.getTopLeft(find.text('可添加的主机')).dy,
        lessThan(tester.getTopLeft(find.text('已添加的主机')).dy));
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(transport.closeCount, 4);
    expect(transport.linkOpen, isFalse);
  });

  testWidgets(
      'a forged lookalike stays unidentified while saved Host is usable',
      (tester) async {
    final transport = _Transport({
      'forged': () async => jsonEncode({
            ...validCommissioningEndpoint,
            'reset_epoch': 9,
          }),
      'saved': () async => jsonEncode(validCommissioningEndpoint),
    });
    await _scan(tester, transport);
    await tester.pumpAndSettle();

    expect(find.text('暂未识别的主机'), findsOneWidget);
    expect(find.text('重试识别'), findsOneWidget);
    expect(find.text('书房 Mac'), findsOneWidget);
    expect(find.text('可添加的主机'), findsNothing);
    expect(find.text('发现 1 台已添加主机，另有 1 台暂未识别。'), findsOneWidget);
    expect(find.textContaining('未发现新的主机'), findsNothing);
  });

  testWidgets('identification timeout closes the link and scans the next Host',
      (tester) async {
    final pending = Completer<String>();
    final transport = _Transport({
      'silent': () => pending.future,
      'saved': () async => jsonEncode(validCommissioningEndpoint),
    });
    await _scan(tester, transport);
    expect(find.text('正在识别…'), findsNWidgets(2));
    expect(find.text('已添加的主机'), findsNothing);
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();

    expect(find.text('重试识别'), findsOneWidget);
    expect(find.text('书房 Mac'), findsOneWidget);
    expect(transport.opened, ['silent', 'saved']);
    expect(transport.closeCount, 3);
    pending.complete(jsonEncode(validCommissioningEndpoint));
    await tester.pumpAndSettle();
    expect(find.text('重试识别'), findsOneWidget);
  });

  testWidgets('rescan removes results from the previous pass', (tester) async {
    final transport = _Transport({
      'saved': () async => jsonEncode(validCommissioningEndpoint),
    });
    await _scan(tester, transport);
    await tester.pumpAndSettle();
    expect(find.text('书房 Mac'), findsOneWidget);
    transport.documents.clear();
    await tester.tap(find.text('重新扫描'));
    await tester.pumpAndSettle();
    expect(find.text('书房 Mac'), findsNothing);
    expect(find.text('已添加的主机'), findsNothing);
    expect(find.byKey(const Key('scan-nearby-hosts')), findsOneWidget);
  });

  testWidgets('leaving during identification cannot open the next candidate',
      (tester) async {
    final pending = Completer<String>();
    final transport = _Transport({
      'pending': () => pending.future,
      'next': () async => jsonEncode(validCommissioningEndpoint),
    });
    await _scan(tester, transport);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(jsonEncode(validCommissioningEndpoint));
    await tester.pumpAndSettle();
    expect(transport.opened, ['pending']);
    expect(transport.linkOpen, isFalse);
    expect(tester.takeException(), isNull);
  });
}
