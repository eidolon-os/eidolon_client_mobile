import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voiceprint_page.dart';

void main() {
  testWidgets(
      'empty allowlist stays restricted and never switches off implicitly',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: VoiceprintPage(
      companionName: '小铮',
      call: ({method = 'GET', suffix = '', body}) async {
        calls.add('$method $suffix');
        return {
          'companion_id': 'c',
          'mode': 'allowlist',
          'revision': 3,
          'profiles': [],
          'allowed_profile_ids': []
        };
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('暂无允许的声音，当前不会回应语音'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
    expect(calls, ['GET ']);
  });

  testWidgets(
      'unavailable authority is shown with retry instead of an off policy',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: VoiceprintPage(
      companionName: '小铮',
      call: ({method = 'GET', suffix = '', body}) async {
        throw Exception('offline');
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });
  testWidgets(
      'saved recordings are playable while legacy profiles explain re-enrollment',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: VoiceprintPage(
      companionName: '小铮',
      call: ({method = 'GET', suffix = '', body}) async {
        calls.add(suffix);
        if (suffix.endsWith('/recording')) throw Exception('offline');
        return {
          'companion_id': 'c',
          'mode': 'off',
          'revision': 1,
          'profiles': [
            {
              'profile_id': 'new',
              'display_name': '妈妈',
              'revision': 1,
              'enrollment_id': 'e',
              'recording_available': true
            },
            {
              'profile_id': 'old',
              'display_name': '爸爸',
              'revision': 1,
              'enrollment_id': 'old-e'
            },
          ],
          'allowed_profile_ids': ['new', 'old'],
        };
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('回放录入声音'), findsOneWidget);
    expect(find.text('暂无录音，重新录入后可回放'), findsOneWidget);
    await tester.tap(find.text('回放录入声音'));
    await tester.pumpAndSettle();
    expect(calls.last, '/profiles/new/recording');
    expect(find.text('无法读取录音，请检查主机连接后重试'), findsOneWidget);
  });
}
