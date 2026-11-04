import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';

void main() {
  testWidgets('household memory stays as the Owner set it', (tester) async {
    final writes = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        if (suffix.startsWith('/memory-policy')) {
          if (method == 'PUT') writes.add(body!);
          return {
            'owner_id': 'o',
            'owner_revision': 3,
            'policy': {
              'candidate': {'save_allowed': true, 'session_recall_allowed': false},
              'prepare_on_promotion': true,
              'household_memory': false,
            },
          };
        }
        return {'persons': []};
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('记忆设置'));
    await tester.pumpAndSettle();
    final household = find.byKey(const ValueKey('defaults-household'));
    expect(tester.widget<SwitchListTile>(household).value, isFalse);
    // Unknown voices are the next phase: nothing here sets them.
    expect(find.byKey(const ValueKey('defaults-save')), findsNothing);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // Saving keeps the household layer as the Owner set it, and the rest as it came.
    expect(writes.single, {
      'candidate': {'save_allowed': true, 'session_recall_allowed': false},
      'prepare_on_promotion': true,
      'household_memory': false,
    });
  });

  testWidgets('the persons page opens the household memory', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async => {'persons': []},
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
      openHouseholdMemory: () async => opened++,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('household-memory')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('家里的记忆'), findsOneWidget);
  });

  for (final outcome in ['save', 'cancel', 'conflict']) {
    testWidgets('the household switch saves through the memory policy: $outcome', (tester) async {
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
      await tester.tap(find.byTooltip('记忆设置'));
      await tester.pumpAndSettle();
      final household = find.byKey(const ValueKey('defaults-household'));
      expect(tester.widget<SwitchListTile>(household).value, isTrue);
      await tester.tap(household);
      await tester.pumpAndSettle();
      await tester.tap(find.text(outcome == 'cancel' ? '取消' : '保存'));
      await tester.pumpAndSettle();
      if (outcome == 'cancel') {
        expect(writes, isEmpty);
      } else {
        expect(writes.single, {
          'candidate': {'save_allowed': false, 'session_recall_allowed': true},
          'prepare_on_promotion': false,
          'household_memory': false,
        });
        expect(calls, contains('PUT /memory-policy?expected_revision=7'));
        expect(calls.where((call) => call == 'GET ').length, 2);
      }
      if (outcome == 'conflict') {
        expect(find.text('操作未确认，请刷新或重试'), findsOneWidget);
        await tester.tap(find.byTooltip('记忆设置'));
        await tester.pumpAndSettle();
        // Reopening fetches authority again instead of reusing the rejected revision.
        expect(calls.where((call) => call == 'GET /memory-policy').length, 2);
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(calls, contains('PUT /memory-policy?expected_revision=8'));
      }
      expect(calls.where((call) => call.contains('/memory-realm')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
