import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';

void main() {
  testWidgets('candidate retirement keeps person and disables broad recall',
      (tester) async {
    var retained = false;
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        calls.add('$method $suffix');
        if (suffix == '/archived') return {'persons': []};
        if (suffix.endsWith('/memory-state')) {
          return {'state': 'inactive', 'person_revision': retained ? 2 : 1};
        }
        if (suffix.contains('/recognition/retire')) retained = true;
        return {
          'persons': [
            {
              'person_id': 'p',
              'owner_id': 'o',
              'display_name': '未命名用户',
              'status': 'active',
              'revision': retained ? 2 : 1,
              'profile': <String, dynamic>{},
              'maturity': 'candidate',
              'is_named': false,
              'recognition_state': retained ? 'retained' : 'active',
            }
          ]
        };
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('候选 · 匿名'), findsOneWidget);
    final toggle = find.byKey(const ValueKey('memory-p'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    final menu = find.byTooltip('未命名用户的更多操作');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出匹配池（保留数据）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出匹配'));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /p/recognition/retire?expected_revision=1'));
    expect(find.text('未命名用户'), findsOneWidget);
    expect(find.textContaining('已退出匹配池'), findsOneWidget);
    expect(calls.where((c) => c.contains('/archive?')), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
