import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/tasks_page.dart';
import 'package:eidolon_client_mobile/src/management/tasks_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 交给它的事 — what I asked it to do, and whether it did.
///
/// The task state machine lives on the Host, so what this app must not do is
/// hold an opinion about it. The tests are mostly about that: an unfamiliar
/// state still shows (and still counts as running), an action reports what the
/// Host said rather than what was hoped, and a refusal — the task finished while
/// the page was open — is a sentence rather than a failure of the app.

Map<String, dynamic> taskWire({
  String taskId = 'j-1',
  String status = 'running',
  String asked = '帮我查一下周末的天气',
  String progress = '在看了',
  String result = '',
  String errorMessage = '',
}) => {
      'task_id': taskId,
      'status': status,
      'asked': asked,
      'kind': 'research',
      'urgency': 'normal',
      'expected_output': '一句话',
      'progress': progress,
      'result': result,
      'error_code': errorMessage.isEmpty ? '' : 'worker_error',
      'error_message': errorMessage,
      'created_at': '2026-08-24T09:00:00+00:00',
      'updated_at': '2026-08-24T09:05:00+00:00',
      'completed_at': null,
    };

TaskPageView page({List<Map<String, dynamic>>? tasks, String? cursor}) =>
    TaskPageView.fromJson({
      'contract_version': '1',
      'companion_id': 'companion-a',
      'tasks': tasks ?? [taskWire()],
      'next_cursor': cursor,
    });

