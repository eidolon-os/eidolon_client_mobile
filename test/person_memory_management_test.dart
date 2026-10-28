import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
      'every memory operation carries explicit Person and never a caller Owner',
      () async {
    final seen = <Uri>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen.add(request.url);
      expect(request.headers['authorization'], 'Bearer token');
      return http.Response('{}', 503);
    }));
    final base = Uri.parse('https://host/');
    const p = 'person a/?';
    final calls = <Future<dynamic> Function()>[
      () => client.fetchMemoryLibrary(base, accessToken: 'token', personId: p),
      () => client.fetchMemoryGraph(base, accessToken: 'token', personId: p),
      () => client.fetchMemoryEntries(base,
          accessToken: 'token', personId: p, since: DateTime(2026)),
      () => client.fetchMemoryCopy(base, accessToken: 'token', personId: p),
      () => client.fetchRecollections(base,
          accessToken: 'token', personId: p, query: 'test'),
      () => client.previewForget(base,
          accessToken: 'token', personId: p, target: 'test'),
      () => client.confirmForget(base,
          accessToken: 'token', personId: p, confirmationToken: 'proof'),
      () => client.forgetStatus(base,
          accessToken: 'token', personId: p, requestId: 'request'),
    ];
    for (final call in calls) {
      try {
        await call();
      } on ManagementRequestException {/* Expected test response. */}
    }
    expect(seen.length, 8);
    for (final url in seen) {
      expect(url.queryParameters['person_id'], p);
      expect(url.queryParameters.containsKey('owner_id'), false);
    }
  });

  testWidgets(
      'archived Person can manage memory and restore without granting voice identity',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];
    var archived = true;
    final person = <String, dynamic>{
      'person_id': 'p',
      'owner_id': 'o',
      'display_name': 'Alice',
      'status': 'inactive',
      'revision': 7,
      'profile': <String, dynamic>{}
    };
    String? opened;
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
            openMemory: (p) async {
              opened = p.personId;
            },
            voiceprints: (
                    {String method = 'GET',
                    String suffix = '',
                    Map<String, dynamic>? body}) async =>
                {'profiles': []},
            call: (
                {String method = 'GET',
                String suffix = '',
                Map<String, dynamic>? body}) async {
              calls.add('$method $suffix');
              if (suffix == '/archived')
                return {
                  'persons': archived ? [person] : []
                };
              if (method == 'POST') {
                archived = false;
                return person;
              }
              return {'persons': []};
            })));
    await tester.pumpAndSettle();
    expect(find.text('已归档用户'), findsOneWidget);
    await tester.tap(find.text('查看记忆'));
    await tester.pumpAndSettle();
    expect(opened, 'p');
    await tester.tap(find.text('恢复归档'));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /p/restore?expected_revision=7'));
    expect(calls.where((c) => c.contains('/memory-realm/restore')), isEmpty);
    expect(find.text('已归档用户'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unidentified memory has details, no restore, and retryable permanent deletion',
      (tester) async {
    var pending = false;
    var removed = false;
    var requests = 0;
    final person = <String, dynamic>{
      'person_id': 'abcdef123',
      'owner_id': 'o',
      'display_name': '旧占位名称',
      'status': 'inactive',
      'revision': 1,
      'profile': <String, dynamic>{},
      'identity_state': 'missing'
    };
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
            voiceprints: (
                    {String method = 'GET',
                    String suffix = '',
                    Map<String, dynamic>? body}) async =>
                {'profiles': []},
            call: (
                {String method = 'GET',
                String suffix = '',
                Map<String, dynamic>? body}) async {
              if (suffix == '/archived')
                return {
                  'persons': removed
                      ? []
                      : [
                          {
                            ...person,
                            'revision': pending ? 2 : 1,
                            'deletion_state': pending ? 'pending' : 'none'
                          }
                        ]
                };
              if (suffix.contains('/permanent-delete?')) {
                requests++;
                if (!pending) {
                  pending = true;
                  throw StateError('connection lost');
                }
                expect(
                    suffix, '/abcdef123/permanent-delete?expected_revision=2');
                removed = true;
                return {'state': 'completed'};
              }
              return {'persons': []};
            })));
    await tester.pumpAndSettle();
    expect(find.text('身份资料缺失的保留记忆'), findsOneWidget);
    expect(find.text('恢复归档'), findsNothing);
    await tester.tap(find.text('保留记忆 · abcdef'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原姓名和人物资料已被旧版本删除'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除').last);
    await tester.pumpAndSettle();
    expect(find.text('永久删除未完成 · 请重试'), findsOneWidget);
    expect(find.text('恢复归档'), findsNothing);
    await tester.tap(find.text('重试永久删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除').last);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('保留记忆 · abcdef'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
