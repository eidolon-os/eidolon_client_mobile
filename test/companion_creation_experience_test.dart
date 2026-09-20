import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/companion_authoring_page.dart';
import 'package:eidolon_client_mobile/src/management/companion_roster_screen.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

const presets = [
  PersonaPreset(
      presetId: 'gentle',
      examples: ['我在听'],
      defaultName: '小禾',
      title: '温柔倾听',
      description: '愿意听你说',
      persona: PersonaAuthoring(characterPortrait: '温和'),
      preferences: ConversationPreferences()),
  PersonaPreset(
      presetId: 'direct',
      examples: ['我们一起理清'],
      defaultName: '知夏',
      title: '直接务实',
      description: '一起理清问题',
      persona: PersonaAuthoring(characterPortrait: '直接'),
      preferences: ConversationPreferences()),
];

void main() {
  testWidgets('creation can continue to devices without a phone conversation',
      (tester) async {
    CreatedCompanion? connecting;
    await tester.pumpWidget(MaterialApp(
        home: CompanionRosterScreen(
      load: ({String? cursor}) async =>
          const CompanionRosterView(companions: []),
      loadContext: () async => ManagementContextView.fromJson({
        'owner': {'owner_id': 'owner', 'display_name': '我', 'revision': 1},
        'capabilities': {'companion.create': true},
        'limits': <String, int?>{}
      }),
      loadPersonaTemplate: () async => const PersonaAuthoring(),
      loadPersonaPresets: () async =>
          const PersonaPresetCatalog(presets: presets),
      createCompanion: (_, name, __, ___, ____) async => CreatedCompanion(
          companionId: 'new-companion',
          displayName: name,
          created: true,
          memoryReady: true),
      connectDevice: (created) async {
        connecting = created;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('created-start-conversation')), findsNothing);
    expect(connecting, isNull);
    await tester.tap(find.byKey(const Key('created-connect-device')));
    await tester.pumpAndSettle();
    expect(connecting?.companionId, 'new-companion');
  });

  testWidgets('each preset and custom retain edits when switching or reopening',
      (tester) async {
    final drafts = CompanionCreationDrafts(const PersonaAuthoring(), presets);
    addTearDown(drafts.dispose);
    Widget page() => MaterialApp(
        home: CompanionAuthoringPage(
            template: const PersonaAuthoring(),
            presets: presets,
            drafts: drafts,
            onCreate: (_, __, ___, ____) async {}));
    await tester.pumpWidget(page());
    await tester.ensureVisible(find.byKey(const Key('authoring-customize')));
    await tester.tap(find.byKey(const Key('authoring-customize')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('authoring-name')), '禾禾');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('preset-direct')));
    await tester.tap(find.byKey(const Key('preset-direct')));
    await tester.pumpAndSettle();
    expect(drafts.selected.name.text, '知夏');
    await tester.ensureVisible(find.byKey(const Key('authoring-custom')));
    await tester.tap(find.byKey(const Key('authoring-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('authoring-name')), '我的伙伴');
    await tester.enterText(
        find.byKey(const Key('authoring-short-description')), '随和一点');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page());
    expect(find.text('我的伙伴'), findsOneWidget);
    expect(find.text('随和一点'), findsOneWidget);
    expect(drafts.presets['gentle']!.name.text, '禾禾');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'uncertain creation freezes edits and retries the same operation and payload',
      (tester) async {
    final submissions = <List<Object?>>[];
    final first = Completer<CreatedCompanion>();
    var ids = 0;
    CreatedCompanion? started;
    await tester.pumpWidget(MaterialApp(
        home: CompanionRosterScreen(
      load: ({String? cursor}) async =>
          const CompanionRosterView(companions: []),
      loadContext: () async => ManagementContextView.fromJson({
        'owner': {'owner_id': 'owner', 'display_name': '我', 'revision': 1},
        'capabilities': {'companion.create': true},
        'limits': <String, int?>{}
      }),
      loadPersonaTemplate: () async => const PersonaAuthoring(),
      loadPersonaPresets: () async =>
          const PersonaPresetCatalog(presets: presets),
      newOperationId: () => 'operation-${++ids}',
      startConversation: (created) async {
        started = created;
      },
      createCompanion: (id, name, persona, preferences, source) async {
        submissions.add([
          id,
          name,
          jsonEncode(persona?.toJson()),
          jsonEncode(preferences?.toJson())
        ]);
        if (submissions.length == 1) return first.future;
        return const CreatedCompanion(
            companionId: 'created',
            displayName: '小禾',
            created: true,
            memoryReady: true);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('authoring-create')))
            .onPressed,
        isNull);
    first.completeError(TimeoutException('lost response'));
    await tester.pumpAndSettle();
    expect(find.text('重试创建'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preset-direct')),
        warnIfMissed: false);
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(submissions.length, 2);
    expect(submissions[0], submissions[1]);
    expect(ids, 1);
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();
    expect(started?.companionId, 'created');
  });

  testWidgets(
      'a refusal the Host explains stays editable and says what it said',
      (tester) async {
    // The other half of the uncertain case: a 4xx is a decision, not a lost
    // answer, so the draft must stay editable and the next press must be a new
    // attempt rather than a replay of the refused one.
    final operations = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: CompanionRosterScreen(
      load: ({String? cursor}) async =>
          const CompanionRosterView(companions: []),
      loadContext: () async => ManagementContextView.fromJson({
        'owner': {'owner_id': 'owner', 'display_name': '我', 'revision': 1},
        'capabilities': {'companion.create': true},
        'limits': <String, int?>{}
      }),
      loadPersonaTemplate: () async => const PersonaAuthoring(),
      loadPersonaPresets: () async =>
          const PersonaPresetCatalog(presets: presets),
      newOperationId: () => 'operation-${operations.length + 1}',
      createCompanion: (id, name, persona, preferences, source) async {
        operations.add(id);
        throw const ManagementRequestException('rejected',
            statusCode: 422,
            refusal: Refusal(kind: 'invalid', reason: '名字里有不能用的字符'));
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();

    expect(find.text('创建未完成：名字里有不能用的字符'), findsOneWidget);
    expect(find.text('重试创建'), findsNothing,
        reason: 'a decision is not an unresolved attempt');
    expect(find.byKey(const Key('preset-direct')), findsOneWidget,
        reason: 'the choice stays editable');

    await tester.tap(find.byKey(const Key('preset-direct')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(operations, ['operation-1', 'operation-2'],
        reason: 'an edited attempt is a new one');
  });

  testWidgets(
      'an untouched preset says where it came from; an edited one does not',
      (tester) async {
    // Provenance has to be earned. Taking a preset and leaving it alone is a
    // fact worth recording; writing over its words makes the Eidolon the
    // person's own, and claiming a preset then would record something untrue.
    // Naming it is not rewriting it, so the name is deliberately not part of
    // the test.
    final claims = <String?>[];
    Widget page(CompanionCreationDrafts drafts) => MaterialApp(
        home: CompanionAuthoringPage(
            template: const PersonaAuthoring(),
            presets: presets,
            drafts: drafts,
            onCreate: (_, __, ___, source) async {
              claims.add(source?.presetId);
            }));

    final untouched =
        CompanionCreationDrafts(const PersonaAuthoring(), presets);
    addTearDown(untouched.dispose);
    await tester.pumpWidget(page(untouched));
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(claims, ['gentle']);

    final edited = CompanionCreationDrafts(const PersonaAuthoring(), presets);
    addTearDown(edited.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page(edited));
    await tester.ensureVisible(find.byKey(const Key('authoring-customize')));
    await tester.tap(find.byKey(const Key('authoring-customize')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('authoring-short-description')), '我自己写的');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(claims, ['gentle', null]);
  });
}
