import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_session_controls.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show device;

void main() {
  testWidgets(
      'two cycles use independent device endpoint and restore correlation',
      (tester) async {
    final preferences = InMemoryAppPreferences();
    final calls = <(String, String)>[];
    Widget page() => MaterialApp(
        home: Scaffold(
            body: DeviceSessionControls(
                device: device('Reachy'),
                storageKey: 'test-device',
                online: () => true,
                preferences: preferences,
                command: (action, id, deviceId, companionId) async {
                  calls.add((action, id));
                  if (action == 'open') expect(deviceId, 'Reachy');
                  return DeviceConversationStatus(
                      sessionId: id,
                      state: action == 'close' ? 'closed' : 'ready');
                })));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();
    expect(find.text('已进入对话，可以说话'), findsOneWidget);
    final first = calls.first.$2;
    await tester.pumpWidget(const SizedBox());
    expect(calls.where((c) => c.$1 == 'close'), isEmpty);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(calls.last, ('status', first));
    await tester.tap(find.text('结束对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();
    expect(calls.last.$2, isNot(first));
    await tester.tap(find.text('结束对话'));
    await tester.pumpAndSettle();
    expect(find.text('在线待机'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
