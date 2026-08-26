import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/activity_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/mission_control_page.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HostMoment _moment({
  String eventId = 'evt-1',
  String action = 'companion.archived',
  String subjectName = '小忆',
  Map<String, String> detail = const {},
  DateTime? at,
}) =>
    HostMoment(
      eventId: eventId,
      occurredAt: at ?? DateTime.utc(2026, 8, 17, 2, 14),
      action: action,
      subjectType: 'companion',
      subjectId: 'companion-a',
      subjectName: subjectName,
      outcome: 'success',
      detail: detail,
    );

HostServiceInventory _services({int ready = 2, int failed = 0}) =>
    HostServiceInventory(
      services: [
        for (var index = 0; index < ready; index += 1)
          HostService(
            serviceId: 'service-$index',
            required: true,
            enabled: true,
            revision: 1,
            runtimeState: HostServiceRuntimeState.ready,
            detail: null,
            observedAt: DateTime.utc(2026, 8, 17, 2),
          ),
        for (var index = 0; index < failed; index += 1)
          HostService(
            serviceId: 'broken-$index',
            required: true,
            enabled: true,
            revision: 1,
            runtimeState: HostServiceRuntimeState.failed,
            detail: null,
            observedAt: DateTime.utc(2026, 8, 17, 2),
          ),
      ],
    );

/// One device as the Host now describes it: composed and phrased on that side,
/// so this fixture states an answer rather than three authorities' halves.
MountedDevice _mountedDevice(
  String name, {
  String? companionId,
  String companionName = '',
  String state = 'awaiting_companion',
}) =>
    MountedDevice.fromView(
      DeviceView.fromJson({
        'device_id': 'device-$name',
        'label': name,
        'kind': name,
        'state': state,
        'answers_as_companion_id': companionId,
        'answers_as_companion_name': companionName,
        'revision': 1,
        'mount_revision': 2,
        'updated_at': '2026-08-17T00:00:00Z',
        'online': 'unknown',
        'online_reason': '这台主机没有任何东西在观测设备是否开着',
        'claim_state': 'active',
        'claim_generation': 1,
        'trust_epoch': 1,
        'owner_domain_generation': 3,
        'manifest_id': name,
        'manifest_revision': 1,
      }),
    );

MountedDeviceInventory _devices(List<String> names) => MountedDeviceInventory(
      devices: [
        for (final name in names)
          _mountedDevice(name),
      ],
    );

