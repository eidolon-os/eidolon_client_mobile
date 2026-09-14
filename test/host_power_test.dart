import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_product_controller.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/network_changes.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_power_section.dart';
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

class _Harness {
  final requests = <http.Request>[];
  final network = _Network();
  late final HostProductController controller;
  int? failure;
  int capabilityStatus = 200;
  bool supported = true;
  bool mismatch = false;
  int localCalls = 0;
  Completer<void>? hold;

  _Harness() {
    controller = HostProductController(
      host: hostFixture(lastKnownBaseUrl: 'https://192.168.1.26:9002'),
      onHostUpdated: (_) async {},
      transport: NoopTransport(),
      controllerKeys: FakeControllerKeys(),
      networkChanges: network,
      localApiClientFactory: (_) => LocalApiClient(
        httpClient: MockClient((request) {
          localCalls++;
          return hostSessionResponse(request);
        }),
      ),
      managementClientFactory: (_) => ManagementClient(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/power')) {
            return http.Response(
                jsonEncode({
                  'can_power_off': supported,
                  if (!supported) 'unavailable_reason': '这台主机的操作系统暂不支持远程关机',
                }),
                capabilityStatus, headers: {
              'content-type': 'application/json; charset=utf-8',
            });
          }
          if (!request.url.path.endsWith('/poweroff')) {
            return http.Response('{}', 404);
          }
          requests.add(request);
          if (hold != null) await hold!.future;
          if (failure == 0) throw http.ClientException('connection lost');
          if (failure != null) return http.Response('{}', failure!);
          return http.Response(
              jsonEncode({
                'request_id': mismatch
                    ? 'another'
                    : jsonDecode(request.body)['request_id'],
                'operation': 'system.poweroff',
                'status': 'accepted',
              }),
              202);
        }),
      ),
    );
  }

  Future<void> connect() => controller.connect(allowBle: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'accepted request uses authenticated selected Host and blocks duplicate sends',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.connect();
    final hostId = h.controller.host.hostId;
    await Future.wait([h.controller.powerOff(), h.controller.powerOff()]);
    expect(h.requests, hasLength(1));
    final request = h.requests.single;
    expect(request.url.toString(),
        'https://192.168.1.26:9002/api/management/v1/host/poweroff');
    expect(request.method, 'POST');
    expect(request.headers['authorization'], startsWith('Bearer '));
    expect((jsonDecode(request.body) as Map).keys, ['request_id']);
    expect(h.controller.powerOffOutcome, contains('关机指令已接受'));
    expect(h.controller.connection, isNull);
    expect(h.controller.host.hostId, hostId);
    await h.controller.powerOff();
    expect(h.requests, hasLength(1));
  });

  for (final status in [0, 502]) {
    test(
        'lost response $status is unknown and never reauthenticated or retried',
        () async {
      final h = _Harness()..failure = status;
      addTearDown(h.controller.dispose);
      await h.connect();
      final reads = h.localCalls;
      await h.controller.powerOff();
      h.network.events.add(null);
      await Future<void>.delayed(Duration.zero);
      await h.controller.powerOff();
      expect(h.requests, hasLength(1));
      expect(h.localCalls, reads);
      expect(h.controller.powerOffOutcome, contains('结果未确认'));
      expect(h.controller.connection, isNull);
    });
  }

  for (final status in [401, 403, 404]) {
    test('explicit refusal $status does not claim acceptance or retry',
        () async {
      final h = _Harness()..failure = status;
      addTearDown(h.controller.dispose);
      await h.connect();
      final reads = h.localCalls;
      await expectLater(
          h.controller.powerOff(), throwsA(isA<ManagementRequestException>()));
      expect(h.requests, hasLength(1));
      expect(h.localCalls, reads);
      expect(h.controller.powerOffOutcome, isNull);
      expect(h.controller.powerOffBusy, isFalse);
    });
  }

  test('a mismatched request identity is unknown, not accepted', () async {
    final h = _Harness()..mismatch = true;
    addTearDown(h.controller.dispose);
    await h.connect();
    await h.controller.powerOff();
    expect(h.controller.powerOffOutcome, contains('结果未确认'));
  });

  test('only explicit reconnect resumes a suspended session', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.connect();
    await h.controller.powerOff();
    await h.connect();
    expect(h.controller.connection, isNotNull);
    expect(h.controller.powerOffOutcome, isNull);
  });

  testWidgets(
      'confirmation names the Host; cancel sends nothing; pending disables entry',
      (tester) async {
    final h = _Harness()..hold = Completer<void>();
    addTearDown(h.controller.dispose);
    await h.connect();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HostPowerSection(controller: h.controller))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('power-off-host')));
    await tester.pumpAndSettle();
    expect(find.text('关闭「${h.controller.host.readableName}」？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(h.requests, isEmpty);
    await tester.tap(find.byKey(const Key('power-off-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-power-off-host-action')));
    await tester.pumpAndSettle();
    expect(find.text('正在请求关机…'), findsOneWidget);
    expect(
        tester.widget<ListTile>(find.byKey(const Key('power-off-host'))).onTap,
        isNull);
    expect(h.requests, hasLength(1));
    h.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('关机指令已接受'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HostPowerSection(controller: h.controller))));
    await tester.pumpAndSettle();
    expect(find.textContaining('关机指令已接受'), findsOneWidget);
    expect(h.requests, hasLength(1));
  });

  for (final mode in ['offline', 'old', 'unsupported']) {
    testWidgets('$mode Host has a disabled power entry', (tester) async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      if (mode != 'offline') await h.connect();
      if (mode == 'old') h.capabilityStatus = 404;
      if (mode == 'unsupported') h.supported = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HostPowerSection(controller: h.controller))));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ListTile>(find.byKey(const Key('power-off-host')))
              .onTap,
          isNull);
      expect(
          find.textContaining(switch (mode) {
            'offline' => '连接主机后可用',
            'old' => '尚未提供关机接口',
            _ => '暂不支持远程关机',
          }),
          findsOneWidget);
      expect(h.requests, isEmpty);
    });
  }
}
