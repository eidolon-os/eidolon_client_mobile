import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/forget_sheet.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 纠错 — asking it to forget something.
///
/// This is the only destructive thing a person can do from this app, so the
/// tests are about what stands between typing words and losing something: the
/// preview, the token that binds it, and the refusal to offer a button when
/// there is nothing safe to confirm.

Map<String, dynamic> proposalWire({
  String status = 'preview',
  String? token = 'opaque',
  bool needsConfirmation = true,
  double score = 0.8,
  List<Map<String, dynamic>>? entries,
  String detail = '',
  String? action = 'delete',
}) => {
      'contract_version': '1',
      'status': status,
      'target': '上周那件事',
      'action': action,
      'entries': entries ??
          [
            {'entry_id': 'drawer_1', 'preview': '上周那件事的记录', 'score': score},
          ],
      'needs_confirmation': needsConfirmation,
      'confirmation_token': token,
      'expires_at': 1900000000,
      'detail': detail,
    };

Map<String, dynamic> resultWire({String status = 'applied', int count = 1}) => {
      'contract_version': '1',
      'action': 'delete',
      'target': '上周那件事',
      'entry_count': count,
      'status': status,
    };

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

Future<void> pumpSheet(
  WidgetTester tester, {
  required Future<ForgetProposalView> Function(String target) preview,
  Future<ForgetResultView> Function(String token)? confirm,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ForgetSheet(
        preview: preview,
        confirm: confirm ??
            (_) async => ForgetResultView.fromJson(resultWire()),
      ),
    ),
  );
}

Future<void> ask(WidgetTester tester, String target) async {
  await tester.enterText(find.byKey(const Key('forget-target-field')), target);
  await tester.tap(find.byKey(const Key('forget-preview-button')));
  await tester.pumpAndSettle();
}

