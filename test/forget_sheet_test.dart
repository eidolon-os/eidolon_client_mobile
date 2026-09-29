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
/// tests are about what stands between typing words and losing something — the
/// preview, the token that binds it, the second question, expiry — and about
/// what happens after: the Host applies the change in the background, and the
/// screen must follow it to `applied` or `failed` instead of stopping at
/// 「正在生效」.

final DateTime _now = DateTime.utc(2026, 9, 23, 12);
final int _later = _now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> proposalWire({
  String status = 'preview',
  String? token = 'opaque',
  bool needsConfirmation = true,
  double score = 0.8,
  List<Map<String, dynamic>>? entries,
  String detail = '',
  int? expiresAt,
}) => {
      'contract_version': '1',
      'status': status,
      'target': '上周那件事',
      'entries': entries ??
          [
            {'entry_id': 'drawer_1', 'preview': '上周那件事的记录', 'score': score},
          ],
      'needs_confirmation': needsConfirmation,
      'confirmation_token': token,
      'expires_at': token == null ? null : (expiresAt ?? _later),
      'detail': detail,
    };

Map<String, dynamic> resultWire({String status = 'applied', int count = 1}) => {
      'contract_version': '1',
      'request_id': 'owner-forget-p1',
      'target': '上周那件事',
      'entry_count': count,
      'status': status,
    };

ForgetProgressView progressOf(String status) => ForgetProgressView.fromJson({
      'contract_version': '1',
      'request_id': 'owner-forget-p1',
      'status': status,
    });

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

const _fast = [Duration(milliseconds: 10), Duration(milliseconds: 10), Duration(milliseconds: 10)];

Future<void> pumpSheet(
  WidgetTester tester, {
  required Future<ForgetProposalView> Function(String target) preview,
  Future<ForgetResultView> Function(String token)? confirm,
  Future<ForgetProgressView> Function(String requestId)? progress,
  DateTime Function()? now,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ForgetSheet(
        preview: preview,
        confirm: confirm ?? (_) async => ForgetResultView.fromJson(resultWire()),
        progress: progress,
        now: now ?? () => _now,
        pollDelays: _fast,
      ),
    ),
  );
}

Future<void> ask(WidgetTester tester, String target) async {
  await tester.enterText(find.byKey(const Key('forget-target-field')), target);
  await tester.tap(find.byKey(const Key('forget-preview-button')));
  await tester.pumpAndSettle();
}

