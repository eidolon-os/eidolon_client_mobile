import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_session_controls.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show device;

void main() {
  testWidgets('mirrors the conversation the device holds and ends that one',
      (tester) async {
    // What the Host says the device is doing; the page keeps none of it.
    var state = 'in_conversation';
    String? conversation = 'lifted';
    final calls = <(String, String?)>[];
    Widget page() => MaterialApp(
        home: Scaffold(
            body: DeviceSessionControls(
                device: device('Reachy'),
                online: () => true,
                command: (action, deviceId, conversationId) async {
                  expect(deviceId, 'Reachy');
                  calls.add((action, conversationId));
                  if (action == 'close') {
                    state = 'standby';
                    conversation = null;
                  }
                  if (action == 'open') {
                    return const DeviceSessionStatus(
                        deviceId: 'Reachy', state: 'starting');
                  }
                  return DeviceSessionStatus(
                      deviceId: deviceId,
                      state: state,
                      conversationId: conversation);
                })));
    // A conversation started at the device is shown without having been asked for here.
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('对话进行中'), findsOneWidget);
    expect(find.text('开始对话'), findsNothing);
    await tester.tap(find.text('结束对话'));
    await tester.pumpAndSettle();
    expect(calls.last, ('close', 'lifted'));
    expect(find.text('在线待机'), findsOneWidget);

    await tester.tap(find.text('开始对话'));
    await tester.pump();
    expect(find.text('正在进入对话，请稍候…'), findsOneWidget);
    // The device asks for its conversation; the next read shows it.
    state = 'in_conversation';
    conversation = 'asked';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('对话进行中'), findsOneWidget);

    // Another terminal ended it; the periodic read follows.
    state = 'occupied';
    conversation = null;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('设备正被跨设备对话或团队对话占用'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