http.Response _hostAnswer(Map<String, dynamic> body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  group('the tasks client', () {
    test('asks the companion route and names no subject', () async {
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer({
            'contract_version': '1',
            'companion_id': 'companion-a',
            'tasks': [taskWire()],
            'next_cursor': null,
          });
        }),
      );

      final answer = await client.fetchTasks(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
      );

      expect(asked?.path, '/api/management/v1/companions/companion-a/tasks');
      expect(asked?.queryParameters, isEmpty);
      expect(answer.tasks.single.asked, '帮我查一下周末的天气');
    });

    test('sends only the parameters it was given', () async {
      // An empty limit is not a number and an empty cursor is not a position.
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer({
            'contract_version': '1',
            'companion_id': 'companion-a',
            'tasks': const [],
            'next_cursor': null,
          });
        }),
      );

      await client.fetchTasks(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
        status: 'running',
        cursor: '2026-08-24T09:00:00+00:00',
      );

      expect(asked?.queryParameters.keys.toSet(), {'status', 'cursor'});
    });

    test('the two actions are posts to their own routes', () async {
      final seen = <String>[];
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          seen.add('${request.method} ${request.url.path}');
          return _hostAnswer(taskWire(status: 'cancelled'));
        }),
      );

      await client.cancelTask(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
        taskId: 'j-1',
      );
      await client.retryTask(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
        taskId: 'j-1',
      );

      expect(seen, [
        'POST /api/management/v1/companions/companion-a/tasks/j-1/cancel',
        'POST /api/management/v1/companions/companion-a/tasks/j-1/retry',
      ]);
    });
  });

  group('the tasks page', () {
    testWidgets('says where a task is, in words', (tester) async {
      await tester.pumpWidget(MaterialApp(home: TasksPage(page: page())));

      expect(find.text('帮我查一下周末的天气'), findsOneWidget);
      expect(find.text('正在做'), findsOneWidget);
    });

    testWidgets('shows a state it has never heard of rather than hiding it',
        (tester) async {
      // A task in an unfamiliar state is running somewhere. Dropping the row
      // would make it vanish while it worked.
      await tester.pumpWidget(
        MaterialApp(
          home: TasksPage(
            page: page(tasks: [taskWire(status: 'paused_for_review')]),
            onCancel: (_) {},
            onRetry: (_) {},
          ),
        ),
      );

      expect(find.byKey(const Key('task-j-1')), findsOneWidget);
      expect(find.text('状态：paused_for_review'), findsOneWidget);
      // Treated as still going: 别做了 is offered, 再试一次 is not.
      expect(find.byKey(const Key('task-cancel-j-1')), findsOneWidget);
      expect(find.byKey(const Key('task-retry-j-1')), findsNothing);
    });

    testWidgets('offers stopping while it runs and retrying once it failed',
        (tester) async {
      for (final (status, cancel, retry) in [
        ('running', true, false),
        ('failed', false, true),
        ('succeeded', false, false),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: TasksPage(
              key: ValueKey(status),
              page: page(tasks: [taskWire(status: status)]),
              onCancel: (_) {},
              onRetry: (_) {},
            ),
          ),
        );

        expect(
          find.byKey(const Key('task-cancel-j-1')),
          cancel ? findsOneWidget : findsNothing,
          reason: 'cancel for $status',
        );
        expect(
          find.byKey(const Key('task-retry-j-1')),
          retry ? findsOneWidget : findsNothing,
          reason: 'retry for $status',
        );
      }
    });

    testWidgets('offers nothing to press when the Host promised nothing',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: TasksPage(page: page())));

      expect(find.byKey(const Key('task-cancel-j-1')), findsNothing);
      expect(find.byKey(const Key('task-retry-j-1')), findsNothing);
    });

    testWidgets('shows the answer when there is one, and the reason when it broke',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TasksPage(
            page: page(
              tasks: [
                taskWire(status: 'succeeded', result: '周末多云，21 度'),
                taskWire(
                  taskId: 'j-2',
                  status: 'failed',
                  errorMessage: '天气服务没有回应',
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('周末多云，21 度'), findsOneWidget);
      expect(find.text('天气服务没有回应'), findsOneWidget);
    });

    testWidgets('a quiet list is said plainly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: TasksPage(page: page(tasks: []))),
      );

      expect(find.byKey(const Key('tasks-empty')), findsOneWidget);
    });
  });

  group('the tasks screen', () {
    testWidgets('reports what the Host says a task became', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TasksScreen(
            load: (_) async => page(),
            cancel: (_) async => TaskView.fromJson(taskWire(status: 'cancelled')),
            retry: (_) async => TaskView.fromJson(taskWire(status: 'accepted')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-cancel-j-1')));
      await tester.pumpAndSettle();

      expect(find.text('已经停下了'), findsOneWidget);
    });

    testWidgets('a refusal is shown as the Host phrased it', (tester) async {
      // The common case, and not a fault: the task finished while the page was
      // open.
      await tester.pumpWidget(
        MaterialApp(
          home: TasksScreen(
            load: (_) async => page(),
            cancel: (_) => Future.error(
              const ManagementRequestException(
                '拒绝',
                statusCode: 409,
                refusal: Refusal(
                  kind: 'conflict',
                  reason: 'long task already finished as succeeded',
                ),
              ),
            ),
            retry: (_) async => TaskView.fromJson(taskWire(status: 'accepted')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-cancel-j-1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('already finished'), findsOneWidget);
    });

    testWidgets('re-reads after an action rather than patching the row',
        (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TasksScreen(
            load: (_) async {
              reads++;
              return page();
            },
            cancel: (_) async => TaskView.fromJson(taskWire(status: 'cancelled')),
            retry: (_) async => TaskView.fromJson(taskWire(status: 'accepted')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);

      await tester.tap(find.byKey(const Key('task-cancel-j-1')));
      await tester.pumpAndSettle();

      expect(reads, 2);
    });

    testWidgets('a list it could not read is not an empty list', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TasksScreen(
            load: (_) => Future.error(
              const ManagementRequestException('读取失败', statusCode: 503),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tasks-error')), findsOneWidget);
      expect(find.byKey(const Key('tasks-empty')), findsNothing);
    });

    testWidgets('offers no action when only half of it is wired', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TasksScreen(
            load: (_) async => page(),
            cancel: (_) async => TaskView.fromJson(taskWire(status: 'cancelled')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('task-cancel-j-1')), findsNothing);
    });
  });
}
