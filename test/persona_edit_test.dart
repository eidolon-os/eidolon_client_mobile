import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/persona_edit_page.dart';

/// Changing who an Eidolon is, after it has been someone.
///
/// What this screen must not do is bigger than what it does. It edits the one
/// thing about a Companion that used to be unchangeable, so a field it drops is
/// a sentence somebody wrote about their Eidolon that quietly stops being true.
void main() {
  PersonaAuthoring standing() => const PersonaAuthoring(
        archetype: 'companion',
        selfConcept: '我原本是这样',
        characterPortrait: '安静',
        relationshipNarrative: '从一次深夜对话开始',
        voicePortrait: '短句',
        values: ['诚实'],
        boundaries: ['不替他做决定'],
        commitments: ['每周问一次'],
        pinnedFacts: ['他有一只猫'],
        safetyBoundaries: ['不提他父亲'],
        behaviorGuidance: ['先问再答'],
        dialogueExamples: ['「今天怎么样？」'],
        modalityNotes: {'voice': '慢一点'},
      );

  Future<PersonaAuthoring?> pumpAndSave(
    WidgetTester tester, {
    required Future<void> Function(WidgetTester tester) edit,
  }) async {
    PersonaAuthoring? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: PersonaEditPage(
          displayName: '小南',
          standing: standing(),
          onSave: (authored) async => saved = authored,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await edit(tester);
    await tester.tap(find.byKey(const Key('persona-edit-save')));
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('opens on who it currently is, not on blanks', (tester) async {
    // The whole safety of saving rests on this. A form that opened on anything
    // else would replace everything the person did not retype with whatever it
    // happened to be showing.
    await tester.pumpWidget(
      MaterialApp(
        home: PersonaEditPage(
          displayName: '小南',
          standing: standing(),
          onSave: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我原本是这样'), findsOneWidget);
    expect(find.text('诚实'), findsOneWidget);
    expect(find.text('他有一只猫'), findsOneWidget);
  });

  testWidgets('changing one sentence leaves every other one alone',
      (tester) async {
    // The failure this guards against is silent: the edit works, the screen
    // says saved, and three other things the person wrote are gone.
    final saved = await pumpAndSave(
      tester,
      edit: (tester) async {
        await tester.enterText(
          find.byKey(const Key('authoring-self-concept')),
          '我现在是这样',
        );
        await tester.pumpAndSettle();
      },
    );

    expect(saved, isNotNull);
    expect(saved!.selfConcept, '我现在是这样');
    expect(saved.characterPortrait, '安静');
    expect(saved.values, ['诚实']);
    expect(saved.pinnedFacts, ['他有一只猫']);
    expect(saved.dialogueExamples, ['「今天怎么样？」']);
    // Not on the form at all, and still on the way back: absence from a screen
    // is not absence from the Eidolon.
    expect(saved.modalityNotes, {'voice': '慢一点'});
    expect(saved.archetype, 'companion');
  });

  testWidgets('saving is inert until something actually changes',
      (tester) async {
    // Pressing save on an untouched form would either do nothing while looking
    // like it did something, or add a chapter to the record for a non-event.
    await tester.pumpWidget(
      MaterialApp(
        home: PersonaEditPage(
          displayName: '小南',
          standing: standing(),
          onSave: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('persona-edit-unchanged')), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('persona-edit-save')))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('authoring-self-concept')),
      '改了',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('persona-edit-unchanged')), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('persona-edit-save')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('adding one line to a list keeps the ones already there',
      (tester) async {
    final saved = await pumpAndSave(
      tester,
      edit: (tester) async {
        await tester.enterText(find.byKey(const Key('authoring-values')), '守时');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      },
    );

    expect(saved!.values, ['诚实', '守时']);
  });

  testWidgets('removing a line removes only that one', (tester) async {
    final saved = await pumpAndSave(
      tester,
      edit: (tester) async {
        await tester.enterText(find.byKey(const Key('authoring-values')), '守时');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('remove-line-诚实')));
        await tester.pumpAndSettle();
      },
    );

    expect(saved!.values, ['守时']);
  });

  testWidgets('a refusal stays on the form, next to what was written',
      (tester) async {
    // Popping back to the Eidolon's page would take the words away from the
    // person at the moment they need to see them.
    await tester.pumpWidget(
      MaterialApp(
        home: PersonaEditPage(
          displayName: '小南',
          standing: standing(),
          refusal: '没能保存：主机没有回答',
          onSave: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('persona-edit-refusal')), findsOneWidget);
    expect(find.text('我原本是这样'), findsOneWidget);
  });

  testWidgets('it does not offer to rename the Eidolon', (tester) async {
    // Who it is and what it is called are two decisions, and renaming lives
    // beside the name. A name box here would make an edit able to change it as
    // a side effect of describing it.
    await tester.pumpWidget(
      MaterialApp(
        home: PersonaEditPage(
          displayName: '小南',
          standing: standing(),
          onSave: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('authoring-name')), findsNothing);
    expect(find.text('小南 是谁'), findsOneWidget);
  });
}
