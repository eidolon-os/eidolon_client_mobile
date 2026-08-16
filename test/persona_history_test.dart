import 'package:eidolon_client_mobile/src/features/host_setup/persona_history_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persona_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PersonaHistory _history({String firstSummary = '我发现你不喜欢被打断'}) =>
    PersonaHistory.fromJson({
      'companion_id': 'c_1',
      'chapters': [
        {
          'chapter_id': 'g_2',
          'changed_at': '2026-08-14T02:00:00Z',
          'what_changed': firstSummary,
          'restored_from': null,
          'is_current': true,
        },
        {
          'chapter_id': 'g_1',
          'changed_at': '2026-08-09T08:00:00Z',
          'what_changed': '',
          'restored_from': null,
          'is_current': false,
        },
      ],
    });

Future<void> _open(
  WidgetTester tester, {
  PersonaHistory? history,
  Future<PersonaHistory> Function(String chapterId)? restore,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PersonaHistoryPage(
        companionName: '小忆',
        loadHistory: () async => history ?? _history(),
        restore: restore ?? (_) async => throw StateError('must not restore'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows what it became, in the words recorded with the change',
      (tester) async {
    await _open(tester);

    expect(find.text('我发现你不喜欢被打断'), findsOneWidget);
    expect(find.text('现在的它'), findsOneWidget);
  });

  testWidgets('admits a gap rather than inventing a reason', (tester) async {
    // A sentence about who your Eidolon became should not be composed by the
    // screen from a diff it happens to have. Saying nothing was recorded is
    // honest; "人格已更新" would be filler dressed as meaning.
    await _open(tester);

    // The oldest entry is where it started, not a change that lost its note:
    // whatever a creation flow wrote there is machinery, not its own words.
    expect(find.text('它刚来的时候'), findsOneWidget);
    expect(find.textContaining('Initial persona genome'), findsNothing);
  });

  testWidgets('there is nothing to approve, only somewhere to go back to',
      (tester) async {
    await _open(tester);

    // The page says 不需要你批准 out loud, so the absence being asserted is
    // of the actions, not the word: there is no button that approves or
    // rejects a change, because there is no queue to work through.
    expect(find.widgetWithText(FilledButton, '批准'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '批准'), findsNothing);
    expect(find.widgetWithText(TextButton, '驳回'), findsNothing);
    expect(find.text('回到那时候'), findsOneWidget);
    // The one it already is has no way back to itself.
    expect(find.byKey(const Key('restore-persona-g_2')), findsNothing);
    expect(find.byKey(const Key('restore-persona-g_1')), findsOneWidget);
  });

  testWidgets('going back says what it costs before it happens',
      (tester) async {
    String? restored;
    await _open(
      tester,
      restore: (chapterId) async {
        restored = chapterId;
        return _history();
      },
    );

    await tester.tap(find.byKey(const Key('restore-persona-g_1')));
    await tester.pumpAndSettle();

    final dialog = tester.widget<AlertDialog>(
      find.byKey(const Key('confirm-persona-restore')),
    );
    final content = (dialog.content! as Text).data!;
    // How many changes stop applying, and that none of them are lost.
    expect(content, contains('1 次变化不再生效'));
    expect(content, contains('这些记录不会消失'));
    expect(restored, isNull);

    await tester.tap(find.byKey(const Key('confirm-persona-restore-action')));
    await tester.pumpAndSettle();

    expect(restored, 'g_1');
  });

  testWidgets('a Host that refuses says so instead of emptying the history',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PersonaHistoryPage(
          companionName: '小忆',
          loadHistory: () async => throw StateError('主机拒绝了这次请求'),
          restore: (_) async => throw StateError('must not restore'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('persona-history-error')), findsOneWidget);
    expect(find.byKey(const Key('persona-history-empty')), findsNothing);
  });

  testWidgets('does not promise growth that is not happening yet',
      (tester) async {
    // Nothing in the runtime proposes an evolution today: the machinery is
    // built and wired, and no product path ever triggers it. A page saying
    // 它会慢慢变化 would be promising something the product does not do.
    await _open(
      tester,
      history: PersonaHistory.fromJson({
        'companion_id': 'c_1',
        'chapters': [
          {
            'chapter_id': 'g_1',
            'changed_at': '2026-08-09T08:00:00Z',
            'what_changed': '',
            'restored_from': null,
            'is_current': true,
          },
        ],
      }),
    );

    expect(find.textContaining('目前它还是刚来时的样子'), findsOneWidget);
    expect(find.textContaining('它变化的时候不需要你批准'), findsOneWidget);
  });

  testWidgets('and stops saying it once it has changed', (tester) async {
    await _open(tester);

    expect(find.textContaining('目前它还是刚来时的样子'), findsNothing);
  });

  group('what the Host says and what the screen may add', () {
    test('a chapter carries no version, hash or schema to leak', () {
      final chapter = _history().chapters.first;

      expect(chapter.chapterId, 'g_2');
      expect(chapter.isCurrent, isTrue);
      expect(chapter.restoredFrom, isNull);
    });

    test('a shape the Host is not supposed to send is refused', () {
      expect(
        () => PersonaChapter.fromJson({
          'chapter_id': 'g_1',
          'changed_at': 'not-a-time',
          'what_changed': '',
          'restored_from': null,
          'is_current': false,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

