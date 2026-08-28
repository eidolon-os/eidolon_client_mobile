import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/conversation_history_page.dart';
import 'package:eidolon_client_mobile/src/management/conversation_history_screen.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ConversationView _conversation({
  required String id,
  String started = '2026-08-24T09:00:00Z',
}) =>
    ConversationView.fromJson({
      'conversation_id': id,
      'started_at': started,
      'updated_at': started,
      'ended_at': null,
    });

TranscriptTurnView _turn({
  required String id,
  String started = '2026-08-24T09:00:00Z',
  String? finished = '2026-08-24T09:00:09Z',
  String user = '周末去哪',
  String assistant = '去公园吧',
}) =>
    TranscriptTurnView.fromJson({
      'turn_id': id,
      'started_at': started,
      'finished_at': finished,
      'status': 'ok',
      'messages': [
        {'role': 'user', 'text': user},
        {'role': 'assistant', 'text': assistant},
      ],
    });

TranscriptView _transcript({
  required String conversationId,
  required List<TranscriptTurnView> turns,
  String? cursor,
}) =>
    TranscriptView(
      conversationId: conversationId,
      turns: turns,
      nextCursor: cursor,
    );

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  group('the transcript client', () {
    test(
      'keeps the Host conversation id as an internal route boundary',
      () async {
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
      },
    );

    test('escapes both internal ids into the path', () async {
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

  group('the continuous history page', () {
    testWidgets('shows words directly without a conversation-status layer', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryPage(turns: [_turn(id: 'turn-1')]),
        ),
      );

      expect(find.text('对话记录'), findsOneWidget);
      expect(find.text('周末去哪'), findsOneWidget);
      expect(find.text('去公园吧'), findsOneWidget);
      expect(find.text('2026年8月24日'), findsOneWidget);
      expect(find.text('还在继续'), findsNothing);
      expect(find.text('已结束'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('keeps a genuine unfinished turn visible', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryPage(
            turns: [_turn(id: 'turn-1', finished: null)],
          ),
        ),
      );

      expect(find.text('这一轮没有说完'), findsOneWidget);
    });

    testWidgets('a quiet history is said plainly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ConversationHistoryPage(turns: [])),
      );

      expect(
        find.byKey(const Key('conversation-history-empty')),
        findsOneWidget,
      );
      expect(find.text('还没有说过话'), findsOneWidget);
    });

    testWidgets('an empty page can still continue into earlier records', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryPage(
            turns: const [],
            onLoadEarlier: () {},
          ),
        ),
      );

      expect(
        find.byKey(const Key('conversation-history-load-earlier')),
        findsOneWidget,
      );
    });
  });

  group('the continuous history screen', () {
    testWidgets('opens the newest words without asking for another choice', (
      tester,
    ) async {
      final transcriptsAsked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryScreen(
            loadConversations: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [_conversation(id: 'conv-new')],
            ),
            loadTranscript: (conversationId, _) async {
              transcriptsAsked.add(conversationId);
              return _transcript(
                conversationId: conversationId,
                turns: [_turn(id: 'turn-new')],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(transcriptsAsked, ['conv-new']);
      expect(
        find.byKey(const Key('conversation-history-page')),
        findsOneWidget,
      );
      expect(find.text('周末去哪'), findsOneWidget);
      expect(find.text('还在继续'), findsNothing);
    });

    testWidgets('continues earlier within the same internal conversation', (
      tester,
    ) async {
      var transcriptPage = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryScreen(
            loadConversations: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [_conversation(id: 'conv-1')],
            ),
            loadTranscript: (conversationId, cursor) async {
              transcriptPage += 1;
              return transcriptPage == 1
                  ? _transcript(
                      conversationId: conversationId,
                      turns: [
                        _turn(
                          id: 'turn-new',
                          started: '2026-08-24T10:00:00Z',
                          user: '新的',
                        ),
                      ],
                      cursor: 'earlier-turns',
                    )
                  : _transcript(
                      conversationId: conversationId,
                      turns: [
                        _turn(
                          id: 'turn-old',
                          started: '2026-08-24T08:00:00Z',
                          user: '旧的',
                        ),
                      ],
                    );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('conversation-history-load-earlier')),
      );
      await tester.pumpAndSettle();

      final oldTop = tester.getTopLeft(find.text('旧的')).dy;
      final newTop = tester.getTopLeft(find.text('新的')).dy;
      expect(oldTop, lessThan(newTop));
      expect(transcriptPage, 2);
    });

    testWidgets('crosses conversation boundaries inside one timeline', (
      tester,
    ) async {
      final asked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryScreen(
            loadConversations: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [
                _conversation(id: 'conv-new', started: '2026-08-25T09:00:00Z'),
                _conversation(id: 'conv-old'),
              ],
            ),
            loadTranscript: (conversationId, _) async {
              asked.add(conversationId);
              return _transcript(
                conversationId: conversationId,
                turns: [
                  _turn(
                    id: 'turn-$conversationId',
                    started: conversationId == 'conv-new'
                        ? '2026-08-25T09:00:00Z'
                        : '2026-08-24T09:00:00Z',
                    user: conversationId == 'conv-new' ? '今天' : '昨天',
                  ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsNothing);
      await tester.tap(
        find.byKey(const Key('conversation-history-load-earlier')),
      );
      await tester.pumpAndSettle();

      expect(asked, ['conv-new', 'conv-old']);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('2026年8月24日'), findsOneWidget);
      expect(find.text('2026年8月25日'), findsOneWidget);
    });

    testWidgets('skips an empty internal conversation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryScreen(
            loadConversations: (_) async => ConversationPageView(
              companionId: 'companion-a',
              conversations: [
                _conversation(id: 'conv-empty'),
                _conversation(id: 'conv-with-words'),
              ],
            ),
            loadTranscript: (conversationId, _) async => _transcript(
              conversationId: conversationId,
              turns:
                  conversationId == 'conv-empty' ? [] : [_turn(id: 'turn-1')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('周末去哪'), findsOneWidget);
    });

    testWidgets('a history it could not read is not an empty history', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationHistoryScreen(
            loadConversations: (_) => Future.error(Exception('读取失败')),
            loadTranscript: (_, __) => throw UnimplementedError(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation-history-error')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('conversation-history-empty')), findsNothing);
    });
  });
}