void main() {
  group('the forget client', () {
    test('a preview is a POST and changes nothing by itself', () async {
      // It mints a token the caller depends on, so it must not be cached or
      // replayed by anything in between.
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request as http.Request;
          return _hostAnswer(proposalWire());
        }),
      );

      final proposal = await client.previewForget(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        target: '上周那件事',
      );

      expect(sent?.method, 'POST');
      expect(sent?.url.path, '/api/management/v1/memory/forget/preview');
      expect(jsonDecode(sent!.body)['target'], '上周那件事');
      expect(proposal.confirmationToken, 'opaque');
    });

    test('the ordinary case names no action', () async {
      // "forget this" means delete to a person; archive is a deliberate choice,
      // and a client that always sent one would be making it for them.
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request as http.Request;
          return _hostAnswer(proposalWire());
        }),
      );

      await client.previewForget(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        target: 'x',
      );

      expect(jsonDecode(sent!.body).containsKey('action'), isFalse);
    });

    test('the confirm sends the token and nothing else', () async {
      // Not the target: sending both would invite the Host to prefer the wrong
      // one, and the token is the half that was actually looked at.
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
          return _hostAnswer(resultWire());
        }),
      );

      await client.confirmForget(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        confirmationToken: 'opaque',
      );

      expect(jsonDecode(sent!.body), {'confirmation_token': 'opaque'});
    });
  });

  group('the forget sheet', () {
    testWidgets('shows what would go before offering to do it', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
      );

      // No button before a preview: there is nothing to confirm yet.
      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);

      await ask(tester, '上周那件事');

      expect(find.byKey(const Key('forget-entry-drawer_1')), findsOneWidget);
      expect(find.text('上周那件事的记录'), findsOneWidget);
      expect(find.byKey(const Key('forget-confirm-button')), findsOneWidget);
    });

    testWidgets('confirms with the token the preview bound', (tester) async {
      String? confirmedWith;
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (token) async {
          confirmedWith = token;
          return ForgetResultView.fromJson(resultWire());
        },
      );
      await ask(tester, '上周那件事');
      await tester.tap(find.byKey(const Key('forget-confirm-button')));
      await tester.pumpAndSettle();

      expect(confirmedWith, 'opaque');
      expect(find.text('已经忘掉 1 条'), findsOneWidget);
    });

    testWidgets('offers nothing to press when nothing matched', (tester) async {
      // A button here would remove nothing and report success.
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(
          proposalWire(status: 'not_found', token: null, entries: []),
        ),
      );
      await ask(tester, '没有的事');

      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
      expect(find.text('你没有告诉过它这件事'), findsOneWidget);
    });

    testWidgets('says "too much" differently from "nothing"', (tester) async {
      // The two lead a person to different next moves, and an empty list would
      // say neither.
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(
          proposalWire(
            status: 'too_broad',
            token: null,
            entries: [],
            detail: 'too many',
          ),
        ),
      );
      await ask(tester, '一切');

      expect(find.text('这么说会牵连太多，说得再具体一点'), findsOneWidget);
      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
    });

    testWidgets('does not soften an inexact match', (tester) async {
      // Pressing a button on a guess is how someone loses what they meant to
      // keep, so the guess is said out loud.
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire(score: 0.6)),
      );
      await ask(tester, '那件事');

      expect(find.text('不是完全确定的匹配'), findsOneWidget);
      expect(find.byKey(const Key('forget-inexact-warning')), findsOneWidget);
    });

    testWidgets('an exact single match is not dressed up as a doubt',
        (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(
          proposalWire(score: 1.0, needsConfirmation: false),
        ),
      );
      await ask(tester, '乌龙茶');

      expect(find.text('不是完全确定的匹配'), findsNothing);
      expect(find.byKey(const Key('forget-inexact-warning')), findsNothing);
    });

    testWidgets('does not claim a change is done when it was only accepted',
        (tester) async {
      // The Host publishes durably and applies asynchronously. "已经忘掉" for a
      // command still on its way is the comfortable lie.
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) async =>
            ForgetResultView.fromJson(resultWire(status: 'accepted')),
      );
      await ask(tester, '上周那件事');
      await tester.tap(find.byKey(const Key('forget-confirm-button')));
      await tester.pumpAndSettle();

      expect(find.text('已受理 1 条，正在生效'), findsOneWidget);
      expect(find.textContaining('已经忘掉'), findsNothing);
    });

    testWidgets('a spent token is not offered again', (tester) async {
      var confirms = 0;
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) async {
          confirms++;
          return ForgetResultView.fromJson(resultWire());
        },
      );
      await ask(tester, '上周那件事');
      await tester.tap(find.byKey(const Key('forget-confirm-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
      expect(confirms, 1);
    });

    testWidgets('a new question drops the previous answer', (tester) async {
      // Leaving the old proposal up would let someone confirm a set that
      // belonged to words they have since changed.
      var asks = 0;
      await pumpSheet(
        tester,
        preview: (_) async {
          asks++;
          if (asks == 1) return ForgetProposalView.fromJson(proposalWire());
          return ForgetProposalView.fromJson(
            proposalWire(status: 'not_found', token: null, entries: []),
          );
        },
      );
      await ask(tester, '上周那件事');
      expect(find.byKey(const Key('forget-confirm-button')), findsOneWidget);

      await ask(tester, '别的事');

      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
    });

    testWidgets('an expired confirmation says to look again', (tester) async {
      // 409 is the Host saying this decision is no longer about now. Retrying
      // the same token would fail the same way, so the person is sent back to
      // the preview rather than offered a retry.
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) => Future.error(
          const ManagementRequestException('拒绝', statusCode: 409),
        ),
      );
      await ask(tester, '上周那件事');
      await tester.tap(find.byKey(const Key('forget-confirm-button')));
      await tester.pumpAndSettle();

      expect(find.text('这次确认过期了，请重新看一遍再决定'), findsOneWidget);
    });

    testWidgets('empty words ask the Host nothing', (tester) async {
      var asks = 0;
      await pumpSheet(
        tester,
        preview: (_) async {
          asks++;
          return ForgetProposalView.fromJson(proposalWire());
        },
      );

      await tester.tap(find.byKey(const Key('forget-preview-button')));
      await tester.pumpAndSettle();

      expect(asks, 0);
    });
  });
}
