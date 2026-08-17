import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/activity_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/mission_control_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HostMoment _moment({
  String eventId = 'evt-1',
  HostMomentKind kind = HostMomentKind.deviceAccepted,
  HostMomentActor actor = HostMomentActor.owner,
  String deviceName = 'atk-dnesp32s3',
  String deviceKind = 'atk-dnesp32s3',
  String reason = '',
  DateTime? at,
}) =>
    HostMoment(
      eventId: eventId,
      occurredAt: at ?? DateTime.utc(2026, 8, 17, 2, 14),
      kind: kind,
      actor: actor,
      deviceId: '10:51:db:7e:24:44',
      deviceName: deviceName,
      deviceKind: deviceKind,
      reason: reason,
      eventType: 'eidolon.device.approved.v1',
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

MountedDeviceInventory _devices(List<String> names) => MountedDeviceInventory(
      devices: [
        for (final name in names)
          MountedDevice(
            deviceId: 'device-$name',
            displayName: name,
            deviceKind: 'esp-box-3',
            admissionState: MountedDeviceAdmissionState.mounted,
            mount: MountedDeviceMount(
              revision: 1,
              attachedCompanionId: null,
              updatedAt: DateTime.utc(2026, 8, 17),
            ),
          ),
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
                  coverage: 'device-lifecycle',
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
        coverage: 'device-lifecycle',
        moments: [
          _moment(eventId: 'evt-2', kind: HostMomentKind.deviceKnocked,
              actor: HostMomentActor.device),
          _moment(),
        ],
      ),
    );

    expect(find.text('atk-dnesp32s3 敲了门'), findsOneWidget);
    expect(find.text('你接受了 atk-dnesp32s3'), findsOneWidget);
    // The Hub's own wording never reaches the person.
    expect(find.textContaining('eidolon.device.'), findsNothing);
  });

  testWidgets('a device the Host cannot name is not named by its identifier', (
    tester,
  ) async {
    await _open(
      tester,
      loadActivity: () async => HostActivity(
        coverage: 'device-lifecycle',
        moments: [_moment(deviceName: '', deviceKind: '')],
      ),
    );

    expect(find.text('你接受了 一台设备'), findsOneWidget);
    // The identifier is still reachable, in the technical line underneath.
    expect(find.textContaining('10:51:db:7e:24:44'), findsOneWidget);
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
          const HostActivity(coverage: 'device-lifecycle', moments: []),
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
      return HostActivity(coverage: 'device-lifecycle', moments: [_moment()]);
    });

    await tester.tap(find.byKey(const Key('retry-mission-control-activity')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('你接受了 atk-dnesp32s3'), findsOneWidget);
  });

  testWidgets('what is running is counted, and what is not is named', (
    tester,
  ) async {
    await _open(tester, listServices: () async => _services(ready: 3, failed: 1));

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

  testWidgets('devices are listed by name, and a failure to list them shows', (
    tester,
  ) async {
    await _open(tester, devices: _devices(['客厅的 Box-3', '书房的板子']));
    expect(find.textContaining('2 台设备挂在它上面'), findsOneWidget);
    expect(find.textContaining('客厅的 Box-3'), findsOneWidget);

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
    expect(coverage.data, contains('不记录设备是否在线'));
    expect(find.textContaining('在线'), findsOneWidget);
  });

  group('what the Host answered', () {
    test('a record without a time or a device is refused', () {
      expect(
        () => HostMoment.fromJson({
          'event_id': 'evt-1',
          'device_id': 'device-1',
          'occurred_at': 'not a time',
        }),
        throwsFormatException,
      );
      expect(
        () => HostMoment.fromJson({
          'event_id': 'evt-1',
          'occurred_at': '2026-08-17T02:14:00Z',
        }),
        throwsFormatException,
      );
      expect(() => HostActivity.fromJson({'moments': []}), throwsFormatException);
    });

    test('an act this app has no word for is still an act', () {
      final moment = HostMoment.fromJson({
        'event_id': 'evt-9',
        'occurred_at': '2026-08-17T02:14:00Z',
        'kind': 'device-hummed',
        'actor': 'quartermaster',
        'device_id': 'device-1',
        'device_name': '客厅的 Box-3',
      });

      expect(moment.kind, HostMomentKind.other);
      expect(moment.actor, HostMomentActor.host);
      expect(hostMomentSentence(moment), '客厅的 Box-3 有一次变动');
    });

    test('an act somebody else took is not attributed to the Owner', () {
      final moment = _moment(
        kind: HostMomentKind.deviceRemoved,
        actor: HostMomentActor.host,
      );

      expect(hostMomentSentence(moment), 'atk-dnesp32s3 被移除了');
      expect(
        hostMomentSentence(_moment(kind: HostMomentKind.deviceRemoved)),
        '你移除了 atk-dnesp32s3',
      );
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
    /// The body below is the Local API's own answer, field for field.
    ///
    /// Pinned here because the two halves of this feature live in different
    /// repositories: a page tested against a fake proves the page reads an
    /// answer correctly, never that the Host gives that answer. The matching
    /// half is asserted in eidolon_admin's
    /// test_an_owner_can_see_what_happened_to_their_devices — if either side
    /// renames a field, one of the two fails.
    const wire = {
      'contract_version': '1',
      'coverage': 'device-lifecycle',
      'moments': [
        {
          'event_id': 'evt-approved',
          'occurred_at': '2026-08-17T10:14:40Z',
          'kind': 'device-accepted',
          'actor': 'owner',
          'device_id': '10:51:db:7e:24:44',
          'device_name': 'atk-dnesp32s3',
          'device_kind': 'atk-dnesp32s3',
          'reason': '',
          'event_type': 'eidolon.device.approved.v1',
        },
      ],
    };

    test('the route, the session and the shape all line up', () async {
      Uri? asked;
      String? sentToken;
      final client = LocalApiClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          sentToken = request.headers['authorization'];
          return http.Response(
            jsonEncode(wire),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      final activity = await client.fetchActivity(
        'https://192.168.1.26:9002',
        accessToken: 'session-token',
        limit: 25,
      );

      expect(asked?.path, '/api/local/v1/activity');
      expect(asked?.queryParameters['limit'], '25');
      // No Owner is named by the client: the session already said whose Host
      // this is, and a client that could name another would create a question
      // this boundary would then have to answer.
      expect(asked.toString(), isNot(contains('owner')));
      expect(sentToken, 'Bearer session-token');
      expect(activity.coverage, 'device-lifecycle');
      expect(hostMomentSentence(activity.moments.single), '你接受了 atk-dnesp32s3');
    });

    test('a Host that refuses is not read as a Host with no history', () async {
      final client = LocalApiClient(
        httpClient: MockClient(
          (_) async => http.Response('{"detail":"hub is down"}', 503),
        ),
      );

      expect(
        () => client.fetchActivity(
          'https://192.168.1.26:9002',
          accessToken: 'session-token',
        ),
        throwsA(isA<LocalApiRequestException>()),
      );
    });
  });
}
