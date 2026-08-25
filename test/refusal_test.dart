import 'dart:io';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/refusal_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What this app tells a person when the Host says no.
///
/// The failure these tests exist for: a Host that had never been given its
/// memory credential refused every memory read for two weeks, and this app said
/// 「读取记忆库被拒绝：Host management backend refused this request」 under a
/// 再试一次 button that could not possibly help. Three separate things were
/// wrong and each is pinned here — the app could not tell which refusal it had,
/// every screen worded refusals itself, and retry was offered unconditionally.
void main() {
  group('which refusal it is', () {
    test('a Host that was never configured is not a Host that is busy', () {
      const notConfigured = ManagementRequestException(
        '读取记忆库',
        statusCode: 503,
        refusal: Refusal(
          kind: 'not_configured',
          reason: 'Admin memory service credential is not configured',
        ),
      );
      const notRunning = ManagementRequestException(
        '读取记忆库',
        statusCode: 503,
        refusal: Refusal(kind: 'not_running', retryable: true),
      );

      expect(notConfigured.hostIsNotConfigured, isTrue);
      expect(notConfigured.hostPartIsDown, isFalse);
      expect(canRetry(notConfigured), isFalse,
          reason: 'nothing changes until somebody configures the Host');
      expect(canRetry(notRunning), isTrue, reason: 'waiting may be enough');
    });

    test('a lost race is not a Host without an Owner', () {
      // These are both 409, and the two predicates that used to tell them apart
      // were literally the same expression — so a genuine conflict on the roster
      // rendered 「这台主机还没有主人」.
      const conflict = ManagementRequestException(
        '设为默认',
        statusCode: 409,
        refusal: Refusal(kind: 'conflict', code: 'revision_stale'),
      );
      const unprovisioned = ManagementRequestException(
        '读取列表',
        statusCode: 409,
        refusal: Refusal(
          kind: 'not_configured',
          code: 'host_not_provisioned',
        ),
      );

      expect(conflict.someoneElseChangedIt, isTrue);
      expect(conflict.hostHasNoOwner, isFalse);
      expect(unprovisioned.hostHasNoOwner, isTrue);
      expect(unprovisioned.someoneElseChangedIt, isFalse);
    });

    test('an authorisation that stopped being accepted has its own name', () {
      const denied = ManagementRequestException(
        '读取',
        statusCode: 401,
        refusal: Refusal(kind: 'denied'),
      );
      expect(denied.authorisationRejected, isTrue);
      expect(refusalText(denied, subject: '它记住的'),
          '这台手机的管理授权已经失效，请重新连接主机');
    });
  });

  group('reading a refusal off the wire', () {
    Future<Object> refusalFrom(String body, int status) async {
      final client = ManagementClient(
        httpClient: MockClient((_) async => http.Response(body, status)),
      );
      try {
        await client.fetchContext(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
        );
        fail('expected a refusal');
      } on ManagementRequestException catch (error) {
        return error;
      }
    }

    test('the envelope is read as the Host published it', () async {
      final error = await refusalFrom(
        '{"detail":{"kind":"not_configured",'
        '"reason":"Admin memory service credential is not configured",'
        '"code":null,"retryable":false}}',
        503,
      ) as ManagementRequestException;

      expect(error.kind, 'not_configured');
      expect(error.reason, 'Admin memory service credential is not configured');
      expect(canRetry(error), isFalse);
    });

    test('a Host too old to publish one still yields a refusal', () async {
      // The version-skew path: this app may be newer than the Host in front of
      // it. Degrading to a status-derived kind keeps the screen readable; the
      // alternative — no refusal at all — is the state that produced 被拒绝.
      final error = await refusalFrom('{"detail":"no Owner yet"}', 409)
          as ManagementRequestException;

      expect(error.kind, 'conflict');
      expect(error.reason, 'no Owner yet');
    });

    test('a body this app cannot read is still not a crash', () async {
      final error =
          await refusalFrom('not json at all', 500) as ManagementRequestException;

      expect(error.kind, 'upstream');
      expect(canRetry(error), isTrue);
    });

    test('a request that never reached the Host carries no refusal', () async {
      final client = ManagementClient(
        httpClient: MockClient((_) async => throw const SocketException('down')),
      );
      try {
        await client.fetchContext(
          Uri.parse('https://192.168.1.26:9002'),
          accessToken: 'session-token',
        );
        fail('expected a failure');
      } on ManagementRequestException catch (error) {
        // Nothing was refused, so there is nothing to explain beyond "it did
        // not get through" — a real distinction, and the only one left.
        expect(error.refusal, isNull);
        expect(canRetry(error), isTrue);
      }
    });
  });

  group('what a screen shows', () {
    Future<void> pump(WidgetTester tester, Object error) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RefusalNotice(
                error: error,
                subject: '它记住的',
                onRetry: () {},
                retryKey: const Key('retry'),
              ),
            ),
          ),
        );

    testWidgets('a Host nobody configured is not offered a retry',
        (tester) async {
      await pump(
        tester,
        const ManagementRequestException(
          '读取记忆库',
          statusCode: 503,
          refusal: Refusal(
            kind: 'not_configured',
            reason: 'Admin memory service credential is not configured',
          ),
        ),
      );

      expect(find.text('这台主机还没配好它记住的，要先在主机上补齐配置'),
          findsOneWidget);
      expect(find.byKey(const Key('retry')), findsNothing,
          reason: 'a retry that cannot work is a promise the product breaks');
      // The Host's own words stay visible: whoever owns this machine is usually
      // the person holding the phone, and this is what they can search for.
      expect(
        find.text('Admin memory service credential is not configured'),
        findsOneWidget,
      );
    });

    testWidgets('a service that has not started is offered a retry',
        (tester) async {
      await pump(
        tester,
        const ManagementRequestException(
          '读取记忆库',
          statusCode: 503,
          refusal: Refusal(
            kind: 'not_running',
            reason: 'this memory space is not running',
            retryable: true,
          ),
        ),
      );

      expect(find.text('它记住的现在没有响应，可能还没启动'), findsOneWidget);
      expect(find.byKey(const Key('retry')), findsOneWidget);
    });

    testWidgets('a refusal about what I just did does not relay plumbing',
        (tester) async {
      await pump(
        tester,
        const ManagementRequestException(
          '设为默认',
          statusCode: 409,
          refusal: Refusal(
            kind: 'conflict',
            reason: 'owner revision 7 is stale',
          ),
        ),
      );

      expect(find.text('有人先改过了，这里看到的已经不是最新的'), findsOneWidget);
      expect(find.text('owner revision 7 is stale'), findsNothing);
    });

    testWidgets('a Host with no Owner is sent to setup, not to a retry',
        (tester) async {
      await pump(
        tester,
        const ManagementRequestException(
          '读取记忆库',
          statusCode: 409,
          refusal: Refusal(
            kind: 'not_configured',
            code: 'host_not_provisioned',
          ),
        ),
      );

      expect(find.text('这台主机还没有主人，先完成设置'), findsOneWidget);
      expect(find.byKey(const Key('retry')), findsNothing);
    });
  });

  group('the wording lives in one place', () {
    test('no screen words a load refusal itself', () {
      // Read from the sources, because the failure is a line that compiles.
      // Ten screens each printing `'$_error'` is how 被拒绝 with nothing after
      // it became this app's answer to every kind of no.
      final offenders = <String>[];
      for (final file in Directory('lib/src/management')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        if (file.path.endsWith('refusal_notice.dart')) continue;
        if (file.path.endsWith('management_client.dart')) continue;
        if (source.contains(r"Text('$_error'")) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'render a RefusalNotice instead of printing the exception',
      );
    });

    test('every kind this app knows has a sentence of its own', () {
      // A kind that fell through to `'$error'` would put an exception on screen
      // — which is what this whole change is removing.
      const kinds = [
        'denied',
        'not_found',
        'conflict',
        'invalid',
        'not_configured',
        'not_running',
        'upstream',
      ];
      final sentences = <String>{};
      for (final kind in kinds) {
        final text = refusalText(
          ManagementRequestException('做某事', refusal: Refusal(kind: kind)),
          subject: '它记住的',
        );
        expect(text, isNot(contains('ManagementRequestException')), reason: kind);
        sentences.add(text);
      }
      expect(sentences, hasLength(kinds.length),
          reason: 'two kinds sharing a sentence is two kinds folded');
    });

    test('a kind from a newer Host degrades instead of failing', () {
      // Forgiving on purpose: the phone updates on its own schedule and the Host
      // on another, so a kind this build has not heard of must still read.
      final text = refusalText(
        const ManagementRequestException(
          '做某事',
          refusal: Refusal(kind: 'something_new', reason: 'the Host explained'),
        ),
        subject: '它记住的',
      );
      expect(text, contains('the Host explained'));
    });
  });
}