Future<void> _open(
  WidgetTester tester, {
  Future<HostActivity> Function()? loadActivity,
  Future<HostServiceInventory> Function()? listServices,
  MountedDeviceInventory? devices,
  String? devicesError,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MissionControlPage(
        loadActivity: loadActivity ??
            () async => HostActivity(
                  moments: [_moment()],
                ),
        listServices: listServices ?? () async => _services(),
        devices: devices,
        devicesError: devicesError,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('what happened is said as a sentence, not as an event type', (
    tester,
  ) async {
    await _open(
      tester,
      loadActivity: () async => HostActivity(
        moments: [
          _moment(eventId: 'evt-2', action: 'companion.workspace.initialized'),
          _moment(
            detail: const {'companion_id_name': '阿力'},
          ),
        ],
      ),
    );

    expect(find.text('「小忆」来了'), findsOneWidget);
    expect(find.text('你把「小忆」收了起来，改由「阿力」回答'), findsOneWidget);
    // The Host's own wording never reaches the person.
    expect(find.textContaining('companion.'), findsNothing);
  });

  testWidgets('an Eidolon nobody named is not named by its identifier', (
    tester,
  ) async {
    await _open(
      tester,
      loadActivity: () async => HostActivity(
        moments: [_moment(subjectName: '')],
      ),
    );

    expect(find.text('你把「还没起名的 Eidolon」收了起来'), findsOneWidget);
  });

  testWidgets('a history that could not be read is never an empty history', (
    tester,
  ) async {
    await _open(tester, loadActivity: () async => throw StateError('主机没有回答'));

    expect(
      find.byKey(const Key('mission-control-activity-failure')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mission-control-activity-empty')),
      findsNothing,
    );
  });

  testWidgets('a history that really is empty says so', (tester) async {
    await _open(
      tester,
      loadActivity: () async =>
          const HostActivity(moments: []),
    );

    expect(
      find.byKey(const Key('mission-control-activity-empty')),
      findsOneWidget,
    );
  });

  testWidgets('retrying asks the Host again', (tester) async {
    var attempts = 0;
    await _open(tester, loadActivity: () async {
      attempts += 1;
      if (attempts == 1) throw StateError('主机没有回答');
      return HostActivity(moments: [_moment()]);
    });

    await tester.tap(find.byKey(const Key('retry-mission-control-activity')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('你把「小忆」收了起来'), findsOneWidget);
  });

  testWidgets('what is running is counted, and what is not is named', (
    tester,
  ) async {
    await _open(tester,
        listServices: () async => _services(ready: 3, failed: 1));

    expect(find.text('3/4 个服务在正常运行'), findsOneWidget);
    expect(find.textContaining('broken-0 失败'), findsOneWidget);
  });

  testWidgets('services that could not be read do not read as zero services', (
    tester,
  ) async {
    await _open(tester, listServices: () async => throw StateError('读不到'));

    expect(
      find.byKey(const Key('mission-control-services-failure')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mission-control-services')), findsNothing);
  });

  testWidgets(
      'devices are listed by what they are, and a failure to list them shows', (
    tester,
  ) async {
    // Nobody has named devices yet, so the accepted Manifest is what a row can
    // honestly say a device is. An identifier is the fallback, not the name.
    await _open(tester, devices: _devices(['esp-box-3', 'waveshare-amoled']));
    expect(find.textContaining('2 台设备挂在它上面'), findsOneWidget);
    expect(find.textContaining('esp-box-3'), findsOneWidget);

    await _open(tester, devicesError: '设备列表暂时不可用。');
    expect(
      find.byKey(const Key('mission-control-devices-failure')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mission-control-devices')), findsNothing);
  });

  testWidgets('the screen says what it does not know', (tester) async {
    await _open(tester);

    // No presence signal exists anywhere in this system, so this screen must
    // not let anyone read "online" into it.
    final coverage = tester.widget<Text>(
      find.byKey(const Key('mission-control-coverage')),
    );
    expect(coverage.data, contains('设备是否在线不在其中'));
    expect(find.textContaining('在线'), findsOneWidget);
  });

  group('what the Host answered', () {
    test('an act this app has no word for is still an act', () {
      // A Host newer than its client records acts the client cannot phrase, and
      // a history with holes in it is worse than one with an unfamiliar line.
      final moment = HostMoment.fromView(
        ActivityMomentView.fromJson({
          'event_id': 'evt-9',
          'action': 'companion.hummed',
          'subject_type': 'companion',
          'subject_id': 'companion-a',
          'subject_name': '小忆',
          'occurred_at': '2026-08-17T02:14:00Z',
          'outcome': 'success',
          'detail': <String, String>{},
        }),
      );

      expect(moment.kind, HostMomentKind.other);
      // Said plainly, with the Host's own word kept, rather than dressed up as
      // something this app pretends to understand.
      expect(hostMomentSentence(moment), '「小忆」有一次变动（companion.hummed）');
    });

    test('putting one away is one line, not two', () {
      // The Host writes two facts in one transaction because the record has to
      // say both happened. A person did one thing.
      final collapsed = collapseMoments([
        _moment(eventId: 'evt-2', action: 'companion.archived'),
        _moment(eventId: 'evt-1', action: 'companion.retirement_begun'),
      ]);

      expect(collapsed.map((moment) => moment.eventId), ['evt-2']);
    });

    test('a retirement left on its own keeps its line', () {
      // Half-done is a real state, and hiding it would leave a person unable to
      // see the Eidolon that is neither here nor put away.
      final collapsed = collapseMoments([
        _moment(eventId: 'evt-1', action: 'companion.retirement_begun'),
      ]);

      expect(collapsed.map((moment) => moment.eventId), ['evt-1']);
    });

    test('time is told the way someone waiting for a device holds it', () {
      final now = DateTime(2026, 8, 18, 9, 0);
      expect(
        hostMomentTime(DateTime(2026, 8, 18, 10, 14), now: now),
        '今天 10:14',
      );
      expect(
        hostMomentTime(DateTime(2026, 8, 17, 10, 14), now: now),
        '昨天 10:14',
      );
      expect(
        hostMomentTime(DateTime(2026, 8, 12, 4, 1), now: now),
        '8月12日 04:01',
      );
    });
  });

  group('what this app asks the Host for', () {
    /// The body below is the management surface's own answer, field for field.
    ///
    /// Pinned here because the two halves of this feature live in different
    /// repositories: a page tested against a fake proves the page reads an
    /// answer correctly, never that the Host gives that answer. The matching
    /// half is asserted in eidolon_admin's
    /// test_the_history_is_the_signed_in_owners_and_pages_backwards — if either
    /// side renames a field, one of the two fails.
    const wire = {
      'contract_version': '1',
      'moments': [
        {
          'event_id': 'evt-archived',
          'action': 'companion.archived',
          'subject_type': 'companion',
          'subject_id': 'companion-a',
          'subject_name': '小忆',
          'occurred_at': '2026-08-17T10:14:40Z',
          'outcome': 'success',
          'detail': <String, String>{},
        },
      ],
      'next_cursor': '7',
    };

    test('the route, the session and the shape all line up', () async {
      Uri? asked;
      String? sentToken;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          sentToken = request.headers['Authorization'];
          return http.Response.bytes(
            utf8.encode(jsonEncode(wire)),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      final view = await client.fetchActivity(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        limit: 25,
      );
      final activity = HostActivity.fromView(view);

      expect(asked?.path, '/api/management/v1/activity');
      expect(asked?.queryParameters['limit'], '25');
      // No Owner is named by the client: the session already said whose Host
      // this is, and a client that could name another would create a question
      // this boundary would then have to answer.
      expect(asked.toString(), isNot(contains('owner')));
      expect(sentToken, 'Bearer session-token');
      // Stored and sent back, never built: this is a position the Host issued.
      expect(activity.nextCursor, '7');
      expect(hostMomentSentence(activity.moments.single), '你把「小忆」收了起来');
    });

    test('a Host that refuses is not read as a Host with no history', () async {
      final client = ManagementClient(
        httpClient: MockClient(
          (_) async => http.Response('{"detail":"data is down"}', 503),
        ),
      );

      expect(
        () => client.fetchActivity(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
        ),
        throwsA(isA<ManagementRequestException>()),
      );
    });
  });
}
