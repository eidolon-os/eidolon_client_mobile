import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/companion_detail_screen.dart';
import 'package:eidolon_client_mobile/src/management/companion_roster_page.dart';
import 'package:eidolon_client_mobile/src/management/companion_roster_screen.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A roster page exactly as the Host sends it.
Map<String, dynamic> rosterWire({
  String? defaultCompanionId = 'companion-a',
  String? nextCursor,
  List<Map<String, dynamic>>? companions,
}) =>
    {
      'contract_version': '1',
      'default_companion_id': defaultCompanionId,
      'companions': companions ??
          [
            {
              'companion_id': 'companion-a',
              'display_name': '小忆',
              'kind': 'standard',
              'lifecycle_state': 'active',
              'revision': 2,
              'created_at': '2026-08-24T09:30:00+00:00',
              'updated_at': '2026-08-24T09:30:00+00:00',
            },
            {
              'companion_id': 'companion-b',
              'display_name': '',
              'kind': 'standard',
              'lifecycle_state': 'archived',
              'revision': 5,
              'created_at': '2026-08-24T09:31:00+00:00',
              'updated_at': '2026-08-24T09:40:00+00:00',
            },
          ],
      'next_cursor': nextCursor,
    };

CompanionRosterView roster({
  String? defaultCompanionId = 'companion-a',
  String? nextCursor,
  List<Map<String, dynamic>>? companions,
}) =>
    CompanionRosterView.fromJson(
      rosterWire(
        defaultCompanionId: defaultCompanionId,
        nextCursor: nextCursor,
        companions: companions,
      ),
    );

