import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/conversations_page.dart';
import 'package:eidolon_client_mobile/src/management/conversations_screen.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/transcript_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 说过的话 / 那次说了什么 — the occasions, and one of them opened.
///
/// The list is not a transcript and must not read like one: a row with a
/// timestamp and no words looks broken, so the row says it can be opened. The
/// transcript is the opposite job — it must read forward, which is the one thing
/// this app reverses, because the Host answers newest-first so "看更早的" can walk
/// back through it.

ConversationView _conversation({
  String id = 'conv-1',
  String? title = '周末计划',
  String started = '2026-08-24T09:00:00Z',
  String? ended = '2026-08-24T09:20:00Z',
}) =>
    ConversationView.fromJson({
      'conversation_id': id,
      'title': title,
      'started_at': started,
      'updated_at': started,
      'ended_at': ended,
    });

TranscriptTurnView _turn({
  String id = 't-1',
  String? finished = '2026-08-24T09:00:09Z',
  List<Map<String, dynamic>>? messages,
}) =>
    TranscriptTurnView.fromJson({
      'turn_id': id,
      'started_at': '2026-08-24T09:00:00Z',
      'finished_at': finished,
      'status': 'ok',
      'messages': messages ??
          [
            {'role': 'user', 'text': '周末去哪'},
            {'role': 'assistant', 'text': '去公园吧'},
          ],
    });

TranscriptView _transcript({List<TranscriptTurnView>? turns, String? cursor}) =>
    TranscriptView(
      conversationId: 'conv-1',
      turns: turns ?? [_turn()],
      nextCursor: cursor,
    );

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  group('the transcript client', () {
    test('asks the conversation route and sends only what it was given', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer({
            'contract_version': '1',
            'conversation_id': 'conv-1',
            'turns': const [],
            'next_cursor': null,
          });
        }),
      );

      await client.fetchTranscript(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
        conversationId: 'conv-1',
        cursor: '2026-08-24T09:00:00Z',
      );

      expect(
        asked?.path,
        '/api/management/v1/companions/companion-a/conversations/conv-1/turns',
      );
      expect(asked?.queryParameters, {'cursor': '2026-08-24T09:00:00Z'});
    });

    test('escapes both ids into the path', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer({
            'contract_version': '1',
            'conversation_id': 'x',
            'turns': const [],
          });
        }),
      );

      await client.fetchTranscript(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'c/../a',
        conversationId: 'conv/../1',
      );

      expect(asked.toString(), contains('/companions/c%2F..%2Fa/'));
      expect(asked.toString(), contains('/conversations/conv%2F..%2F1/turns'));
    });
  });

  group('the conversations list', () {
    testWidgets('says when, and that a row opens', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(
            conversations: [_conversation()],
            onOpen: (_) {},
          ),
        ),
      );

      expect(find.text('周末计划'), findsOneWidget);
      expect(find.textContaining('2026-08-24 '), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('an open conversation says so rather than showing a false end',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(conversations: [_conversation(ended: null)]),
        ),
      );

      expect(find.textContaining('还在继续'), findsOneWidget);
    });

    testWidgets('an unnamed conversation is not named by this screen',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(conversations: [_conversation(title: '')]),
        ),
      );

      expect(find.text('没有标题的一次'), findsOneWidget);
    });

    testWidgets('rows do not open when nothing is behind them', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ConversationsPage(conversations: [_conversation()])),
      );

      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('a quiet history is said plainly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ConversationsPage(conversations: [])),
      );

      expect(find.byKey(const Key('conversations-empty')), findsOneWidget);
    });
  });

  group('the transcript', () {
    testWidgets('reads forward, mine on one side and its on the other',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: TranscriptPage(turns: [_turn()])));

      expect(find.text('周末去哪'), findsOneWidget);
      expect(find.text('去公园吧'), findsOneWidget);
    });

    testWidgets('a turn that never finished says so', (tester) async {
      // What a dropped connection looks like afterwards, and worth seeing.
      await tester.pumpWidget(
        MaterialApp(home: TranscriptPage(turns: [_turn(finished: null)])),
      );

      expect(find.byKey(const Key('turn-unfinished-t-1')), findsOneWidget);
      expect(find.text('这一轮没有说完'), findsOneWidget);
    });

    testWidgets('a conversation with nothing said is not an error',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: TranscriptPage(turns: [])));

      expect(find.byKey(const Key('transcript-empty')), findsOneWidget);
    });
  });

  group('the screen', () {
    testWidgets('opening a row shows what was said', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsScreen(
            load: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [_conversation()],
            ),
            loadTranscript: (_, __) async => _transcript(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('conversation-conv-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('transcript-page')), findsOneWidget);
      expect(find.text('周末去哪'), findsOneWidget);
    });

    testWidgets('earlier turns arrive above the ones already read',
        (tester) async {
      // The Host answers newest first; a conversation reads forward. Getting
      // this backwards would put yesterday's words after today's.
      final pages = <TranscriptView>[
        _transcript(turns: [_turn(id: 't-2')], cursor: 'earlier'),
        _transcript(turns: [_turn(id: 't-1')]),
      ];
      var asked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsScreen(
            load: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [_conversation()],
            ),
            loadTranscript: (_, cursor) async => pages[asked++],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation-conv-1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('transcript-load-earlier')));
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(find.byKey(const Key('transcript-list')));
      final keys = (list.childrenDelegate as SliverChildListDelegate)
          .children
          .map((child) => child.key)
          .whereType<Key>()
          .map((key) => key.toString())
          .toList();
      // t-1 is older, so its messages come before t-2's.
      expect(
        keys.indexWhere((key) => key.contains('message-t-1')) <
            keys.indexWhere((key) => key.contains('message-t-2')),
        isTrue,
        reason: keys.toString(),
      );
    });

    testWidgets('a history it could not read is not an empty history',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsScreen(
            load: (_) => Future.error(
              const ManagementRequestException('读取失败', statusCode: 503),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('conversations-error')), findsOneWidget);
      expect(find.byKey(const Key('conversations-empty')), findsNothing);
    });

    testWidgets('a conversation that is gone says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsScreen(
            load: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [_conversation()],
            ),
            loadTranscript: (_, __) => Future.error(
              const ManagementRequestException('没有', statusCode: 404),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation-conv-1')));
      await tester.pumpAndSettle();

      expect(find.text('找不到这次对话了'), findsOneWidget);
    });
  });
}
