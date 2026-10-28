import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';

void main() {
  for (final outcome in ['save', 'cancel', 'conflict']) {
    testWidgets('Owner defaults remain independent: $outcome', (tester) async {
      final calls = <String>[];
      final writes = <Map<String, dynamic>>[];
      var revision = 7;
      await tester.pumpWidget(MaterialApp(
          home: PersonsPage(
        call: ({method = 'GET', suffix = '', body}) async {
          calls.add('$method $suffix');
          if (suffix.startsWith('/memory-policy')) {
            if (method == 'PUT') {
              writes.add(body!);
              if (outcome == 'conflict') {
                revision = 8;
                throw StateError('revision changed');
              }
            }
            return {
              'owner_id': 'o',
              'owner_revision': revision,
              'policy': {
                'candidate': {
                  'save_allowed': false,
                  'session_recall_allowed': true
                },
                'prepare_on_promotion': false,
              },
            };
          }
          return {'persons': []};
        },
        voiceprints: ({method = 'GET', suffix = '', body}) async =>
            {'profiles': []},
      )));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.contains('memory-policy')), isEmpty);
      await tester.tap(find.byTooltip('自动记忆策略'));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('defaults-save'));
      final recall = find.byKey(const ValueKey('defaults-recall'));
      final prepare = find.byKey(const ValueKey('defaults-prepare'));
      expect(tester.widget<SwitchListTile>(save).value, isFalse);
      expect(tester.widget<SwitchListTile>(recall).value, isTrue);
      expect(tester.widget<SwitchListTile>(prepare).value, isFalse);
      for (final control in [save, recall, prepare]) {
        await tester.ensureVisible(control);
        await tester.tap(control);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(outcome == 'cancel' ? '取消' : '保存策略'));
      await tester.pumpAndSettle();
      if (outcome == 'cancel') {
        expect(writes, isEmpty);
      } else {
        expect(writes.single, {
          'candidate': {'save_allowed': true, 'session_recall_allowed': false},
          'prepare_on_promotion': true,
        });
        expect(calls, contains('PUT /memory-policy?expected_revision=7'));
        expect(calls.where((call) => call == 'GET ').length, 2);
      }
      if (outcome == 'conflict') {
        expect(find.text('操作未确认，请刷新或重试'), findsOneWidget);
        await tester.tap(find.byTooltip('自动记忆策略'));
        await tester.pumpAndSettle();
        // Reopening fetches authority again instead of reusing the rejected revision.
        expect(calls.where((call) => call == 'GET /memory-policy').length, 2);
        await tester.tap(find.text('保存策略'));
        await tester.pumpAndSettle();
        expect(calls, contains('PUT /memory-policy?expected_revision=8'));
      }
      expect(calls.where((call) => call.contains('/memory-realm')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
