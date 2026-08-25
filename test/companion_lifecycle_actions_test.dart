import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/companion_detail_screen.dart';
import 'package:eidolon_client_mobile/src/management/lifecycle_sheet.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 收起来 / 让它回来.
///
/// What these hold is not "a button works". It is that the rule about who
/// answers for this Owner stays on the Host: the app asks, and turns the Host's
/// refusal into the question a person can answer. A client that decided for
/// itself when a successor is needed would be a second copy of that rule.

http.Response _answer(Map<String, dynamic> body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );

CompanionDetailView _detail({
  String lifecycleState = 'active',
  bool isDefault = true,
}) =>
    CompanionDetailView.fromJson({
      'contract_version': '1',
      'companion_id': 'companion-a',
      'display_name': '小忆',
      'kind': 'standard',
      'lifecycle_state': lifecycleState,
      'revision': 2,
      'is_default': isDefault,
    });

CompanionSummaryView _row(String id, String name, {String state = 'active'}) =>
    CompanionSummaryView.fromJson({
      'companion_id': id,
      'display_name': name,
      'kind': 'standard',
      'lifecycle_state': state,
      'revision': 1,
      'created_at': '2026-08-24T09:30:00+00:00',
      'updated_at': '2026-08-24T09:30:00+00:00',
    });

