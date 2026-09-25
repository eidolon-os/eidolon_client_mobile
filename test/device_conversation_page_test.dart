import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_conversation_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show scene;

void main() {
  testWidgets('phone controls two endpoints, waits for readiness and closes same session', (tester) async {
    final calls = <(String, String, ConversationStart?)>[];
    await tester.pumpWidget(MaterialApp(home: DeviceConversationPage(load: () async => scene(),
      command: (action, id, selection) async {
        calls.add((action, id, selection));
        return DeviceConversationStatus(sessionId: id,
          state: {'open': 'preparing', 'status': 'ready', 'close': 'closed'}[action]!);
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
    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();
    expect(find.text('正在准备两台设备…'), findsOneWidget);
    expect(calls.single.$3!.inputDeviceId, 'StackChan');
    expect(calls.single.$3!.outputDeviceId, 'BOX-3');
    expect(calls.single.$3!.targetCompanionId, 'mac');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('已准备好。请从输入设备说话，回复由播放设备播出。'), findsOneWidget);
    await tester.tap(find.text('结束对话'));
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'close');
    expect(calls.last.$2, calls.first.$2);
    expect(find.text('对话已结束，可以使用原来的单聊。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
