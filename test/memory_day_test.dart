import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_day_page.dart';
import 'package:eidolon_client_mobile/src/management/memory_day_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 最近记下的 — what it wrote down, newest first.
///
/// The page most able to look right while being wrong: a person cannot tell a
/// missing entry from an entry that was never recorded. It also held a dead
/// button: 「看更早的」 widened a window whose first page was already full, so
/// it fetched the same page forever. These tests are about reaching every
/// entry, and about what the screen refuses to claim.

Map<String, dynamic> entryWire(String id, String recordedAt, {String? preview}) => {
  'entry_id': id,
  'recorded_at': recordedAt,
  'recorded_at_source': 'occurred_at',
  'wing_id': 'Wing_Life',
  'room_id': '饮食',
  'preview': preview ?? '内容 $id',
};

Map<String, dynamic> dayWire({
  int undated = 0,
  String? nextCursor,
  bool truncated = false,
  List<Map<String, dynamic>>? entries,
}) {
  final rows =
      entries ?? [entryWire('drawer_1', '2026-08-24T09:05:00+00:00', preview: '他早上喝了乌龙茶')];
  return {
    'contract_version': '1',
    'since': '1970-01-01T00:00:00.000',
    'entries': rows,
    'entry_count': rows.length,
    'more_in_window': nextCursor != null,
    if (nextCursor != null) 'next_cursor': nextCursor,
    'undated_count': undated,
    'truncated': truncated,
  };
}

MemoryDayView day({
  int undated = 0,
  String? nextCursor,
  bool truncated = false,
  List<Map<String, dynamic>>? entries,
}) => MemoryDayView.fromJson(
  dayWire(undated: undated, nextCursor: nextCursor, truncated: truncated, entries: entries),
);

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json'},
);

final DateTime _today = DateTime(2026, 8, 24, 12, 30);

Widget _page(MemoryDayView view, {VoidCallback? onLoadMore}) => MaterialApp(
  home: MemoryDayPage(
    entries: view.entries,
    undatedCount: view.undatedCount,
    truncated: view.truncated,
    today: _today,
    onLoadMore: onLoadMore,
  ),
);

void main() {
  group('the entries client', () {
    test('sends the lower bound with its offset, and nothing else unasked', () async {
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
      expect(since, matches(RegExp(r'(Z|[+-]\d{2}:\d{2})$')));
      expect(asked?.queryParameters.keys.toSet(), {'since'});
    });

    test('passes the Host\'s cursor back unread', () async {
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
        since: DateTime(1970),
        cursor: 'opaque-position',
      );

      expect(asked?.queryParameters['cursor'], 'opaque-position');
    });
  });

  group('the page', () {
    testWidgets('groups entries under the day they happened', (tester) async {
      await tester.pumpWidget(
        _page(
          day(
            entries: [
              entryWire('d_today', '2026-08-24T09:05:00'),
              entryWire('d_yesterday', '2026-08-23T20:00:00'),
              entryWire('d_earlier', '2026-08-01T08:00:00'),
            ],
          ),
        ),
      );

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('8月1日'), findsOneWidget);
    });

    testWidgets('keeps the two partial answers apart', (tester) async {
      // Reading on helps with a full page and not with a stopped scan, so the
      // page never merges them into one sentence.
      await tester.pumpWidget(_page(day(truncated: true)));

      expect(find.text('主机这次没有读完全部记忆，这里可能不完整'), findsOneWidget);
      expect(find.byKey(const Key('memory-day-load-more')), findsNothing);
    });

    testWidgets('counts entries that hold no usable time', (tester) async {
      await tester.pumpWidget(_page(day(undated: 2)));

      expect(find.textContaining('另有 2 条没有可用的时间'), findsOneWidget);
    });

    testWidgets('an empty memory is said plainly', (tester) async {
      await tester.pumpWidget(_page(day(entries: [])));

      expect(find.text('还没有记下什么'), findsOneWidget);
    });
  });

  group('the screen', () {
    testWidgets('reads on with the cursor until the Host says there is no more', (
      tester,
    ) async {
      // Three pages, the last without a cursor. Every entry arrives exactly
      // once, and the button goes away when there is nothing more — never a
      // button in front of a page that cannot exist.
      final asked = <String?>[];
      final pages = {
        null: day(
          entries: [entryWire('d1', '2026-08-24T10:00:00'), entryWire('d2', '2026-08-24T09:00:00')],
          nextCursor: 'c1',
        ),
        'c1': day(
          entries: [entryWire('d3', '2026-08-23T10:00:00'), entryWire('d4', '2026-08-23T09:00:00')],
          nextCursor: 'c2',
        ),
        'c2': day(entries: [entryWire('d5', '2026-08-01T10:00:00')]),
      };
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _today,
            load: (since, cursor) async {
              asked.add(cursor);
              expect(since, DateTime(1970));
              return pages[cursor]!;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-day-load-more')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('memory-day-load-more')), 200);
      await tester.tap(find.byKey(const Key('memory-day-load-more')));
      await tester.pumpAndSettle();

      expect(asked, [null, 'c1', 'c2']);
      for (final id in ['d1', 'd2', 'd3', 'd4']) {
        expect(find.byKey(Key('memory-day-entry-$id'), skipOffstage: false), findsOneWidget);
      }
      await tester.scrollUntilVisible(find.byKey(const Key('memory-day-entry-d5')), 200);
      expect(find.byKey(const Key('memory-day-entry-d5')), findsOneWidget);
      expect(find.byKey(const Key('memory-day-load-more'), skipOffstage: false), findsNothing);
    });

    testWidgets('a failed next page keeps what was read and says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _today,
            load: (since, cursor) async {
              if (cursor == null) {
                return day(entries: [entryWire('d1', '2026-08-24T10:00:00')], nextCursor: 'c1');
              }
              throw ManagementRequestException('读取今天记下的超时');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-day-load-more')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-day-entry-d1')), findsOneWidget);
      expect(find.byKey(const Key('memory-day-more-error')), findsOneWidget);
      // Still offered: a timeout is something reading again can fix.
      expect(find.byKey(const Key('memory-day-load-more')), findsOneWidget);
    });

    testWidgets('a memory that could not be read is not shown as empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryDayScreen(
            now: () => _today,
            load: (since, cursor) async => throw ManagementRequestException(
              '读取今天记下的被拒绝',
              statusCode: 503,
              refusal: const Refusal(kind: 'not_configured', retryable: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-day-error')), findsOneWidget);
      expect(find.text('还没有记下什么'), findsNothing);
      // Nothing this phone can do changes a Host that was never configured.
      expect(find.byKey(const Key('memory-day-retry')), findsNothing);
    });
  });
}