void main() {
  group('the client call', () {
    test('states where it should end up, and never names an Owner', () async {
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
          return _answer({
            'contract_version': '1',
            'companion_id': 'companion-a',
            'lifecycle_state': 'archived',
            'revision': 6,
            'default_companion_id': 'companion-b',
          });
        }),
      );

      final view = await client.setCompanionLifecycle(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
        lifecycleState: 'archived',
      );

      expect(sent?.method, 'PUT');
      expect(sent?.url.path, '/api/management/v1/companions/companion-a/lifecycle');
      expect(sent?.url.queryParameters.containsKey('owner_id'), isFalse);
      // No replacement until the Host says it needs one.
      expect(jsonDecode(sent!.body), {'lifecycle_state': 'archived'});
      expect(view.defaultCompanionId, 'companion-b');
    });

    test('a refusal that is a question arrives as one', () async {
      // Before the code travelled, this was an anonymous 409 — the same thing a
      // lost race looks like, and nothing a screen could act on.
      final client = ManagementClient(
        httpClient: MockClient((request) async => _answer(
              {
                'detail': {
                  'code': 'default_replacement_required',
                  'message': 'companion is the owner default',
                }
              },
              status: 409,
            )),
      );

      await expectLater(
        client.setCompanionLifecycle(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
          companionId: 'companion-a',
          lifecycleState: 'archived',
        ),
        throwsA(isA<ManagementRequestException>()
            .having((e) => e.code, 'code', 'default_replacement_required')
            .having((e) => e.reason, 'reason', 'companion is the owner default')),
      );
    });

    test('a refusal with only a sentence still reads', () async {
      final client = ManagementClient(
        httpClient: MockClient((request) async =>
            _answer({'detail': '主机暂时联系不上'}, status: 503)),
      );

      await expectLater(
        client.setCompanionLifecycle(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
          companionId: 'companion-a',
          lifecycleState: 'active',
        ),
        throwsA(isA<ManagementRequestException>()
            .having((e) => e.code, 'code', isNull)
            .having((e) => e.reason, 'reason', '主机暂时联系不上')),
      );
    });
  });

  group('the sheet', () {
    testWidgets('asks first, and says nothing is lost', (tester) async {
      final asked = <List<String?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompanionLifecycleSheet(
              companion: _detail(),
              others: [_row('companion-b', '阿力')],
              setLifecycle: (state, replacement) async {
                asked.add([state, replacement]);
                return CompanionLifecycleView.fromJson({
                  'companion_id': 'companion-a',
                  'lifecycle_state': state,
                  'revision': 3,
                  'default_companion_id': 'companion-b',
                });
              },
            ),
          ),
        ),
      );

      expect(find.text('它不会再开始新的对话。它记得的一切都留着，随时可以让它回来。'),
          findsOneWidget);
      // Nothing is asked until the person presses.
      expect(asked, isEmpty);

      await tester.tap(find.byKey(const Key('lifecycle-confirm')));
      await tester.pumpAndSettle();

      // The first ask names no successor: whether one is needed is the Host's
      // to say.
      expect(asked, [
        ['archived', null]
      ]);
    });

    testWidgets('turns the Host\'s refusal into the question', (tester) async {
      final asked = <List<String?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompanionLifecycleSheet(
              companion: _detail(),
              others: [_row('companion-b', '阿力')],
              setLifecycle: (state, replacement) async {
                asked.add([state, replacement]);
                if (replacement == null) {
                  throw const ManagementRequestException(
                    '收起来被拒绝',
                    statusCode: 409,
                    code: 'default_replacement_required',
                  );
                }
                return CompanionLifecycleView.fromJson({
                  'companion_id': 'companion-a',
                  'lifecycle_state': state,
                  'revision': 3,
                  'default_companion_id': replacement,
                });
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('lifecycle-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('现在是 小忆 在回答你'), findsOneWidget);
      expect(find.byKey(const Key('lifecycle-successor-companion-b')),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('lifecycle-successor-companion-b')));
      await tester.pumpAndSettle();

      expect(asked, [
        ['archived', null],
        ['archived', 'companion-b'],
      ]);
    });

    testWidgets('says plainly when there is nobody else', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompanionLifecycleSheet(
              companion: _detail(),
              others: const [],
              setLifecycle: (state, replacement) async =>
                  throw const ManagementRequestException(
                '收起来被拒绝',
                statusCode: 409,
                code: 'last_active_companion',
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('lifecycle-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lifecycle-blocked')), findsOneWidget);
      expect(find.text('这是你现在唯一还在的 Eidolon。先添一个新的，再把它收起来。'),
          findsOneWidget);
      // Nothing left to press: it is a statement, not a thing to retry.
      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('lifecycle-confirm')),
      );
      expect(confirm.onPressed, isNull);
    });

    testWidgets('bringing one back says nothing about who answers',
        (tester) async {
      final asked = <List<String?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompanionLifecycleSheet(
              companion: _detail(lifecycleState: 'archived', isDefault: false),
              others: [_row('companion-b', '阿力')],
              setLifecycle: (state, replacement) async {
                asked.add([state, replacement]);
                return CompanionLifecycleView.fromJson({
                  'companion_id': 'companion-a',
                  'lifecycle_state': state,
                  'revision': 4,
                  'default_companion_id': 'companion-b',
                });
              },
            ),
          ),
        ),
      );

      expect(find.text('让 小忆 回来'), findsOneWidget);
      expect(find.text('它可以再开始新的对话了。谁来默认回答，还是照你之前定的。'),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('lifecycle-confirm')));
      await tester.pumpAndSettle();

      expect(asked, [
        ['active', null]
      ]);
    });
  });

  group('the screen', () {
    testWidgets('a Host that cannot do this has nothing to press',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'companion-a',
            load: (_) async => _detail(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('detail-lifecycle')), findsNothing);
    });

    testWidgets('each action waits on its own capability', (tester) async {
      // A Host that can put one away and not bring one back is a Host this
      // screen has to be able to draw. Inferring the second flag from the first
      // would be this app answering a question only the Host can.
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'companion-a',
            load: (_) async => _detail(lifecycleState: 'archived'),
            canPutAway: true,
            setLifecycle: (_, __, ___) async =>
                throw AssertionError('never asked'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('detail-lifecycle')), findsNothing);
    });

    testWidgets('mid-move states offer no button', (tester) async {
      // ``retiring`` is a step the Host is walking through. A button on it
      // would be one that gets refused.
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'companion-a',
            load: (_) async => _detail(lifecycleState: 'retiring'),
            canPutAway: true,
            canBringBack: true,
            setLifecycle: (_, __, ___) async =>
                throw AssertionError('never asked'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('detail-lifecycle')), findsNothing);
    });

    testWidgets('after a move the screen re-reads rather than repaints itself',
        (tester) async {
      // The answer to a lifecycle change describes a move, not a Companion.
      // Painting one from the other is how a screen and a Host drift apart.
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionDetailScreen(
            companionId: 'companion-a',
            load: (_) async {
              reads += 1;
              return _detail(
                lifecycleState: reads == 1 ? 'active' : 'archived',
                isDefault: false,
              );
            },
            others: [_row('companion-b', '阿力')],
            canPutAway: true,
            canBringBack: true,
            setLifecycle: (companionId, state, replacement) async =>
                CompanionLifecycleView.fromJson({
              'companion_id': companionId,
              'lifecycle_state': state,
              'revision': 3,
              'default_companion_id': 'companion-b',
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('detail-lifecycle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lifecycle-confirm')));
      await tester.pumpAndSettle();

      expect(reads, 2);
      expect(find.text('让它回来'), findsOneWidget);
    });
  });
}
