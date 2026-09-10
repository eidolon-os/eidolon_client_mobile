// Real HTTP integration; invoked by Agent's isolated network journey suite.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/management/companion_authoring_page.dart';
import 'package:eidolon_client_mobile/src/management/persona_edit_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

void main() {
  const origin = String.fromEnvironment('PERSONA_E2E_URL');
  const token = String.fromEnvironment('PERSONA_E2E_TOKEN');
  if (origin.isNotEmpty) LiveTestWidgetsFlutterBinding.ensureInitialized();
  test('real Flutter client creates, previews, edits, renames and restores',
      () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final base = Uri.parse(origin);
    final client = ManagementClient();
    addTearDown(client.close);
    final presets = await client.personaPresets(base, accessToken: token);
    final draft = presets.presets.first.persona;
    final preview = await client.previewPersona(base,
        accessToken: token,
        draft: PersonaPreviewRequest(name: '小南', persona: draft, text: '你好'));
    expect(preview.reply, isNotEmpty);
    final created = await client.createCompanion(base,
        accessToken: token,
        operationId: '90b4a07c-9fbe-40cb-b71f-fd88989fabce',
        displayName: '小南',
        persona: draft,
        preferences: const ConversationPreferences(responseLength: 'brief'));
    final id = created.companionId;
    final before =
        await client.fetchPersona(base, accessToken: token, companionId: id);
    final edit = PersonaEditRequest(
        expectedBaseGenomeId: before.genomeId,
        expectedPreferenceRevision: before.preferenceRevision!,
        operationId: 'flutter-edit',
        persona: const PersonaAuthoring(voicePortrait: '简短直接'),
        preferences: const ConversationPreferences(responseLength: 'balanced'));
    final edited = await client.setPersona(base,
        accessToken: token, companionId: id, persona: edit);
    expect(edited.persona.voicePortrait, '简短直接');
    expect(edited.preferences!.responseLength, 'balanced');
    final named = await client.setPersona(base,
        accessToken: token,
        companionId: id,
        persona: PersonaEditRequest(
            expectedBaseGenomeId: edited.genomeId,
            expectedPreferenceRevision: edited.preferenceRevision!,
            operationId: 'flutter-rename',
            persona: const PersonaAuthoring(),
            action: 'rename',
            displayName: '小北'));
    expect(named.displayName, '小北');
    await expectLater(
        client.setPersona(base,
            accessToken: token,
            companionId: id,
            persona: PersonaEditRequest(
                expectedBaseGenomeId: before.genomeId,
                expectedPreferenceRevision: before.preferenceRevision!,
                operationId: 'flutter-stale',
                persona: const PersonaAuthoring(voicePortrait: '陈旧草稿'))),
        throwsA(isA<ManagementRequestException>()
            .having((e) => e.statusCode, 'status', 409)));
    final restored = await client.setPersona(base,
        accessToken: token,
        companionId: id,
        persona: PersonaEditRequest(
            expectedBaseGenomeId: named.genomeId,
            expectedPreferenceRevision: named.preferenceRevision!,
            operationId: 'flutter-restore',
            persona: const PersonaAuthoring(),
            action: 'restore',
            restoreGenomeId: before.genomeId));
    expect(restored.displayName, '小北');
    expect(restored.persona.voicePortrait, before.persona.voicePortrait);
    expect(restored.preferences!.responseLength, 'balanced');
    final replay = await client.setPersona(base,
        accessToken: token, companionId: id, persona: edit);
    expect(replay.genomeId, edited.genomeId);
    expect(
        (await client.fetchPersona(base, accessToken: token, companionId: id))
            .genomeId,
        restored.genomeId);
    expect(
        (await client.personaHistory(base, accessToken: token, companionId: id))
            .chapters
            .length,
        4);
  }, skip: origin.isEmpty ? 'Requires isolated Persona network stack' : false);

  testWidgets('real forms preview, create, edit and persist through HTTP',
      (tester) async {
    // Opt-in real-network widget test: disable Flutter's default HTTP 400 stub.
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = ManagementClient();
    addTearDown(client.close);
    final base = Uri.parse(origin);
    final catalog = (await tester
        .runAsync(() => client.personaPresets(base, accessToken: token)))!;
    final previewed = Completer<PersonaPreviewResponse>();
    final created = Completer<CreatedCompanion>();
    await tester.pumpWidget(MaterialApp(
        home: CompanionAuthoringPage(
      template: catalog.presets.first.persona,
      presets: catalog.presets,
      preview: (draft) async {
        final reply =
            await client.previewPersona(base, accessToken: token, draft: draft);
        previewed.complete(reply);
        return reply;
      },
      onCreate: (name, persona, preferences) async {
        created.complete(await client.createCompanion(base,
            accessToken: token,
            operationId: '90b4a07c-9fbe-40cb-b71f-fd88989fabcf',
            displayName: name,
            persona: persona,
            preferences: preferences));
      },
    )));
    await tester.enterText(find.byKey(const Key('authoring-name')), '表单伙伴');
    await tester.enterText(
        find.byKey(const Key('authoring-short-description')), '安静但有主见');
    await tester.tap(find.byKey(const Key('authoring-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('适中'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('试聊'));
    await tester.runAsync(() async {
      await tester.tap(find.text('试聊'));
      await previewed.future.timeout(const Duration(seconds: 15));
    });
    await tester.pumpAndSettle();
    expect(find.text((await previewed.future).reply), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('authoring-create')));
      await created.future.timeout(const Duration(seconds: 15));
    });
    final id = (await created.future).companionId;
    final before = (await tester.runAsync(
        () => client.fetchPersona(base, accessToken: token, companionId: id)))!;
    expect(before.persona.characterPortrait, '安静但有主见');
    expect(before.preferences!.responseLength, 'balanced');
    final saved = Completer<PersonaEditSnapshot>();
    await tester.pumpWidget(MaterialApp(
        home: PersonaEditPage(
      displayName: '表单伙伴',
      standing: before.persona,
      onSave: (authored) async {
        saved.complete(await client.setPersona(base,
            accessToken: token,
            companionId: id,
            persona: PersonaEditRequest(
                expectedBaseGenomeId: before.genomeId,
                expectedPreferenceRevision: before.preferenceRevision!,
                operationId: 'flutter-widget-edit',
                persona: authored)));
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('persona-details')));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('authoring-voice-portrait')));
    await tester.enterText(
        find.byKey(const Key('authoring-voice-portrait')), '先回应要点');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('persona-edit-save')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('persona-edit-save')));
      await saved.future.timeout(const Duration(seconds: 15));
    });
    final persisted = (await tester.runAsync(
        () => client.fetchPersona(base, accessToken: token, companionId: id)))!;
    expect(persisted.persona.voicePortrait, '先回应要点');
    expect(persisted.persona.characterPortrait, '安静但有主见');
    expect(persisted.preferences!.responseLength, 'balanced');
  }, skip: origin.isEmpty);
}
