import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_voice_access.dart';

void main() {
  testWidgets('home owns the switch and uses the latest authority revision',
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
          'mode': method == 'PUT' ? 'allowlist' : 'off',
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
    expect(writes.single, {'mode': 'allowlist', 'expected_revision': 7});
    expect(find.text('暂无允许的声音，当前不会回应语音'), findsOneWidget);
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
