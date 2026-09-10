import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/development_lan_commissioning.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_wizard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/host_session_fixtures.dart';
import 'support/setup_discovery_fixtures.dart';
import 'support/setup_fixtures.dart';

class _LanDiscovery implements LocalApiDiscovery {
  @override
  Future<LocalApiSurvey> discover(
          {Duration timeout = const Duration(seconds: 5)}) async =>
      const LocalApiSurvey([
        LocalApiSourceReport(
          origin: LocalApiCandidateOrigin.announced,
          attempted: '_eidolon-local-api._tcp',
          candidates: [
            LocalApiCandidate(
              origin: LocalApiCandidateOrigin.announced,
              endpoint: LocalApiEndpoint(
                instanceName: 'Host',
                baseUrl: 'https://192.168.1.25:9002',
                ipAddress: '192.168.1.25',
                contractVersion: '1',
              ),
            )
          ],
        ),
      ]);
}

class _Ble extends NoopTransport {
  int secureCalls = 0;
  final operations = <String>[];
  @override
  Future<List<NearbyEidolonHost>> scan(
          {required String serviceUuid,
          Duration timeout = const Duration(seconds: 8)}) async =>
      const [
        NearbyEidolonHost(
            address: 'AA:BB:CC:DD:EE:FF',
            name: 'Eidolon-4c0285',
            hostMarker: '4c0285',
            rssi: -40),
      ];
  @override
  Future<String> open(
          {required String address, required String serviceUuid}) async =>
      jsonEncode(validCommissioningEndpoint);
  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async {
    expect(
        tlsSpkiFingerprint, validCommissioningEndpoint['tls_spki_fingerprint']);
    secureCalls++;
  }

  @override
  Future<Map<String, dynamic>> request(
      String operation, Map<String, dynamic> payload) async {
    operations.add(operation);
    return switch (operation) {
      'session.authenticate' => {
          'state': {'claim_state': 'unclaimed'}
        },
      'wifi.scan' => {
          'networks': [
            {'ssid': 'Home', 'signal': 80, 'secured': true}
          ]
        },
      _ => throw StateError('Unexpected operation $operation'),
    };
  }
}

DevelopmentLanCommissioning _lan({
  Future<String> Function(String)? fetch,
  http.Client Function(String)? client,
}) =>
    DevelopmentLanCommissioning(
      discovery: _LanDiscovery(),
      controllerKeys: FakeControllerKeys(),
      endpointFetcher:
          fetch ?? (_) async => jsonEncode(validCommissioningEndpoint),
      pinnedClientFactory: client,
      clock: () => DateTime.utc(2026, 8, 5, 0, 10),
    );

Future<void> _scan(
  WidgetTester tester, {
  required CommissioningTransport ble,
  required DevelopmentLanCommissioning lan,
  HostRegistry? registry,
  ValueChanged<ManagedHost>? onComplete,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: SetupWizardPage(
    transport: ble,
    developmentLanCommissioning: lan,
    controllerKeys: FakeControllerKeys(),
    clock: () => DateTime.utc(2026, 8, 5, 0, 10),
    registry: registry,
    onComplete: onComplete ?? (_) {},
  )));
  expect(find.byKey(const Key('open-development-lan-setup')), findsNothing);
  await tester.tap(find.byKey(const Key('scan-nearby-hosts')));
  await tester.pump();
}

