import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_voice_access.dart';

void main() {
  testWidgets(
      'extraction readiness never enables admission or revives legacy policy',
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
    expect(writes, isEmpty);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    expect(find.text('识别能力验证中 · 当前对话不受声纹限制'), findsOneWidget);
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
