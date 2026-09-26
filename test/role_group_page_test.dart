import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_page.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_controller.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show scene, device;

void main() {
  testWidgets('UI starts ordered team and reopens same explicit close control', (tester) async {
    final calls = <(String, String)>[];
    final controller = RoleGroupController((action, id, selection) async {
      calls.add((action,id));
      if(action=='open') {
        expect(selection!.inputDeviceId,'Waveshare');
        expect(selection.outputDeviceIds,['StackChan','BOX-3']);
      }
      return RoleGroupStatus(sessionId:id,state:action=='close'?'closed':'ready',scenario:'ip_role_group',completionBasis:'native_playout');
    });
    Widget page() => MaterialApp(home:RoleGroupPage(controller:controller,load:() async=>scene(devices:[
      device('Mobile'),device('Waveshare',companion:null),device('StackChan',companion:'a'),device('BOX-3',companion:'b')])));
    await tester.pumpWidget(page()); await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>)); await tester.pumpAndSettle();
    await tester.tap(find.text('Waveshare').last); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('team-output-StackChan')));
    await tester.tap(find.byKey(const ValueKey('team-output-BOX-3')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('start-role-group')));
    await tester.tap(find.byKey(const Key('start-role-group'))); await tester.pumpAndSettle();
    final id=controller.sessionId;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds:90));
    expect(controller.sessionId,id);
    expect(calls.any((c)=>c.$1=='close'),false);
    await tester.pumpWidget(page()); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('close-role-group')));
    await tester.tap(find.byKey(const Key('close-role-group'))); await tester.pumpAndSettle();
    expect(calls.last,('close',id!));
    expect(controller.sessionId,isNull);
    await tester.pumpWidget(const SizedBox()); controller.dispose();
  });
}