void main() {
  testWidgets(
      'LAN-only Host can be claimed without BLE permission or Wi-Fi setup',
      (tester) async {
    final requests = <http.Request>[];
    ManagedHost? completed;
    await _scan(tester,
        ble: UnavailableBleTransport(),
        lan: _lan(client: (pin) {
          expect(pin, validCommissioningEndpoint['tls_spki_fingerprint']);
          return MockClient((request) async {
            requests.add(request);
            return http.Response(
                jsonEncode({
                  'contract_version': '1',
                  'operation': 'local.lan-commissioning-claim',
                  'host_id': validHostId,
                  'controller': {'controller_id': controllerIdFixture},
                  'state': {
                    'claim_state': 'claimed',
                    'network_state': 'connected'
                  },
                }),
                200);
          });
        }),
        onComplete: (host) => completed = host);
    await tester.pumpAndSettle();
    expect(find.text('可添加的主机'), findsOneWidget);
    expect(find.text('局域网地址：192.168.1.25:9002'), findsOneWidget);
    await tester.tap(find.text('识别详情'));
    await tester.pumpAndSettle();
    expect(find.text('Host ID：$validHostId'), findsOneWidget);
    expect(find.text('机型和系统信息将在添加并连接后显示'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('主机已经联网，无需重新配置 Wi-Fi。'), findsOneWidget);
    expect(find.textContaining('连上 Wi-Fi'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('development-setup-code')), '12345678');
    await tester.enterText(
        find.byKey(const Key('lan-controller-name')), '我的平板');
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();
    expect(find.text('主机接入已完成'), findsOneWidget);
    await tester.tap(find.byKey(const Key('finish-setup')));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/api/local/v1/commissioning/claim');
    final payload = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(payload['setup_code'], '12345678');
    expect(payload['controller']['display_name'], '我的平板');
    expect(completed!.hostId, validHostId);
    expect(completed!.lastKnownBaseUrl, 'https://192.168.1.25:9002');
  });

  testWidgets(
      'BLE and LAN sightings merge into one saved Host without claiming',
      (tester) async {
    final ble = _Ble();
    final saved = hostFixture().copyWith(
      displayName: '书房主机',
      machineInfo: const HostMachineInfo(
        hostname: 'study-macbook.local',
        model: 'MacBook Pro',
        cpuModel: 'Apple M3 Pro',
        cpuCores: 12,
        memoryBytes: 36 * 1024 * 1024 * 1024,
        operatingSystem: 'macOS',
      ),
      lastKnownBaseUrl: 'https://192.168.1.99:9002',
      lastConnectedAt: DateTime.utc(2026, 9, 10),
    );
    final registry = InMemoryHostRegistry([saved]);
    ManagedHost? opened;
    await _scan(tester,
        ble: ble,
        lan: _lan(client: (_) => throw StateError('No claim expected')),
        registry: registry,
        onComplete: (host) => opened = host);
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(360, 1000));
    await tester.pumpAndSettle();
    expect(find.text('书房主机'), findsOneWidget);
    expect(find.textContaining('MacBook Pro · Apple M3 Pro'), findsOneWidget);
    await tester.tap(find.text('识别详情'));
    await tester.pumpAndSettle();
    expect(find.text('系统主机名：study-macbook.local'), findsOneWidget);
    expect(find.text('发现方式：局域网 + 蓝牙 · 信号 -40 dBm'), findsOneWidget);
    expect(find.text('局域网地址：192.168.1.25:9002'), findsOneWidget);
    expect(find.textContaining('192.168.1.99'), findsNothing);
    expect(find.text('设备资料来自上次连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('发现 1 台已添加主机，未发现新的主机。'), findsOneWidget);
    await tester.ensureVisible(find.text('连接'));
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(identical(opened, saved), isTrue);
    expect(ble.secureCalls, 0);
    expect(ble.operations, isEmpty);
    expect(await registry.load(), [saved]);
  });

  testWidgets('missing LAN entrance leaves the original BLE setup usable',
      (tester) async {
    final ble = _Ble();
    await _scan(tester,
        ble: ble,
        lan: _lan(
            fetch: (url) async => throw DevelopmentEndpointRefused(
                baseUrl: url, statusCode: 404)));
    await tester.pumpAndSettle();
    expect(find.text('添加'), findsOneWidget);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('输入 Setup 码'), findsOneWidget);
    expect(find.byKey(const Key('lan-controller-name')), findsNothing);
    await tester.enterText(
        find.byKey(const Key('development-setup-code')), '12345678');
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();
    expect(find.text('让主机加入 Wi-Fi'), findsOneWidget);
    expect(ble.operations, ['session.authenticate', 'wifi.scan']);
  });

  testWidgets('a refused LAN claim is not automatically replayed over BLE',
      (tester) async {
    final ble = _Ble();
    var claims = 0;
    await _scan(tester,
        ble: ble,
        lan: _lan(
            client: (_) => MockClient((_) async {
                  claims++;
                  return http.Response('{}', 401);
                })));
    await tester.pumpAndSettle();
    expect(find.text('添加'), findsOneWidget);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('development-setup-code')), '12345678');
    await tester.tap(find.byKey(const Key('authenticate-setup-code')));
    await tester.pumpAndSettle();
    expect(claims, 1);
    expect(ble.secureCalls, 0);
    expect(ble.operations, isEmpty);
    expect(find.byKey(const Key('setup-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-setup-via-nearby')));
    await tester.pumpAndSettle();
    expect(ble.secureCalls, 1);
    expect(ble.operations, isEmpty);
    expect(find.byKey(const Key('lan-controller-name')), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('development-setup-code')))
            .controller!
            .text,
        isEmpty);
  });

  testWidgets('a late LAN discovery result cannot update a disposed page',
      (tester) async {
    final pending = Completer<String>();
    await _scan(tester,
        ble: UnavailableBleTransport(),
        lan: _lan(fetch: (_) => pending.future));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(jsonEncode(validCommissioningEndpoint));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('rescan clears stale LAN Hosts when the network stops answering',
      (tester) async {
    var reachable = true;
    await _scan(tester, ble: UnavailableBleTransport(),
        lan: _lan(fetch: (_) async {
      if (!reachable) throw TimeoutException('Host unavailable');
      return jsonEncode(validCommissioningEndpoint);
    }));
    await tester.pumpAndSettle();
    expect(find.text('添加'), findsOneWidget);
    reachable = false;
    await tester.tap(find.text('重新扫描'));
    await tester.pumpAndSettle();
    expect(find.text('添加'), findsNothing);
    expect(find.text('可添加的主机'), findsNothing);
    expect(find.byKey(const Key('setup-error')), findsOneWidget);
    expect(find.byKey(const Key('scan-nearby-hosts')), findsOneWidget);
  });
}
