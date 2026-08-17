import 'package:eidolon_client_mobile/src/features/host_setup/recollection_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/recollections_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Recollections _answer(String query, List<Recollection> items) =>
    Recollections(query: query, items: items);

Future<void> _open(
  WidgetTester tester,
  Future<Recollections> Function(String query) onSearch,
) => tester.pumpWidget(
  MaterialApp(
    home: RecollectionsPage(companionName: '小忆', onSearch: onSearch),
  ),
);

Future<void> _ask(WidgetTester tester, String question) async {
  await tester.enterText(
    find.byKey(const Key('recollection-question')),
    question,
  );
  await tester.tap(find.byKey(const Key('ask-recollections')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens empty rather than showing a sample of someone\'s life', (
    tester,
  ) async {
    await _open(tester, (_) async => _answer('', const []));
    expect(find.byKey(const Key('recollections-idle')), findsOneWidget);
  });

  testWidgets('an answer is shown as sentences', (tester) async {
    await _open(
      tester,
      (query) async => _answer(query, [
        Recollection(
          text: '他喜欢在下午散步',
          rememberedAt: DateTime.utc(2026, 8, 16, 9, 30),
        ),
        const Recollection(text: '没有时间的那一条'),
      ]),
    );

    await _ask(tester, '散步');

    expect(find.text('他喜欢在下午散步'), findsOneWidget);
    expect(find.text('没有时间的那一条'), findsOneWidget);
    // A missing time is left missing, not filled in with the time of asking.
    expect(find.textContaining('年'), findsOneWidget);
  });

  testWidgets('an empty question is not asked at all', (tester) async {
    var asked = 0;
    await _open(tester, (query) async {
      asked += 1;
      return _answer(query, const []);
    });

    await _ask(tester, '   ');

    expect(asked, 0);
    expect(find.byKey(const Key('recollections-idle')), findsOneWidget);
  });

  testWidgets('nothing remembered says so, naming what was asked', (
    tester,
  ) async {
    await _open(tester, (query) async => _answer(query, const []));

    await _ask(tester, '滑雪');

    expect(find.byKey(const Key('recollections-empty')), findsOneWidget);
    expect(find.textContaining('滑雪'), findsWidgets);
  });

  testWidgets('a failure is not shown as an empty memory', (tester) async {
    await _open(tester, (_) async => throw StateError('主机暂时不可用'));

    await _ask(tester, '散步');

    // "It does not remember that" and "it could not be asked" are different
    // things to be told about your own life.
    expect(find.byKey(const Key('recollections-failure')), findsOneWidget);
    expect(find.byKey(const Key('recollections-empty')), findsNothing);
  });

  group('what the Host answered', () {
    test('a record without text is refused rather than shown blank', () {
      expect(
        () => Recollection.fromJson({'remembered_at': '2026-08-16T09:30:00Z'}),
        throwsFormatException,
      );
      expect(
        () => Recollections.fromJson({'query': 'x'}),
        throwsFormatException,
      );
    });

    test('an unparseable time leaves the record without one', () {
      final recollection = Recollection.fromJson({
        'text': '他喜欢在下午散步',
        'remembered_at': 'not a time',
      });

      expect(recollection.text, '他喜欢在下午散步');
      expect(recollection.rememberedAt, isNull);
    });
  });
}