/// A response shaped the way a real Host sends one: UTF-8 bytes, and a
/// content-type with no charset parameter. Constructed from bytes rather than
/// from a String so the test does not depend on how the http package guesses an
/// encoding — the same reason the client reads bodyBytes.
http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  group('the management client', () {
    test('asks the generated path with the session, naming no Owner', () async {
      Uri? asked;
      String? sentToken;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          sentToken = request.headers['authorization'];
          return _hostAnswer(rosterWire());
        }),
      );

      final page = await client.fetchRoster(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
      );

      expect(asked?.path, '/api/management/v1/companions');
      // No Owner is named by the client, and there is no parameter for one:
      // the session already said whose Host this is.
      expect(asked?.queryParameters.containsKey('owner_id'), isFalse);
      expect(sentToken, 'Bearer session-token');
      expect(page.companions, hasLength(2));
    });

    test('carries a cursor back without reading it', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(rosterWire());
        }),
      );

      await client.fetchRoster(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        cursor: 'opaque-from-the-host',
      );

      expect(asked?.queryParameters['cursor'], 'opaque-from-the-host');
    });

    test('a name in Chinese survives the wire', () async {
      // The Host sends UTF-8 with no charset in the header. Decoding by header
      // would fall back to latin-1 here and mangle the name silently, since
      // latin-1 decoding never fails on any byte.
      final client = ManagementClient(
        httpClient: MockClient((_) async => _hostAnswer(rosterWire())),
      );

      final page = await client.fetchRoster(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
      );

      expect(page.companions.first.displayName, '小忆');
    });

    test('a Host with no Owner is not read as an Owner with no Eidolons',
        () async {
      // Different screens: one offers a way to make an Eidolon, the other
      // cannot until the Host is provisioned. Folding them together sends a
      // person to a button that cannot work.
      final client = ManagementClient(
        httpClient: MockClient(
          (_) async => http.Response('{"detail":"no Owner yet"}', 409),
        ),
      );

      await expectLater(
        client.fetchRoster(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
        ),
        throwsA(
          isA<ManagementRequestException>()
              .having((e) => e.hostHasNoOwner, 'hostHasNoOwner', isTrue)
              .having((e) => e.reason, 'reason', 'no Owner yet'),
        ),
      );
    });

    test('a refusal is a refusal, not an empty roster', () async {
      final client = ManagementClient(
        httpClient: MockClient(
          (_) async => http.Response('{"detail":"data authority is down"}', 503),
        ),
      );

      await expectLater(
        client.fetchRoster(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
        ),
        throwsA(isA<ManagementRequestException>()),
      );
    });

    test('a capability this Host never mentioned is not permission', () async {
      final context = ManagementContextView.fromJson({
        'contract_version': '1',
        'owner': {'owner_id': 'owner-1', 'display_name': 'Manson', 'revision': 3},
        'default_companion_id': 'companion-a',
        'capabilities': {'companion.read': true, 'companion.create': false},
        'limits': {'max_active_companions': null},
      });

      expect(hostCan(context, 'companion.read'), isTrue);
      expect(hostCan(context, 'companion.create'), isFalse);
      // Absent, because this app is the newer half. Same answer as false for
      // the button, and a different diagnosis for a person reading logs.
      expect(hostCan(context, 'memory.export'), isFalse);
      expect(context.capabilities.containsKey('memory.export'), isFalse);
    });

    test('a limit the Host left null is not replaced with a number', () async {
      final context = ManagementContextView.fromJson({
        'contract_version': '1',
        'owner': {'owner_id': 'owner-1', 'display_name': 'Manson', 'revision': 3},
        'default_companion_id': null,
        'capabilities': const <String, bool>{},
        'limits': {'max_active_companions': null},
      });

      expect(context.limits['max_active_companions'], isNull);
      expect(context.defaultCompanionId, isNull);
    });
  });

  group('the roster screen', () {
    testWidgets('a Host that refused is not shown as an empty roster',
        (tester) async {
      // The lie this prevents: "you have no Eidolons", told to a person at the
      // exact moment they need to know the Host would not answer.
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterScreen(
            load: ({String? cursor}) => Future.error(
              const ManagementRequestException(
                '读取失败',
                statusCode: 503,
                reason: 'data authority is down',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('roster-error')), findsOneWidget);
      expect(find.byKey(const Key('roster-empty')), findsNothing);
      expect(find.textContaining('data authority is down'), findsOneWidget);
    });

    testWidgets('a Host with no Owner is told apart from an Owner with none',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterScreen(
            load: ({String? cursor}) => Future.error(
              const ManagementRequestException('读取失败', statusCode: 409),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('这台主机还没有主人，先完成设置'), findsOneWidget);
    });

    testWidgets('asking for more appends rather than replacing', (tester) async {
      final pages = <Map<String, dynamic>>[
        rosterWire(
          nextCursor: 'page-2',
          companions: [
            {
              'companion_id': 'companion-a',
              'display_name': '小忆',
              'kind': 'standard',
              'lifecycle_state': 'active',
              'revision': 2,
              'created_at': '2026-08-24T09:30:00+00:00',
              'updated_at': '2026-08-24T09:30:00+00:00',
            },
          ],
        ),
        rosterWire(
          companions: [
            {
              'companion_id': 'companion-c',
              'display_name': '阿力',
              'kind': 'standard',
              'lifecycle_state': 'active',
              'revision': 1,
              'created_at': '2026-08-24T09:32:00+00:00',
              'updated_at': '2026-08-24T09:32:00+00:00',
            },
          ],
        ),
      ];
      var asked = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterScreen(
            load: ({String? cursor}) async =>
                CompanionRosterView.fromJson(pages[asked++]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roster-load-more')));
      await tester.pumpAndSettle();

      // What a person was already reading must not vanish because they asked
      // to see more.
      expect(find.byKey(const Key('roster-row-companion-a')), findsOneWidget);
      expect(find.byKey(const Key('roster-row-companion-c')), findsOneWidget);
      expect(find.byKey(const Key('roster-load-more')), findsNothing);
    });

    testWidgets('retrying after a refusal asks again', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterScreen(
            load: ({String? cursor}) async {
              attempts++;
              if (attempts == 1) {
                throw const ManagementRequestException('读取失败', statusCode: 503);
              }
              return CompanionRosterView.fromJson(rosterWire());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roster-retry')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.byKey(const Key('roster-row-companion-a')), findsOneWidget);
    });
  });

  detailTests();

  group('the roster page', () {
    testWidgets('marks the default once, from the page and not a row',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: CompanionRosterPage(roster: roster())),
      );

      expect(find.byKey(const Key('roster-row-companion-a')), findsOneWidget);
      expect(find.byKey(const Key('roster-row-companion-b')), findsOneWidget);
      expect(find.byKey(const Key('roster-default-badge')), findsOneWidget);
    });

    testWidgets('shows no default when the Owner has none', (tester) async {
      // Real state — everything archived, or the only one is a guard. The page
      // must not promote a row to fill the gap.
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterPage(roster: roster(defaultCompanionId: null)),
        ),
      );

      expect(find.byKey(const Key('roster-default-badge')), findsNothing);
      expect(find.byKey(const Key('roster-row-companion-a')), findsOneWidget);
    });

    testWidgets('an archived Eidolon is shown, and says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: CompanionRosterPage(roster: roster())),
      );

      expect(find.text('你已归档，记忆还留着'), findsOneWidget);
      expect(find.text('在这台 Host 上运行'), findsOneWidget);
    });

    testWidgets('an unnamed Eidolon is not called by its identifier',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: CompanionRosterPage(roster: roster())),
      );

      expect(find.text('还没有名字的 Eidolon'), findsOneWidget);
      expect(find.text('companion-b'), findsNothing);
    });

    testWidgets('a state this version does not know still renders a row',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterPage(
            roster: roster(
              companions: [
                {
                  'companion_id': 'companion-z',
                  'display_name': '未来',
                  'kind': 'a-kind-from-a-later-release',
                  'lifecycle_state': 'hibernating',
                  'revision': 1,
                  'created_at': '2026-08-24T09:30:00+00:00',
                  'updated_at': '2026-08-24T09:30:00+00:00',
                },
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('roster-row-companion-z')), findsOneWidget);
      expect(find.text('这台 Host 说的状态，这个版本还不认识'), findsOneWidget);
      expect(find.text('hibernating'), findsNothing);
    });

    testWidgets('an Owner with no Eidolons is told plainly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterPage(
            roster: roster(defaultCompanionId: null, companions: const []),
          ),
        ),
      );

      expect(find.byKey(const Key('roster-empty')), findsOneWidget);
      expect(find.byKey(const Key('roster-list')), findsNothing);
    });

    testWidgets('another page is offered only when the Host said there is one',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: CompanionRosterPage(roster: roster())),
      );
      expect(find.byKey(const Key('roster-load-more')), findsNothing);

      var asked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterPage(
            roster: roster(nextCursor: 'page-2'),
            onLoadMore: () => asked++,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('roster-load-more')));
      expect(asked, 1);
    });
  });
}


