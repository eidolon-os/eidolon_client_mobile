import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';

void main() {
  testWidgets('OS person can be managed and open voiceprints without Companion',
      (tester) async {
    final requests = <String>[];
    var status = 'active';
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        requests.add('$method $suffix');
        if (method == 'PUT') status = body!['status'] as String;
        final person = {
          'person_id': 'person',
          'owner_id': 'owner',
          'display_name': '甲',
          'revision': 1,
          'status': status,
          'profile': <String, dynamic>{}
        };
        return method == 'GET'
            ? {
                'persons': [person]
              }
            : person;
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(find.text('已停用 · 不参与辅助识别'), findsOneWidget);
    expect(requests, contains('PUT /person'));
    await tester.tap(find.text('声纹管理'));
    await tester.pumpAndSettle();
    expect(find.text('声纹用于辅助识别用户，不限制对话。'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('uncertain creation retries the same person id and profile',
      (tester) async {
    final creates = <Map<String, dynamic>>[];
    final people = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        if (method == 'GET') return {'persons': people};
        creates.add(Map<String, dynamic>.from(body!));
        if (creates.length == 1) throw Exception('reply lost');
        people.add(
            {...body, 'owner_id': 'owner', 'status': 'active', 'revision': 1});
        return people.last;
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加用户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Alice');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('重试确认添加用户'), findsOneWidget);
    await tester.tap(find.text('重试确认添加用户'));
    await tester.pumpAndSettle();
    expect(creates.length, 2);
    expect(creates[0], creates[1]);
    expect(creates.first['person_id'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('重试确认添加用户'), findsNothing);
  });
}
