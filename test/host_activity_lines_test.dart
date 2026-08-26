import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/activity_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
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

/// 改动记录的句子，作为纯逻辑。
///
/// 这些断言原先住在 test/mission_control_test.dart 里，和那块屏的 widget 测试放
/// 在一起。主机动态并进「主机运行状态」之后，屏没了，而这一组和屏无关 —— 它测的
/// 是 activity_models：一件这个版本没有词的事仍然是一件事、收起来算一行不算两行、
/// 时间按等设备的人握着它的方式说。所以它整组搬过来，一个字没改。
void main() {
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
