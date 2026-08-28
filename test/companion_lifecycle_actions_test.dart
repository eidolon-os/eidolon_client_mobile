import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/home_models.dart';
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
      // lost race looks like, and nothing a screen could act on. The Host now
      // publishes one envelope for every refusal on this surface, so the kind
      // and the domain code arrive together and a screen can tell the question
      // ("who should answer instead?") from the accident.
      final client = ManagementClient(
        httpClient: MockClient((request) async => _answer(
              {
                'detail': {
                  'kind': 'conflict',
                  'reason': 'companion is the owner default',
                  'code': 'default_replacement_required',
                  'retryable': false,
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
              displayName: '小忆',
              lifecycleState: 'active',
              others: const [LifecycleSuccessor(companionId: 'companion-b', displayName: '阿力')],
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

      expect(
        find.text('它不会再开始新的对话，正在由它应答的设备会先空下来。'
            '它记得的一切都留着，随时可以让它回来。'),
        findsOneWidget,
      );
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
              displayName: '小忆',
              lifecycleState: 'active',
              others: const [LifecycleSuccessor(companionId: 'companion-b', displayName: '阿力')],
              setLifecycle: (state, replacement) async {
                asked.add([state, replacement]);
                if (replacement == null) {
                  throw const ManagementRequestException(
                    '收起来被拒绝',
                    statusCode: 409,
                    // The Host's envelope, as it now arrives: a conflict that is
                    // a question rather than a lost race, named by its code.
                    refusal: Refusal(
                      kind: 'conflict',
                      code: 'default_replacement_required',
                    ),
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
              displayName: '小忆',
              lifecycleState: 'active',
              others: const <LifecycleSuccessor>[],
              setLifecycle: (state, replacement) async =>
                  throw const ManagementRequestException(
                '收起来被拒绝',
                statusCode: 409,
                refusal: Refusal(
                  kind: 'conflict',
                  code: 'last_active_companion',
                ),
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
              displayName: '小忆',
              lifecycleState: 'archived',
              others: const [LifecycleSuccessor(companionId: 'companion-b', displayName: '阿力')],
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
      expect(
        find.text('它可以再开始新的对话了。设备和默认回答都还是你之前定的。'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('lifecycle-confirm')));
      await tester.pumpAndSettle();

      expect(asked, [
        ['active', null]
      ]);
    });
  });

  group('the Eidolon\'s page', () {
    /// The page every path now opens. There used to be two: a thin one the
    /// roster pushed (default badge, rename, put-away) and a rich one only the
    /// home card could reach, and only for the Eidolon that answers when
    /// nobody was named. Which page you got depended on where you tapped, and
    /// only one of them let you change who the Eidolon is.
    Future<void> open(
      WidgetTester tester, {
      String lifecycleState = 'active',
      bool isDefault = false,
      VoidCallback? onChangeLifecycle,
    }) =>
        tester.pumpWidget(
          MaterialApp(
            home: CompanionPage(
              companion: HostCompanion.fromView(
                CompanionSummaryView.fromJson({
                  'companion_id': 'companion-a',
                  'display_name': '小忆',
                  'kind': 'conversational',
                  'lifecycle_state': lifecycleState,
                  'revision': 4,
                  'created_at': '2026-08-01T00:00:00+00:00',
                  'updated_at': '2026-08-01T00:00:00+00:00',
                  'running': true,
                  'last_active_at': '2026-08-26T09:30:00+00:00',
                }),
              ),
              isDefault: isDefault,
              onChangeLifecycle: onChangeLifecycle,
              devices: const MountedDeviceInventory(devices: []),
              onRename: () {},
              onOpenPersona: () {},
            ),
          ),
        );

    testWidgets('a Host that cannot put one away has nothing to press',
        (tester) async {
      // Absent rather than present-and-refused: a button that exists to be
      // rejected teaches a person to distrust the ones that work.
      await open(tester);

      expect(find.byKey(const Key('companion-lifecycle')), findsNothing);
    });

    testWidgets('the action says which direction it goes', (tester) async {
      await open(tester, onChangeLifecycle: () {});
      expect(find.text('收起伙伴'), findsOneWidget);

      await open(
        tester,
        lifecycleState: 'archived',
        onChangeLifecycle: () {},
      );
      expect(find.text('让伙伴回来'), findsOneWidget);
    });

    testWidgets('being put away outranks whatever the runtime says',
        (tester) async {
      // The row still reports running — the Host may not have torn the runtime
      // down yet — but what the person decided is the thing to show.
      await open(tester, lifecycleState: 'archived', onChangeLifecycle: () {});

      expect(find.text('已经收起来了'), findsOneWidget);
      expect(find.textContaining('正在运行'), findsNothing);
    });

    testWidgets('the default one is marked, not renamed or promoted',
        (tester) async {
      await open(tester, isDefault: true);

      expect(find.byKey(const Key('companion-default-badge')), findsOneWidget);
      expect(find.text('默认应答伙伴'), findsOneWidget);
      // And it is still just this Eidolon's page: no greeting to the Owner,
      // which used to sit under the name and make the card read as a profile.
      expect(find.textContaining('你好'), findsNothing);
    });

    testWidgets('an Eidolon that is not the default says nothing about it',
        (tester) async {
      await open(tester);

      expect(find.byKey(const Key('companion-default-badge')), findsNothing);
    });
  });
}
