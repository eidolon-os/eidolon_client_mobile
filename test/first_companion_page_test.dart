import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/first_companion_page.dart';

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

void main() {
  testWidgets(
      'lost initialization response retries the original complete snapshot',
      (tester) async {
    final requests = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: FirstCompanionPage(
      loadTemplate: () async => const PersonaAuthoring(),
      loadPresets: () async => const PersonaPresetCatalog(presets: [preset]),
      initialize: (name, persona, preferences, source) async {
        requests.add({
          'name': name,
          'persona': persona?.toJson(),
          'preferences': preferences?.toJson(),
          'source': source?.presetId
        });
        throw TimeoutException('lost response');
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(find.text('重试创建'), findsOneWidget);
    await tester.tap(find.byKey(const Key('authoring-create')));
    await tester.pumpAndSettle();
    expect(requests.length, 2);
    expect(requests[1], requests[0]);
    expect(requests[0]['source'], 'water');
    expect(requests[0]['preferences'], preset.preferences.toJson());
  });

  testWidgets('template load failure never silently creates the default',
      (tester) async {
    var loaded = false;
    var writes = 0;
    await tester.pumpWidget(MaterialApp(
        home: FirstCompanionPage(
      loadTemplate: () async => const PersonaAuthoring(),
      loadPresets: () async {
        if (!loaded) throw Exception('offline');
        return const PersonaPresetCatalog(presets: [preset]);
      },
      initialize: (_, __, ___, ____) async {
        writes++;
      },
    )));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.byKey(const Key('authoring-create')), findsNothing);
    loaded = true;
    await tester.tap(find.text('重新读取设定'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preset-water')), findsOneWidget);
    expect(writes, 0);
  });
}
