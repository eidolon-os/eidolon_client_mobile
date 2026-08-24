import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_day_page.dart';
import 'package:eidolon_client_mobile/src/management/memory_day_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 今日 — what it wrote down today.
///
/// The page most able to look right while being wrong: a person cannot tell a
/// missing entry from an entry that was never recorded. So these tests are about
/// the window (whose day is it?) and about what the screen refuses to claim.

Map<String, dynamic> dayWire({
  String since = '2026-08-24T00:00:00.000',
  int undated = 0,
  bool moreInWindow = false,
  bool truncated = false,
  List<Map<String, dynamic>>? entries,
}) => {
      'contract_version': '1',
      'since': since,
      'entries': entries ??
          [
            {
              'entry_id': 'drawer_1',
              'recorded_at': '2026-08-24T09:05:00+00:00',
              'recorded_at_source': 'occurred_at',
              'wing_id': 'Wing_Life',
              'room_id': '饮食',
              'preview': '他早上喝了乌龙茶',
            },
          ],
      'entry_count': entries?.length ?? 1,
      'more_in_window': moreInWindow,
      'undated_count': undated,
      'truncated': truncated,
    };

MemoryDayView day({
  int undated = 0,
  bool moreInWindow = false,
  bool truncated = false,
  List<Map<String, dynamic>>? entries,
}) =>
    MemoryDayView.fromJson(
      dayWire(
        undated: undated,
        moreInWindow: moreInWindow,
        truncated: truncated,
        entries: entries,
      ),
    );

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

final DateTime _noon = DateTime(2026, 8, 24, 12, 30);

void main() {
  group('the day client', () {
    test('sends the window with its offset', () async {
      // The Host compares instants. An offset is what lets it place this one
      // without knowing where the person is.
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(dayWire());
        }),
      );

      await client.fetchMemoryEntries(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        since: DateTime(2026, 8, 24),
      );

      expect(asked?.path, '/api/management/v1/memory/entries');
      final since = asked!.queryParameters['since']!;
      expect(since.startsWith('2026-08-24T00:00:00'), isTrue);
      expect(asked?.queryParameters.containsKey('owner_id'), isFalse);
    });

    test('sends no limit or audience when none was named', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(dayWire());
        }),
      );

      await client.fetchMemoryEntries(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        since: DateTime(2026, 8, 24),
      );

      expect(asked?.queryParameters.keys.toSet(), {'since'});
    });
  });

  group('the day page', () {
    testWidgets('says which window it is answering for', (tester) async {
      // A list with no window cannot be told apart from an answer to a
      // different question — which matters most when it is empty.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(day: day(), dayStartedAt: DateTime(2026, 8, 24)),
        ),
      );

      expect(find.textContaining('从 00:00 起，记下 1 条'), findsOneWidget);
    });

    testWidgets('keeps the two partial answers apart', (tester) async {
      // Asking again helps with a full page and not with a stopped scan, so the
      // page never merges them into one sentence.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(
            day: day(truncated: true),
            dayStartedAt: DateTime(2026, 8, 24),
          ),
        ),
      );

      expect(find.text('这次没有读完全部记忆，可能漏了更早的'), findsOneWidget);
      expect(find.byKey(const Key('memory-day-load-more')), findsNothing);
    });

    testWidgets('offers more only when the page ended inside the window',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(
            day: day(moreInWindow: true),
            dayStartedAt: DateTime(2026, 8, 24),
            onLoadMore: () {},
          ),
        ),
      );

      expect(find.byKey(const Key('memory-day-load-more')), findsOneWidget);
    });

    testWidgets('counts entries that hold no usable time', (tester) async {
      // Someone whose entry never shows up in any day should be able to learn
      // that this is why.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(
            day: day(undated: 2),
            dayStartedAt: DateTime(2026, 8, 24),
          ),
        ),
      );

      expect(find.text('另有 2 条没有可用的时间，不在任何一天的清单里'), findsOneWidget);
    });

    testWidgets('a quiet day is said plainly, not drawn as a failure',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(
            day: day(entries: []),
            dayStartedAt: DateTime(2026, 8, 24),
          ),
        ),
      );

      expect(find.byKey(const Key('memory-day-empty')), findsOneWidget);
      expect(find.text('这段时间没有记下什么'), findsOneWidget);
    });

    testWidgets('a quiet day still reports what is undated', (tester) async {
      // Otherwise "nothing today" and "two things I cannot place" look the same.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(
            day: day(entries: [], undated: 2),
            dayStartedAt: DateTime(2026, 8, 24),
          ),
        ),
      );

      expect(find.textContaining('另有 2 条'), findsOneWidget);
    });

    testWidgets('shows an entry at the time it is about, in local terms',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(day: day(), dayStartedAt: DateTime(2026, 8, 24)),
        ),
      );

      expect(find.byKey(const Key('memory-day-entry-drawer_1')), findsOneWidget);
      expect(find.text('他早上喝了乌龙茶'), findsOneWidget);
      // The room is context, not a category id.
      expect(find.textContaining('饮食'), findsOneWidget);
    });

    testWidgets('an unparseable time is shown rather than invented',
        (tester) async {
      // Hiding the entry would lose it; inventing a time would file it wrongly.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayPage(
            day: day(
              entries: [
                {
                  'entry_id': 'drawer_odd',
                  'recorded_at': 'sometime',
                  'recorded_at_source': 'unknown',
                  'wing_id': '',
                  'room_id': '',
                  'preview': '说不清什么时候',
                },
              ],
            ),
            dayStartedAt: DateTime(2026, 8, 24),
          ),
        ),
      );

      expect(find.byKey(const Key('memory-day-entry-drawer_odd')), findsOneWidget);
      expect(find.textContaining('sometime'), findsOneWidget);
    });
  });

  group('the day screen', () {
    testWidgets('asks from local midnight, which the Host cannot compute',
        (tester) async {
      // A day computed on the Host would be wrong by up to a day and would not
      // say so; this is the one piece of judgement the client owns.
      DateTime? asked;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _noon,
            load: (since) async {
              asked = since;
              return day();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(asked, DateTime(2026, 8, 24));
      expect(asked!.isUtc, isFalse);
    });

    testWidgets('looking further back widens the window by a day',
        (tester) async {
      // Not an opaque cursor: someone asking for more of today wants the
      // morning, and then yesterday.
      final windows = <DateTime>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _noon,
            load: (since) async {
              windows.add(since);
              return day(moreInWindow: true);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-day-load-more')));
      await tester.pumpAndSettle();

      expect(windows, [DateTime(2026, 8, 24), DateTime(2026, 8, 23)]);
    });

    testWidgets('does not offer to widen when the page held the window',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(now: () => _noon, load: (_) async => day()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-day-load-more')), findsNothing);
    });

    testWidgets('a memory that could not be read is not a quiet day',
        (tester) async {
      // The two are indistinguishable to a person, and only one is a reason to
      // worry.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _noon,
            load: (_) => Future.error(
              const ManagementRequestException(
                '读取失败',
                statusCode: 503,
                reason: 'memory is unavailable',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-day-error')), findsOneWidget);
      expect(find.byKey(const Key('memory-day-empty')), findsNothing);
    });

    testWidgets('retrying after a refusal asks again', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _noon,
            load: (_) async {
              attempts++;
              if (attempts == 1) {
                throw const ManagementRequestException('读取失败', statusCode: 503);
              }
              return day();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-day-retry')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.byKey(const Key('memory-day-entry-drawer_1')), findsOneWidget);
    });
  });
}
