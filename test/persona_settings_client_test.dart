import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/companion_authoring_page.dart';

void main() {
  final base = Uri.parse('https://host.test');
  test('edit carries CAS and receipt identity and preserves omitted fields',
      () async {
    final requests = <Map<String, dynamic>>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      requests.add(jsonDecode(request.body));
      return http.Response(
          jsonEncode({
            'genome_id': 'g2',
            'preference_revision': 3,
            'persona': {'voice_portrait': '短句'},
            'preferences': {'response_length': 'brief'}
          }),
          200, headers: {"content-type": "application/json; charset=utf-8"});
    }));
    const edit = PersonaEditRequest(
        expectedBaseGenomeId: 'g1',
        expectedPreferenceRevision: 2,
        operationId: 'same-request',
        persona: PersonaAuthoring(voicePortrait: '短句'));
    final saved = await client.setPersona(base,
        accessToken: 'token', companionId: 'companion-a', persona: edit);
    await client.setPersona(base,
        accessToken: 'token', companionId: 'companion-a', persona: edit);
    expect(saved.genomeId, 'g2');
    expect(requests[0], requests[1]);
    expect(requests[0]['expected_base_genome_id'], 'g1');
    expect(requests[0]['expected_preference_revision'], 2);
    expect(requests[0]['operation_id'], 'same-request');
    expect(requests[0]['persona'], {'voice_portrait': '短句'});
  });

  test('a conflict remains a conflict rather than a reported save', () async {
    final client = ManagementClient(
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {'code': 'preferences_changed', 'message': 'reload'}
            }),
            409)));
    expect(
        client.setPersona(base,
            accessToken: 'token',
            companionId: 'companion-a',
            persona: const PersonaEditRequest(
                expectedBaseGenomeId: 'g1',
                expectedPreferenceRevision: 1,
                operationId: 'a',
                persona: PersonaAuthoring())),
        throwsA(isA<ManagementRequestException>()));
  });

  testWidgets(
      'a server preset and reply preference reach create without starting a conversation',
      (tester) async {
    PersonaAuthoring? sent;
    ConversationPreferences? prefs;
    var calls = 0;
    final presets = [
      const PersonaPreset(
          presetId: 'gentle',
          title: '温和陪伴',
          persona: PersonaAuthoring(characterPortrait: '温和'),
          examples: ['示例 A']),
      const PersonaPreset(
          presetId: 'direct',
          title: '直接务实',
          persona: PersonaAuthoring(characterPortrait: '直接'),
          examples: ['示例 B']),
    ];
    await tester.pumpWidget(MaterialApp(
        home: CompanionAuthoringPage(
            template: presets[0].persona,
            presets: presets,
            onCreate: (name, persona, preferences) async {
              calls++;
              sent = persona;
              prefs = preferences;
            })));
    await tester.tap(find.text('直接务实'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('authoring-name')), '小南');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-next')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('示例 B'), findsOneWidget);
    await tester.tap(find.text('详细'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authoring-create')));
    expect(calls, 1);
    expect(sent?.characterPortrait, '直接');
    expect(prefs?.responseLength, 'detailed');
  });
}
