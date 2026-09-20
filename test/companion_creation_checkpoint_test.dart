import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/companion_creation_checkpoint.dart';
import 'package:eidolon_client_mobile/src/management/companion_roster_screen.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';

const preset = PersonaPreset(
  presetId: 'water',
  revision: '1',
  defaultName: '澄澄',
  title: '水 · 温柔倾听',
  description: '愿意听你说完',
  examples: ['我在听'],
  persona: PersonaAuthoring(characterPortrait: '温柔倾听'),
  preferences: ConversationPreferences(responseLength: 'brief'),
);

CompanionCreationCheckpointStore store(AppPreferences preferences,
        {String owner = 'owner'}) =>
    CompanionCreationCheckpointStore(
        hostId: 'host',
        controllerId: 'controller',
        ownerId: owner,
        preferences: preferences);

class FailingWrites extends InMemoryAppPreferences {
  @override
  Future<void> writeString(String key, String value) async =>
      throw StateError('disk unavailable');
}

void main() {
  test(
      'checkpoint survives store recreation, isolates Owners and prevents overwrites',
      () async {
    final preferences = InMemoryAppPreferences();
    final pending = CompanionCreationSubmission(
        'op-1', '澄澄', preset.persona, preset.preferences, preset);
    await store(preferences).save(pending);
    final recovered = await store(preferences).load();
    expect(recovered!.encode(), pending.encode());
    expect(recovered.uncertain, isTrue);
    expect(await store(preferences, owner: 'other').load(), isNull);
    final other = CompanionCreationSubmission('op-2', '另一个', null, null, null);
    await expectLater(store(preferences).save(other), throwsStateError);
    await expectLater(store(preferences).clear('op-2'), throwsStateError);
    expect((await store(preferences).load())!.operationId, 'op-1');
    await store(preferences).clear('op-1');
    expect(await store(preferences).load(), isNull);
  });

  test('unsupported checkpoint cannot be silently defaulted', () {
    expect(() => CompanionCreationSubmission.decode('{"version":2}'),
        throwsFormatException);
    final pending = CompanionCreationSubmission(
        'op-1', '澄澄', preset.persona, preset.preferences, preset);
    final value = jsonDecode(pending.encode()) as Map<String, dynamic>;
    value['persona']['future_persona_field'] = 'must not vanish';
    expect(() => CompanionCreationSubmission.decode(jsonEncode(value)),
        throwsFormatException);
  });

  testWidgets(
      'a restarted roster retries its saved request without loading new templates',
      (tester) async {
    final preferences = InMemoryAppPreferences();
    final requests = <List<Object?>>[];
    var restarted = false;
    Widget page() => MaterialApp(
            home: CompanionRosterScreen(
          creationCheckpoints: store(preferences),
          load: ({String? cursor}) async =>
              const CompanionRosterView(companions: []),
          loadContext: () async => ManagementContextView.fromJson({
            'owner': {'owner_id': 'owner', 'display_name': '我', 'revision': 1},
            'capabilities': {'companion.create': true},
            'limits': <String, int?>{},
          }),
          loadPersonaTemplate: () async {
            if (restarted) throw StateError('catalogue unavailable');
            return const PersonaAuthoring();
          },
          loadPersonaPresets: () async {
            if (restarted) throw StateError('catalogue retired');
            return const PersonaPresetCatalog(presets: [preset]);
          },
          createCompanion: (id, name, persona, prefs, source) async {
            expect((await store(preferences).load())?.operationId, id);
            requests.add([
              id,
              name,
              persona?.toJson(),
              prefs?.toJson(),
              source?.toJson()
            ]);
            if (!restarted) {
              throw TimeoutException('server committed, reply lost');
            }
            if (requests.length == 2) {
              throw const ManagementRequestException(
                  'grant temporarily refused',
                  statusCode: 403);
            }
            return CreatedCompanion(
                companionId: 'same-companion',
                displayName: name,
                created: false,
                memoryReady: true);
          },
        ));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    restarted = true;
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('继续确认创建'), findsOneWidget);
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    expect(find.text('重试创建'), findsOneWidget);
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(requests.length, 2);
    expect(requests.last, requests.first);
    expect((await store(preferences).load())?.operationId, requests.first[0]);
    expect(find.text('重试创建'), findsOneWidget);
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(requests.length, 3);
    expect(requests.last, requests.first);
    expect(await store(preferences).load(), isNull);
  });

  testWidgets('a failed checkpoint write prevents the network mutation',
      (tester) async {
    var writes = 0;
    await tester.pumpWidget(MaterialApp(
        home: CompanionRosterScreen(
      creationCheckpoints: store(FailingWrites()),
      load: ({String? cursor}) async =>
          const CompanionRosterView(companions: []),
      loadContext: () async => ManagementContextView.fromJson({
        'owner': {'owner_id': 'owner', 'display_name': '我', 'revision': 1},
        'capabilities': {'companion.create': true},
        'limits': <String, int?>{},
      }),
      loadPersonaTemplate: () async => const PersonaAuthoring(),
      loadPersonaPresets: () async =>
          const PersonaPresetCatalog(presets: [preset]),
      createCompanion: (_, __, ___, ____, _____) async {
        writes++;
        throw StateError('must not dispatch');
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(writes, 0);
  });
}