Future<void> decide(WidgetTester tester, {bool sure = true}) async {
  await tester.tap(find.byKey(const Key('forget-confirm-button')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(Key(sure ? 'forget-decision-confirm' : 'forget-decision-cancel')),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the forget client', () {
    test('a preview is a POST of the words and nothing else', () async {
      // There is no action to name: forgetting is a deletion, and the archive
      // the realm also knows has no way back in this product.
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
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
      expect(jsonDecode(sent!.body), {'target': '上周那件事'});
      expect(proposal.confirmationToken, 'opaque');
    });

    test('the confirm sends the token and nothing else', () async {
      http.Request? sent;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          sent = request;
          return _hostAnswer(resultWire());
        }),
      );

      final result = await client.confirmForget(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        confirmationToken: 'opaque',
      );

      expect(jsonDecode(sent!.body), {'confirmation_token': 'opaque'});
      expect(result.requestId, 'owner-forget-p1');
    });

    test('progress is asked by the change the Host named', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer({
            'contract_version': '1',
            'request_id': 'owner-forget-p1',
            'status': 'applied',
          });
        }),
      );

      final progress = await client.forgetStatus(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        requestId: 'owner-forget-p1',
      );

      expect(asked?.path, '/api/management/v1/memory/forget/status');
      expect(asked?.queryParameters, {'request_id': 'owner-forget-p1'});
      expect(progress.status, 'applied');
    });
  });

  group('the forget sheet', () {
    testWidgets('says up front that forgetting cannot be undone', (tester) async {
      await pumpSheet(tester, preview: (_) async => ForgetProposalView.fromJson(proposalWire()));

      expect(find.textContaining('删除后不能恢复'), findsOneWidget);
      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
    });

    testWidgets('shows what would go before offering to do it', (tester) async {
      await pumpSheet(tester, preview: (_) async => ForgetProposalView.fromJson(proposalWire()));
      await ask(tester, '上周那件事');

      expect(find.byKey(const Key('forget-entry-drawer_1')), findsOneWidget);
      expect(find.text('上周那件事的记录'), findsOneWidget);
      expect(find.text('忘掉这 1 条'), findsOneWidget);
    });

    testWidgets('asks once more before a permanent change, and can be declined',
        (tester) async {
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

      expect(find.byKey(const Key('forget-decision')), findsOneWidget);
      expect(find.textContaining('忘掉后不能恢复'), findsOneWidget);

      await tester.tap(find.byKey(const Key('forget-decision-cancel')));
      await tester.pumpAndSettle();

      expect(confirms, 0);
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
      await decide(tester);

      expect(confirmedWith, 'opaque');
      expect(find.text('已经忘掉 1 条，它以后不会再想起这些'), findsOneWidget);
    });

    testWidgets('follows an accepted change until the Host says it is applied',
        (tester) async {
      // The usual case on a Host: the confirm answers `accepted`, the change is
      // applied in the background. "已受理，正在生效" with nothing behind it was
      // the dead end; now the screen asks until it knows.
      final asked = <String>[];
      final answers = ['accepted', 'retrying', 'applied'];
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) async => ForgetResultView.fromJson(resultWire(status: 'accepted')),
        progress: (requestId) async {
          asked.add(requestId);
          return progressOf(answers[asked.length - 1]);
        },
      );
      await ask(tester, '上周那件事');
      await tester.tap(find.byKey(const Key('forget-confirm-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('forget-decision-confirm')));
      await tester.pump();

      expect(find.text('正在忘掉 1 条…'), findsOneWidget);
      expect(find.textContaining('已经忘掉'), findsNothing);

      await tester.pumpAndSettle();

      expect(asked, ['owner-forget-p1', 'owner-forget-p1', 'owner-forget-p1']);
      expect(find.text('已经忘掉 1 条，它以后不会再想起这些'), findsOneWidget);
    });

    testWidgets('a failed change is said as stopped, not as still going', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) async => ForgetResultView.fromJson(resultWire(status: 'accepted')),
        progress: (_) async => progressOf('failed'),
      );
      await ask(tester, '上周那件事');
      await decide(tester);

      expect(find.textContaining('没有忘掉'), findsOneWidget);
      // The next step is a new preview, and the button for it is live.
      final preview = tester.widget<FilledButton>(find.byKey(const Key('forget-preview-button')));
      expect(preview.onPressed, isNotNull);
    });

    testWidgets('a change still running after every read says it will finish on its own',
        (tester) async {
      var reads = 0;
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) async => ForgetResultView.fromJson(resultWire(status: 'accepted')),
        progress: (_) async {
          reads++;
          return progressOf(reads > 3 ? 'applied' : 'accepted');
        },
      );
      await ask(tester, '上周那件事');
      await decide(tester);

      expect(find.textContaining('它会自己完成'), findsOneWidget);
      expect(reads, 3);

      // Asking again is honest here: the change can still finish.
      await tester.tap(find.byKey(const Key('forget-ask-again')));
      await tester.pumpAndSettle();

      expect(find.text('已经忘掉 1 条，它以后不会再想起这些'), findsOneWidget);
    });

    testWidgets('offers nothing to press when nothing matched', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(
          proposalWire(status: 'not_found', token: null, entries: []),
        ),
      );
      await ask(tester, '没有的事');

      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
      // Not "you never told it": what was said may simply not have been kept.
      expect(find.text('没有找到和「上周那件事」有关的记忆'), findsOneWidget);
    });

    testWidgets('says "too much" differently from "nothing"', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(
          proposalWire(status: 'too_broad', token: null, entries: [], detail: 'too many'),
        ),
      );
      await ask(tester, '一切');

      expect(find.text('这么说会牵连太多，说得再具体一点'), findsOneWidget);
      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
    });

    testWidgets('does not soften an inexact match', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire(score: 0.6)),
      );
      await ask(tester, '那件事');

      expect(find.text('不是完全确定的匹配'), findsOneWidget);
      expect(find.byKey(const Key('forget-inexact-warning')), findsOneWidget);
    });

    testWidgets('an exact single match is not dressed up as a doubt', (tester) async {
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

    testWidgets('an expired preview offers no button', (tester) async {
      // Checked on the phone rather than discovered by a failed confirm: the
      // Host said when the decision stops being about now.
      var clock = _now;
      await pumpSheet(
        tester,
        now: () => clock,
        preview: (_) async => ForgetProposalView.fromJson(
          proposalWire(expiresAt: _now.add(const Duration(seconds: 30)).millisecondsSinceEpoch ~/ 1000),
        ),
      );
      await ask(tester, '上周那件事');
      expect(tester.widget<FilledButton>(find.byKey(const Key('forget-confirm-button'))).onPressed,
          isNotNull);

      clock = _now.add(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));

      expect(find.byKey(const Key('forget-expired')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('forget-confirm-button'))).onPressed,
          isNull);
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
      await decide(tester);

      expect(find.byKey(const Key('forget-confirm-button')), findsNothing);
      expect(confirms, 1);
    });

    testWidgets('a new question drops the previous answer', (tester) async {
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

    testWidgets('a preview that can no longer be acted on says to look again', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) async => ForgetProposalView.fromJson(proposalWire()),
        confirm: (_) => Future.error(
          const ManagementRequestException(
            '忘掉它被拒绝',
            statusCode: 409,
            refusal: Refusal(kind: 'conflict', retryable: false),
          ),
        ),
      );
      await ask(tester, '上周那件事');
      await decide(tester);

      expect(find.text('这次预览已经失效，请重新看一遍再决定'), findsOneWidget);
    });

    testWidgets('a Host fault is worded, and no button invites a hopeless retry',
        (tester) async {
      // What the phone showed on 2026-09-22: 「没有完成：查看会忘掉什么被拒绝：
      // memory response violated the consumed contract」 under a live button.
      await pumpSheet(
        tester,
        preview: (_) => Future.error(
          const ManagementRequestException(
            '查看会忘掉什么被拒绝',
            statusCode: 503,
            refusal: Refusal(
              kind: 'upstream',
              reason: 'memory response violated the consumed contract',
              retryable: false,
            ),
          ),
        ),
      );
      await ask(tester, '工资');

      expect(find.text('没有完成：主机在处理记忆纠错时出错了'), findsOneWidget);
      expect(find.textContaining('被拒绝'), findsNothing);
      final preview = tester.widget<FilledButton>(find.byKey(const Key('forget-preview-button')));
      expect(preview.onPressed, isNull);
    });

    testWidgets('a Host that did not answer can be asked again', (tester) async {
      await pumpSheet(
        tester,
        preview: (_) => Future.error(const ManagementRequestException('查看会忘掉什么超时')),
      );
      await ask(tester, '工资');

      final preview = tester.widget<FilledButton>(find.byKey(const Key('forget-preview-button')));
      expect(preview.onPressed, isNotNull);
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
