import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/audience_sheet.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 只让它记得 — choosing who keeps one memory.
///
/// The write side of an isolation the reads have honoured since Phase 2. It looks
/// like a destructive action and is not: the Eidolon that is named still
/// remembers the thing in full, and the way back is the same call. So the tests
/// are about saying that truthfully — who *will* remember, not who will not —
/// and about the two claims this sheet must never make: that a change is done
/// when it was only accepted, and that there is a choice when there is nobody to
/// choose.

CompanionSummaryView companion(String id, String name) =>
    CompanionSummaryView.fromJson({
      'companion_id': id,
      'display_name': name,
      'kind': 'standard',
      'lifecycle_state': 'active',
      'revision': 1,
      'created_at': '2026-08-01T00:00:00+00:00',
      'updated_at': '2026-08-01T00:00:00+00:00',
    });

MemoryAudienceView audience({String companionId = 'c-a', String status = 'applied'}) =>
    MemoryAudienceView.fromJson({
      'contract_version': '1',
      'entry_id': 'drawer_1',
      'companion_id': companionId,
      'status': status,
    });

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

Future<void> pumpSheet(
  WidgetTester tester, {
  required Future<MemoryAudienceView> Function(String? companionId) assign,
  List<CompanionSummaryView>? companions,
  String? current,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AudienceSheet(
        entryId: 'drawer_1',
        companions: companions ??
            [companion('c-a', '小忆'), companion('c-b', '小声')],
        assign: assign,
        currentCompanionId: current,
      ),
    ),
  );
}

void main() {
  group('the audience client', () {
    test('puts the entry in the path and the eidolon in the body', () async {
      // A PUT, so a retry after a connection nobody saw the answer to changes
      // nothing twice.
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
          return _hostAnswer({
            'contract_version': '1',
            'entry_id': 'drawer_1',
            'companion_id': 'c-a',
            'status': 'applied',
          });
        }),
      );

      final result = await client.assignMemoryAudience(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        entryId: 'drawer_1',
        companionId: 'c-a',
      );

      expect(sent?.method, 'PUT');
      expect(sent?.url.path, '/api/management/v1/memory/entries/drawer_1/audience');
      expect(jsonDecode(sent!.body), {'companion_id': 'c-a'});
      expect(result.companionId, 'c-a');
    });

    test('names nobody to give a memory back to everyone', () async {
      // An empty string rather than a word for "everyone": the Host decides what
      // an audience is.
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
          return _hostAnswer({
            'contract_version': '1',
            'entry_id': 'drawer_1',
            'companion_id': '',
            'status': 'applied',
          });
        }),
      );

      await client.assignMemoryAudience(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        entryId: 'drawer_1',
      );

      expect(jsonDecode(sent!.body), {'companion_id': ''});
    });

    test('escapes an entry id into the path', () async {
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
          return _hostAnswer({
            'contract_version': '1',
            'entry_id': 'drawer_1',
            'companion_id': 'c-a',
            'status': 'applied',
          });
        }),
      );

      await client.assignMemoryAudience(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        entryId: 'drawer_1/../other',
        companionId: 'c-a',
      );

      expect(
        sent!.url.toString(),
        contains('/memory/entries/drawer_1%2F..%2Fother/audience'),
      );
    });
  });

  group('the audience sheet', () {
    testWidgets('says who will remember, and offers the way back', (tester) async {
      await pumpSheet(tester, assign: (_) async => audience());

      expect(find.byKey(const Key('audience-companion-c-a')), findsOneWidget);
      expect(find.byKey(const Key('audience-companion-c-b')), findsOneWidget);
      // Never a one-way door: giving it back is one of the choices.
      expect(find.byKey(const Key('audience-everyone')), findsOneWidget);
      expect(find.text('小忆'), findsOneWidget);
    });

    testWidgets('marks who holds it now, when the caller knows', (tester) async {
      await pumpSheet(tester, assign: (_) async => audience(), current: 'c-b');

      final ticks = tester.widgetList<Icon>(find.byIcon(Icons.check));
      expect(ticks.length, 1);
    });

    testWidgets('sends the companion that was tapped', (tester) async {
      String? asked = 'untouched';
      await pumpSheet(tester, assign: (companionId) async {
        asked = companionId;
        return audience(companionId: companionId ?? '');
      });
      await tester.tap(find.byKey(const Key('audience-companion-c-b')));
      await tester.pumpAndSettle();

      expect(asked, 'c-b');
      expect(find.textContaining('只有 小声 记得'), findsOneWidget);
    });

    testWidgets('gives it back to everyone with nobody named', (tester) async {
      String? asked = 'untouched';
      await pumpSheet(tester, assign: (companionId) async {
        asked = companionId;
        return audience(companionId: '');
      });
      await tester.tap(find.byKey(const Key('audience-everyone')));
      await tester.pumpAndSettle();

      expect(asked, isNull);
      expect(find.text('所有伙伴都可以记得了'), findsOneWidget);
    });

    testWidgets('does not claim a change is done when it was only accepted',
        (tester) async {
      // The Host publishes durably and applies asynchronously; a memory that has
      // not moved yet is exactly what a person would go and check.
      await pumpSheet(
        tester,
        assign: (companionId) async =>
            audience(companionId: companionId ?? '', status: 'accepted'),
      );
      await tester.tap(find.byKey(const Key('audience-companion-c-a')));
      await tester.pumpAndSettle();

      expect(find.textContaining('已受理'), findsOneWidget);
      expect(find.textContaining('现在只有'), findsNothing);
    });

    testWidgets('offers no choice when there is nobody to choose',
        (tester) async {
      // An empty list with a button under it would be a control that cannot do
      // anything.
      await pumpSheet(tester, assign: (_) async => audience(), companions: []);

      expect(find.byKey(const Key('audience-no-companions')), findsOneWidget);
      expect(find.byKey(const Key('audience-everyone')), findsNothing);
    });

    testWidgets('a memory that is already gone is said plainly', (tester) async {
      await pumpSheet(
        tester,
        assign: (_) => Future.error(
          const ManagementRequestException('没有这条', statusCode: 404),
        ),
      );
      await tester.tap(find.byKey(const Key('audience-companion-c-a')));
      await tester.pumpAndSettle();

      expect(find.text('这条记忆已经不在了'), findsOneWidget);
      expect(find.byKey(const Key('audience-result')), findsNothing);
    });

    testWidgets('a refusal is not shown as a success', (tester) async {
      await pumpSheet(
        tester,
        assign: (_) => Future.error(
          const ManagementRequestException('读取失败', statusCode: 503),
        ),
      );
      await tester.tap(find.byKey(const Key('audience-companion-c-a')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audience-error')), findsOneWidget);
      expect(find.byKey(const Key('audience-result')), findsNothing);
    });
  });
}
