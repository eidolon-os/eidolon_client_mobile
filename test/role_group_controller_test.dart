import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_controller.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';

void main() {
  for (final delayedAction in ['open', 'status']) {
    test('close is queued after in-flight $delayedAction, never dropped',
        () async {
      final gate = Completer<void>();
      final calls = <String>[];
      final controller = RoleGroupController((action, id, selection) async {
        calls.add(action);
        if (action == delayedAction) await gate.future;
        return RoleGroupStatus(
            sessionId: id,
            state: action == 'close' ? 'closed' : 'ready',
            scenario: 'ip_role_group',
            completionBasis: 'native_playout');
      });
      final opening = controller.start('ptt', ['a']);
      if (delayedAction == 'status') await opening;
      final querying =
          delayedAction == 'status' ? controller.refresh() : opening;
      final closing = controller.close();
      final repeatedClose = controller.close();
      expect(calls, isNot(contains('close')));
      expect(controller.notice, contains('正在停止'));
      gate.complete();
      await Future.wait([querying, closing, repeatedClose]);
      expect(calls.where((action) => action == 'close'), hasLength(1));
      expect(controller.state, 'closed');
      expect(controller.sessionId, isNull);
      controller.dispose();
    });
  }
  testWidgets('team survives silence and only explicit close ends it',
      (tester) async {
    final calls = <String>[];
    final controller = RoleGroupController((action, id, selection) async {
      calls.add(action);
      if (action == 'open') expect(selection!.outputDeviceIds, ['a', 'b']);
      return RoleGroupStatus(
          sessionId: id,
          state: action == 'close' ? 'closed' : 'ready',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.start('ptt', ['a', 'b']);
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
      if (action == 'open') {
        opened = id;
        throw StateError('lost response');
      }
      expect(id, opened);
      return RoleGroupStatus(
          sessionId: id,
          state: 'closed',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.start('ptt', ['a']);
    expect(controller.sessionId, opened);
    await controller.close();
    expect(controller.sessionId, isNull);
    controller.dispose();
  });
  testWidgets(
      'failed close stays retryable through polls and clears only on confirmation',
      (tester) async {
    var closes = 0;
    var remoteState = 'ready';
    final controller = RoleGroupController((action, id, selection) async {
      if (action == 'close') {
        closes++;
        if (closes == 1) {
          remoteState = 'failed';
          throw StateError('503 endpoint cleanup unconfirmed');
        }
        remoteState = 'closed';
      }
      return RoleGroupStatus(
          sessionId: id,
          state: remoteState,
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.start('ptt', ['a', 'b']);
    final id = controller.sessionId;
    await controller.close();
    expect(controller.closeUnconfirmed, isTrue);
    expect(controller.sessionId, id);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.state, 'failed');
    expect(controller.notice, contains('重试结束'));
    // A stale closing snapshot must not erase a known failed close.
    remoteState = 'closing';
    await controller.refresh();
    expect(controller.notice, contains('重试结束'));
    await controller.start('other', ['b']);
    expect(controller.sessionId, id);
    await controller.close();
    expect(controller.sessionId, isNull);
    expect(controller.closeRequested, isFalse);
    expect(controller.closeUnconfirmed, isFalse);
    expect(controller.state, 'closed');
    controller.dispose();
  });
  testWidgets('accepted close waits for host completion without losing scene',
      (tester) async {
    var remoteState = 'ready';
    final controller = RoleGroupController((action, id, selection) async {
      if (action == 'close') remoteState = 'closing';
      return RoleGroupStatus(
          sessionId: id,
          state: remoteState,
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.start('ptt', ['a', 'b']);
    final id = controller.sessionId;
    await controller.close();
    expect(controller.sessionId, id);
    expect(controller.notice, contains('正在停止'));
    expect(controller.closeUnconfirmed, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.sessionId, id);
    remoteState = 'closed';
    await tester.pump(const Duration(seconds: 2));
    expect(controller.sessionId, isNull);
    controller.dispose();
  });
}
