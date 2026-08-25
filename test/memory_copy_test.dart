import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_copy_page.dart';
import 'package:eidolon_client_mobile/src/management/memory_copy_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 导出 — the copy I take with me.
///
/// The other three memory pages are read correctly by being readable. This one
/// is read correctly by being *complete*, so the tests are about the opposite
/// property from the day list's: nothing may be shortened, nothing dropped, and
/// the two ways a copy can be partial have to be said out loud.

const long = '他喜欢在下午三点喝一杯乌龙茶，不加糖。';

Map<String, dynamic> copyWire({
  int undated = 0,
  bool truncated = false,
  List<Map<String, dynamic>>? records,
}) => {
      'contract_version': '1',
      'taken_at': '2026-08-24T12:31:00+00:00',
      'records': records ??
          [
            {
              'entry_id': 'drawer_1',
              'recorded_at': '2026-08-24T09:05:00+00:00',
              'recorded_at_source': 'occurred_at',
              'wing_id': 'Wing_Life',
              'room_id': '饮食',
              'memory_type': 'preference',
              'value': long,
            },
          ],
      'record_count': records?.length ?? 1,
      'undated_count': undated,
      'truncated': truncated,
    };

MemoryCopyView copy({
  int undated = 0,
  bool truncated = false,
  List<Map<String, dynamic>>? records,
}) =>
    MemoryCopyView.fromJson(
      copyWire(undated: undated, truncated: truncated, records: records),
    );

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  group('the copy client', () {
    test('asks for the whole thing and names no subject', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(copyWire());
        }),
      );

      final answer = await client.fetchMemoryCopy(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
      );

      expect(asked?.path, '/api/management/v1/memory/export');
      expect(asked?.queryParameters, isEmpty);
      expect(answer.records.single.value, long);
    });

    test('can ask for one companion\'s audience, as the library does', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(copyWire());
        }),
      );

      await client.fetchMemoryCopy(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'c-a',
      );

      expect(asked?.queryParameters, {'companion_id': 'c-a'});
    });

    test('decodes the copy as UTF-8', () async {
      // A latin-1 decode would hand someone a saved copy of their own memory
      // with every character of it mangled.
      final client = ManagementClient(
        httpClient: MockClient((_) async => _hostAnswer(copyWire())),
      );

      final answer = await client.fetchMemoryCopy(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
      );

      expect(answer.records.single.value, long);
    });
  });

  group('the copy page', () {
    testWidgets('says how much it holds and when it was taken', (tester) async {
      // Two copies of one memory differ, and a file with no instant cannot be
      // told apart from a stale one.
      await tester.pumpWidget(MaterialApp(home: MemoryCopyPage(copy: copy())));

      expect(find.textContaining('共 1 条'), findsOneWidget);
      expect(find.textContaining('取自 2026-08-24'), findsOneWidget);
    });

    testWidgets('shows a memory whole rather than as a preview', (tester) async {
      // The failure mode of this page: a preview here is data loss that looks
      // like a working read.
      await tester.pumpWidget(MaterialApp(home: MemoryCopyPage(copy: copy())));

      expect(find.text(long), findsOneWidget);
      expect(find.textContaining('…'), findsNothing);
    });

    testWidgets('says out loud when the copy is not all of it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: MemoryCopyPage(copy: copy(truncated: true))),
      );

      expect(find.text('这次没有读完全部记忆，这份副本不完整'), findsOneWidget);
    });

    testWidgets('accounts for what it could not date', (tester) async {
      // They are in the file, at the end. Someone seeing an undated memory in
      // their copy should be able to learn why.
      await tester.pumpWidget(
        MaterialApp(home: MemoryCopyPage(copy: copy(undated: 2))),
      );

      expect(find.text('其中 2 条没有可用的时间，排在最后'), findsOneWidget);
    });

    testWidgets('shows an undated memory as undated rather than filling one in',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryCopyPage(
            copy: copy(
              undated: 1,
              records: [
                {
                  'entry_id': 'drawer_undated',
                  'recorded_at': '',
                  'recorded_at_source': '',
                  'wing_id': '',
                  'room_id': '',
                  'memory_type': '',
                  'value': '说不清什么时候',
                },
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('memory-copy-record-drawer_undated')),
          findsOneWidget);
      expect(find.textContaining('没有可用的时间 '), findsNothing);
      expect(find.text('没有可用的时间'), findsOneWidget);
    });

    testWidgets('hands over the copy itself, not the screen', (tester) async {
      // What a person pastes should be readable by something, so it is the
      // JSON rather than the rendering — and it carries the counts, because a
      // partial copy that lost its own warning is worse than one on screen.
      String? clipped;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryCopyPage(
            copy: copy(truncated: true),
            clipboard: (text) async => clipped = text,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('memory-copy-button')));
      await tester.pumpAndSettle();

      final decoded = jsonDecode(clipped!) as Map<String, dynamic>;
      expect(decoded['record_count'], 1);
      expect(decoded['truncated'], true);
      expect((decoded['records'] as List).single['value'], long);
    });

    testWidgets('offers nothing to press when there is nothing to take',
        (tester) async {
      // A button that copies an empty file and reports success is the fake
      // button these pages exist not to have.
      await tester.pumpWidget(
        MaterialApp(home: MemoryCopyPage(copy: copy(records: []))),
      );

      expect(find.byKey(const Key('memory-copy-button')), findsNothing);
      expect(find.byKey(const Key('memory-copy-empty')), findsOneWidget);
    });
  });

  group('the copy screen', () {
    testWidgets('says the copy was taken away', (tester) async {
      // Pressing a button that gives no sign of having worked is how someone
      // copies their memory four times and trusts none of them.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryCopyScreen(
            load: () async => copy(),
            clipboard: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-copy-button')));
      await tester.pump();

      expect(find.text('已复制到剪贴板'), findsOneWidget);
    });

    testWidgets('a memory that could not be read is not an empty copy',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryCopyScreen(
            load: () => Future.error(
              const ManagementRequestException(
                '读取失败',
                statusCode: 503,
                refusal: Refusal(
                  kind: 'not_running',
                  reason: 'memory is unavailable',
                  retryable: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-copy-error')), findsOneWidget);
      expect(find.byKey(const Key('memory-copy-page')), findsNothing);
    });

    testWidgets('retrying after a refusal asks again', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryCopyScreen(
            load: () async {
              attempts++;
              if (attempts == 1) {
                throw const ManagementRequestException('读取失败', statusCode: 503);
              }
              return copy();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-copy-retry')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.byKey(const Key('memory-copy-page')), findsOneWidget);
    });
  });
}
