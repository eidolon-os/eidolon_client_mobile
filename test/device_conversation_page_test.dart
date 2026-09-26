import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_conversation_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show scene, device;

void main() {
  testWidgets(
      'inventory refresh discovers devices and shows unavailable reasons',
      (tester) async {
    var refreshed = false;
    await tester.pumpWidget(MaterialApp(
        home: DeviceConversationPage(
      load: () async => scene(
          devices: refreshed
              ? [
                  device('Waveshare 2.06', companion: null),
                  device('New speaker'),
                  device('Revoked', state: 'access_revoked'),
                  device('Mobile')
                ]
              : [device('First speaker')]),
      command: (_, id, __) async =>
          DeviceConversationStatus(sessionId: id, state: 'closed'),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('First speaker').last);
    await tester.pumpAndSettle();
    refreshed = true;
    await tester.tap(find.byKey(const Key('refresh-conversation-devices')));
    await tester.pumpAndSettle();
    final input = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).first);
    expect(input.initialValue, isNull);
    final button = tester.widget<DropdownButton<String>>(find.descendant(
        of: find.byType(DropdownButtonFormField<String>).first,
        matching: find.byType(DropdownButton<String>)));
    expect(button.items!.map((i) => i.value),
        ['Waveshare 2.06', 'New speaker', 'Revoked']);
    expect(button.items!.map((i) => i.enabled), [false, true, false]);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Waveshare 2.06（尚未绑定伙伴）').last, findsOneWidget);
    expect(find.text('Revoked（设备访问已撤销）').last, findsOneWidget);
    expect(find.text('First speaker'), findsNothing);
  });

  testWidgets(
      'failed inventory can retry without leaving and stale choices are disabled',
      (tester) async {
    var fail = false;
    await tester.pumpWidget(MaterialApp(
        home: DeviceConversationPage(
      load: () async {
        if (fail) throw StateError('offline');
        return scene();
      },
      command: (_, id, __) async =>
          DeviceConversationStatus(sessionId: id, state: 'closed'),
    )));
    await tester.pumpAndSettle();
    fail = true;
    await tester.tap(find.byKey(const Key('refresh-conversation-devices')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取设备，请刷新重试。'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>).first)
            .onChanged,
        isNull);
    fail = false;
    await tester.tap(find.byKey(const Key('refresh-conversation-devices')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取设备，请刷新重试。'), findsNothing);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>).first)
            .onChanged,
        isNotNull);
  });

  testWidgets(
      'phone controls two endpoints, waits for readiness and closes same session',
      (tester) async {
    final calls = <(String, String, ConversationStart?)>[];
    await tester.pumpWidget(MaterialApp(
        home: DeviceConversationPage(
            load: () async => scene(),
            command: (action, id, selection) async {
              calls.add((action, id, selection));
              return DeviceConversationStatus(
                  sessionId: id,
                  state: {
                    'open': 'preparing',
                    'status': 'ready',
                    'close': 'closed'
                  }[action]!);
            })));
    await tester.pumpAndSettle();
    final dropdowns = find.byType(DropdownButtonFormField<String>);
    await tester.tap(dropdowns.at(0));
    await tester.pumpAndSettle();
    expect(find.text('Mobile'), findsNothing);
    await tester.tap(find.text('StackChan').last);
    await tester.pumpAndSettle();
    await tester.tap(dropdowns.at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BOX-3').last);
    await tester.pumpAndSettle();
    await tester.tap(dropdowns.at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mac').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('开始对话'));
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();
    expect(find.text('正在准备两台设备…'), findsOneWidget);
    expect(calls.single.$3!.inputDeviceId, 'StackChan');
    expect(calls.single.$3!.outputDeviceId, 'BOX-3');
    expect(calls.single.$3!.targetCompanionId, 'mac');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('已准备好。请从输入设备说话，回复由播放设备播出。'), findsOneWidget);
    await tester.ensureVisible(find.text('结束对话'));
    await tester.tap(find.text('结束对话'));
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'close');
    expect(calls.last.$2, calls.first.$2);
    expect(find.text('对话已结束，可以使用原来的单聊。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
