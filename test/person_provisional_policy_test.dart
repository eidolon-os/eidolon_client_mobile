import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';

void main() {
  for (final cancel in [false, true]) {
    testWidgets('provisional policy independent controls cancel=$cancel',
        (tester) async {
      final writes = <Map<String, dynamic>>[];
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(
          home: PersonsPage(
        call: ({method = 'GET', suffix = '', body}) async {
          calls.add('$method $suffix');
          if (suffix == '/archived') return {'persons': []};
          if (suffix.contains('/provisional-memory/policy')) {
            if (method == 'PUT') writes.add(body!);
            return {
              'owner_id': 'o',
              'person_id': 'p',
              'person_revision': 7,
              'realm_id': 'r',
              'policy': {'save_allowed': false, 'session_recall_allowed': true}
            };
          }
          if (suffix.endsWith('/memory-state')) {
            return {'state': 'inactive', 'person_revision': 1};
          }
          return {
            'persons': [
              {
                'person_id': 'p',
                'owner_id': 'o',
                'display_name': '候选用户',
                'revision': 1,
                'status': 'active',
                'maturity': 'candidate',
                'is_named': false,
                'profile': <String, dynamic>{}
              }
            ]
          };
        },
        voiceprints: ({method = 'GET', suffix = '', body}) async =>
            {'profiles': []},
      )));
      await tester.pumpAndSettle();
      expect(
          calls.where((call) => call.contains('provisional-memory')), isEmpty);
      final menu = find.byTooltip('候选用户的更多操作');
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂定数据许可'));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('provisional-save'));
      final recall = find.byKey(const ValueKey('provisional-recall'));
      expect(tester.widget<SwitchListTile>(save).value, isFalse);
      expect(tester.widget<SwitchListTile>(recall).value, isTrue);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(recall);
      await tester.pumpAndSettle();
      await tester.tap(find.text(cancel ? '取消' : '保存许可'));
      await tester.pumpAndSettle();
      if (cancel) {
        expect(writes, isEmpty);
      } else {
        expect(writes.single,
            {'save_allowed': true, 'session_recall_allowed': false});
        expect(calls,
            contains('PUT /p/provisional-memory/policy?expected_revision=7'));
      }
      expect(calls.where((call) => call.contains('/memory-realm')), isEmpty);
      final broad = find.byKey(const ValueKey('memory-p'));
      await tester.ensureVisible(broad);
      expect(tester.widget<Switch>(broad).onChanged, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
