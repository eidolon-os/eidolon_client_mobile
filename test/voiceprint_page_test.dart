import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voiceprint_page.dart';

void main() {
  testWidgets('one saved voice offers replacement rather than another profile',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: VoiceprintPage(
            personId: 'p',
            personName: '甲',
            call: ({method = 'GET', suffix = '', body}) async => {
                  'profiles': [
                    {
                      'profile_id': 'v',
                      'person_id': 'p',
                      'display_name': '甲',
                      'enrollment_id': 'e',
                      'revision': 1
                    }
                  ]
                })));
    await tester.pumpAndSettle();
    expect(find.text('当前声纹档案'), findsOneWidget);
    expect(find.text('重新录入'), findsOneWidget);
    expect(find.text('录入声纹'), findsNothing);
    expect(find.text('录入新声音'), findsNothing);
  });
  testWidgets('saved policy is not misrepresented as effective admission',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: VoiceprintPage(
      personId: 'person',
      personName: '小铮',
      call: ({method = 'GET', suffix = '', body}) async {
        calls.add('$method $suffix');
        return {
          'person_id': 'person',
          'mode': 'allowlist',
          'revision': 3,
          'profiles': [],
          'allowed_profile_ids': []
        };
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('先录入此用户的声纹，即可测试匹配。'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(calls, ['GET ']);
  });

  testWidgets(
      'unavailable authority is shown with retry instead of an off policy',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: VoiceprintPage(
      personId: 'person',
      personName: '小铮',
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
      personId: 'person',
      personName: '小铮',
      call: ({method = 'GET', suffix = '', body}) async {
        calls.add(suffix);
        if (suffix.endsWith('/recording')) throw Exception('offline');
        return {
          'person_id': 'person',
          'mode': 'off',
          'revision': 1,
          'profiles': [
            {
              'person_id': 'person',
              'profile_id': 'new',
              'display_name': '妈妈',
              'revision': 1,
              'enrollment_id': 'e',
              'recording_available': true
            },
            {
              'person_id': 'person',
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