CompanionDetailView detail({bool isDefault = true, String kind = 'standard'}) =>
    CompanionDetailView.fromJson({
      'contract_version': '1',
      'companion_id': 'companion-a',
      'display_name': '小忆',
      'kind': kind,
      'lifecycle_state': 'active',
      'revision': 2,
      'is_default': isDefault,
    });

/// Opening one from the list.
void detailTests() {
  group('one Eidolon, opened', () {
    testWidgets('a row opens the Eidolon it names', (tester) async {
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterScreen(
            load: ({String? cursor}) async =>
                CompanionRosterView.fromJson(rosterWire()),
            openCompanion: (companionId) async {
              opened = companionId;
              return detail();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roster-row-companion-b')));
      await tester.pumpAndSettle();

      expect(opened, 'companion-b');
      expect(find.byKey(const Key('companion-detail-screen')), findsOneWidget);
    });

    testWidgets('rows do not pretend to open when nothing can load them',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionRosterScreen(
            load: ({String? cursor}) async =>
                CompanionRosterView.fromJson(rosterWire()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('roster-row-companion-a')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('companion-detail-screen')), findsNothing);
    });

    testWidgets('the default badge comes from the Host, not from the list',
        (tester) async {
      // The roster compares against a page-level pointer; this screen shows a
      // comparison the Host made. Both read the same one field, so they cannot
      // disagree — and the detail screen must not infer it from the row it was
      // opened from.
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'companion-a',
            load: (_) async => detail(isDefault: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('detail-default-badge')), findsNothing);
    });

    testWidgets('a kind this version does not know is still described',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'companion-a',
            load: (_) async => detail(kind: 'a-kind-from-a-later-release'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('这台 Host 上的另一类 Eidolon'), findsOneWidget);
      expect(find.text('a-kind-from-a-later-release'), findsNothing);
    });

    testWidgets('an Eidolon that is not yours reads as absent', (tester) async {
      // Not "you may not see it": that would confirm the id exists, turning
      // this screen into a way to test identifiers.
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'someone-elses',
            load: (_) => Future.error(
              const ManagementRequestException('读取失败', statusCode: 404),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('这台主机上没有这个 Eidolon'), findsOneWidget);
    });
  });
}
