import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_controller.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';

void main() {
  testWidgets('team survives silence and only explicit close ends it', (tester) async {
    final calls = <String>[];
    final controller = RoleGroupController((action, id, selection) async {
      calls.add(action);
      if (action == 'open') expect(selection!.outputDeviceIds, ['a', 'b']);
      return RoleGroupStatus(sessionId: id, state: action == 'close' ? 'closed' : 'ready',
          scenario: 'ip_role_group', completionBasis: 'native_playout');
    });
    await controller.start('ptt', ['a', 'b'], false);
    final id = controller.sessionId;
    await tester.pump(const Duration(minutes: 61));
    expect(controller.sessionId, id);
    expect(controller.state, 'ready');
    expect(calls.where((v) => v == 'open').length, 1);
    expect(calls, isNot(contains('close')));
    await controller.close();
    expect(controller.sessionId, isNull);
    controller.dispose();
  });
  test('uncertain start retains same session for explicit cleanup', () async {
    String? opened;
    final controller = RoleGroupController((action, id, selection) async {
      if (action == 'open') { opened = id; throw StateError('lost response'); }
      expect(id, opened);
      return RoleGroupStatus(sessionId:id,state:'closed',scenario:'ip_role_group',completionBasis:'native_playout');
    });
    await controller.start('ptt', ['a'], false);
    expect(controller.sessionId, opened);
    await controller.close();
    expect(controller.sessionId, isNull);
    controller.dispose();
  });
}
