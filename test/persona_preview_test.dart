import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/persona_preview_panel.dart';
import 'package:eidolon_client_mobile/src/management/persona_form.dart';

void main() {
  testWidgets('detailed prose edits invalidate a completed preview',
      (tester) async {
    final form = PersonaForm(const PersonaAuthoring(selfConcept: '原来的我'));
    addTearDown(form.dispose);
    final requests = <PersonaPreviewRequest>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, setState) => SingleChildScrollView(
          child: Column(children: [
        ...form.whoItIs(() => setState(() {})),
        PersonaPreviewPanel(
          draft: PersonaPreviewRequest(
              name: '澄澄', persona: form.authoring, text: ''),
          preview: (draft) async {
            requests.add(draft);
            return const PersonaPreviewResponse(
                draftDigest: 'one', reply: '旧设定的回复', finishReason: 'stop');
          },
        ),
      ])),
    ))));
    await tester.ensureVisible(find.text('试聊'));
    await tester.tap(find.text('试聊'));
    await tester.pumpAndSettle();
    expect(find.text('旧设定的回复'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('authoring-self-concept')));
    await tester.enterText(
        find.byKey(const Key('authoring-self-concept')), '修改后的我');
    await tester.pumpAndSettle();
    expect(find.text('旧设定的回复'), findsNothing);
    await tester.ensureVisible(find.text('试聊'));
    await tester.tap(find.text('试聊'));
    await tester.pumpAndSettle();
    expect(requests.last.persona.selfConcept, '修改后的我');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('preview sends current draft and drops results after edits',
      (tester) async {
    final first = Completer<PersonaPreviewResponse>();
    final second = Completer<PersonaPreviewResponse>();
    final requests = <PersonaPreviewRequest>[];
    Future<PersonaPreviewResponse> preview(PersonaPreviewRequest draft) {
      requests.add(draft);
      return requests.length == 1 ? first.future : second.future;
    }

    Widget page(String portrait) => MaterialApp(
        home: Scaffold(
            body: PersonaPreviewPanel(
                draft: PersonaPreviewRequest(
                    name: '南',
                    persona: PersonaAuthoring(characterPortrait: portrait),
                    preferences:
                        const ConversationPreferences(responseLength: 'brief'),
                    text: ''),
                preview: preview)));
    await tester.pumpWidget(page('original'));
    await tester.tap(find.text('试聊'));
    await tester.pump();
    expect(requests.single.persona.characterPortrait, 'original');
    expect(requests.single.text, '今天有点累。');
    await tester.pumpWidget(page('edited'));
    first.complete(const PersonaPreviewResponse(
        draftDigest: 'old', reply: 'old reply', finishReason: 'stop'));
    await tester.pump();
    expect(find.text('old reply'), findsNothing);
    await tester.tap(find.text('试聊'));
    await tester.pump();
    expect(requests.last.persona.characterPortrait, 'edited');
    second.complete(const PersonaPreviewResponse(
        draftDigest: 'new', reply: 'new reply', finishReason: 'stop'));
    await tester.pump();
    expect(find.text('new reply'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('persona-preview-input')), 'new question');
    await tester.pump();
    expect(find.text('new reply'), findsNothing);
  });

  testWidgets('preview failure permits retry without losing draft',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PersonaPreviewPanel(
                draft: const PersonaPreviewRequest(
                    name: '南', persona: PersonaAuthoring(), text: ''),
                preview: (_) => Future.error(Exception('offline'))))));
    await tester.tap(find.text('试聊'));
    await tester.pumpAndSettle();
    expect(find.text('试聊暂时不可用，可以重试或继续保存设定。'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '试聊'))
            .onPressed,
        isNotNull);
  });
}
