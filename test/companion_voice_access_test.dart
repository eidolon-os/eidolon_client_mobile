import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_voice_access.dart';

void main() {
  testWidgets('changed voices require explicit confirmation of current policy',
      (tester) async {
    final writes = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CompanionVoiceAccess(
      companionName: '小忆',
      call: ({method = 'GET', suffix = '', body}) async {
        if (body != null) writes.add(body);
        return {
          'companion_id': 'c',
          'mode': 'allowlist',
          'admission_state': writes.isEmpty ? 'unvalidated' : 'ready',
          'readiness': {
            'state': 'ready',
            'validation_state': 'controlled_trial',
            'extraction_ready': true,
            'admission_ready': true,
            'calibration_digest':
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
          },
          'revision': writes.isEmpty ? 7 : 8,
          'profiles': [],
          'allowed_profile_ids': ['p']
        };
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.textContaining('确认前不会接纳语音'), findsOneWidget);
    expect(find.textContaining('受控测试 · 尚未校准'), findsOneWidget);
    await tester.tap(find.text('重新确认允许的声音'));
    await tester.pumpAndSettle();
    expect(writes.single, {'mode': 'allowlist', 'expected_revision': 7});
    expect(find.text('重新确认允许的声音'), findsNothing);
    expect(find.textContaining('通过验证后才打断和回复'), findsOneWidget);
  });

  testWidgets(
      'unavailable admission preserves policy truth and still permits turning off',
      (tester) async {
    final writes = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CompanionVoiceAccess(
      companionName: '小忆',
      call: ({method = 'GET', suffix = '', body}) async {
        if (body != null) writes.add(body);
        return {
          'companion_id': 'c',
          'mode': 'allowlist',
          'readiness': {
            'state': 'ready',
            'extraction_ready': true,
            'admission_ready': false
          },
          'revision': 7,
          'profiles': [],
          'allowed_profile_ids': []
        };
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.text('管理声纹 · 已录入 0 个，允许 0 个'), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion-voiceprint-switch')));
    await tester.pumpAndSettle();
    expect(writes.single['mode'], 'off');
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value,
        isTrue); // fake authority kept allowlist; UI must not invent off
    expect(tile.onChanged, isNotNull);
    expect(find.textContaining('识别服务未就绪'), findsOneWidget);
  });
  testWidgets('failed policy read does not invent an off switch',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CompanionVoiceAccess(
      companionName: '小忆',
      call: ({method = 'GET', suffix = '', body}) async =>
          throw Exception('offline'),
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });
}
