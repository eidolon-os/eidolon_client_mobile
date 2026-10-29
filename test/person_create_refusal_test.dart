import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

void main() {
  testWidgets('create validation failure is not displayed as permission denial',
      (tester) async {
    Map<String, dynamic>? submitted;
    final client = ManagementClient(httpClient: MockClient((request) async {
      if (request.method == 'POST') {
        submitted = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'detail': [
          {'type': 'extra_forbidden', 'loc': ['body', 'is_named'],
            'msg': 'Extra inputs are not permitted'}
        ]}), 422);
      }
      return http.Response('{"persons":[]}', 200);
    }));
    await tester.pumpWidget(MaterialApp(home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) => client.personRequest(
        Uri.parse('https://host.test'), accessToken: 'test',
        method: method, suffix: suffix, body: body),
      voiceprints: ({method = 'GET', suffix = '', body}) async => {'profiles': []},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加用户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '测试用户');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(submitted?['is_named'], isTrue);
    expect(submitted?['person_id'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(find.text('主机没有接受这次请求'), findsOneWidget);
    expect(find.text('管理用户被拒绝'), findsNothing);
    expect(find.textContaining('管理授权已经失效'), findsNothing);
  });
}
