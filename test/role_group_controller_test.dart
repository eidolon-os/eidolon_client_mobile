import 'dart:async';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_controller.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';

void main() {
  const savedTeam = TeamRevision(
      teamId: 'saved',
      revision: 1,
      configuration:
          TeamConfiguration(name: '朋友', inputDeviceId: 'input', members: []));
  test('round failure keeps run and clears after a later successful round',
      () async {
    var roundError = 'DECISION_TRANSPORT_ERROR';
    final controller = RoleGroupController(
        savedCommand: (_, id, __, ___) async => RoleGroupStatus(
            sessionId: id,
            state: 'ready',
            scenario: 'ip_role_group',
            completionBasis: 'native_playout',
            roundError: roundError,
            roundEpoch: 1));
    await controller.startSaved(savedTeam);
    final id = controller.sessionId;
    expect(controller.notice, contains('上一轮没能回答'));
    expect(id, isNotNull);
    roundError = '';
    await controller.refresh();
    expect(controller.sessionId, id);
    expect(controller.notice, contains('团队已就绪'));
    controller.dispose();
  });
  for (final existing in [false, true]) {
    test('definite refusal reconciles existing run: $existing', () async {
      final controller = RoleGroupController(
          loadSavedRuns: (_) async => TeamStarts(
              starts: existing
                  ? [
                      const TeamStartRecord(
                          teamId: 'saved',
                          sessionId: 'other-phone',
                          revision: 1,
                          closed: false)
                    ]
                  : []),
          savedCommand: (_, __, ___, ____) async =>
              throw const ManagementRequestException('refused',
                  statusCode: 409));
      await controller.startSaved(savedTeam);
      expect(controller.sessionId, existing ? 'other-phone' : null);
      expect(controller.notice, contains(existing ? '已有聊天' : '未能开始'));
      controller.dispose();
    });
  }
  test('failed refusal reconciliation keeps uncertain session', () async {
    final controller = RoleGroupController(
        loadSavedRuns: (_) async => throw StateError('offline'),
        savedCommand: (_, __, ___, ____) async =>
            throw const ManagementRequestException('refused', statusCode: 409));
    await controller.startSaved(savedTeam);
    expect(controller.sessionId, isNotNull);
    expect(controller.notice, contains('无法确认'));
    controller.dispose();
  });
  test('queued cancellation never closes a different discovered run', () async {
    final gate = Completer<void>();
    final actions = <String>[];
    final controller = RoleGroupController(
        loadSavedRuns: (_) async => const TeamStarts(starts: [
              TeamStartRecord(
                  teamId: 'saved',
                  sessionId: 'other-phone',
                  revision: 1,
                  closed: false)
            ]),
        savedCommand: (action, _, __, ___) async {
          actions.add(action);
          await gate.future;
          throw const ManagementRequestException('refused', statusCode: 409);
        });
    final opening = controller.startSaved(savedTeam);
    final closing = controller.close();
    gate.complete();
    await Future.wait([opening, closing]);
    expect(actions, ['open']);
    expect(controller.sessionId, isNull);
    controller.dispose();
  });

  test(
      'saved team run uses fixed identity through close without free selection',
      () async {
    final calls = <String>[];
    final controller =
        RoleGroupController(savedCommand: (action, id, team, revision) async {
      expect(team, 'saved');
      expect(revision, 4);
      calls.add(action);
      return RoleGroupStatus(
          sessionId: id,
          state: action == 'close' ? 'closed' : 'ready',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.startSaved(const TeamRevision(
        teamId: 'saved',
        revision: 4,
        configuration: TeamConfiguration(
            name: '朋友', inputDeviceId: 'input', members: [])));
    expect(controller.teamId, 'saved');
    await controller.close();
    expect(calls, ['open', 'close']);
    expect(controller.teamId, isNull);
    controller.dispose();
  });

  test('restore queries Host without reopening and retains unknown occupancy',
      () async {
    final calls = <String>[];
    var reachable = false;
    final controller =
        RoleGroupController(savedCommand: (action, id, teamId, revision) async {
      calls.add(action);
      expect(id, 'saved-team');
      if (!reachable) throw StateError('offline');
      return RoleGroupStatus(
          sessionId: id,
          state: 'closed',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.restoreSaved(const TeamStartRecord(
        teamId: 'saved', sessionId: 'saved-team', revision: 1, closed: false));
    expect(controller.sessionId, 'saved-team');
    await controller.startSaved(savedTeam);
    expect(calls, ['status']);
    reachable = true;
    await controller.refresh();
    expect(controller.sessionId, isNull);
    expect(calls, ['status', 'status']);
    controller.dispose();
  });
  for (final delayedAction in ['open', 'status']) {
    test('close is queued after in-flight $delayedAction, never dropped',
        () async {
      final gate = Completer<void>();
      final calls = <String>[];
      final controller = RoleGroupController(
          savedCommand: (action, id, teamId, revision) async {
        calls.add(action);
        if (action == delayedAction) await gate.future;
        return RoleGroupStatus(
            sessionId: id,
            state: action == 'close' ? 'closed' : 'ready',
            scenario: 'ip_role_group',
            completionBasis: 'native_playout');
      });
      final opening = controller.startSaved(savedTeam);
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
    final controller =
        RoleGroupController(savedCommand: (action, id, teamId, revision) async {
      calls.add(action);
      return RoleGroupStatus(
          sessionId: id,
          state: action == 'close' ? 'closed' : 'ready',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.startSaved(savedTeam);
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
    final controller =
        RoleGroupController(savedCommand: (action, id, teamId, revision) async {
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
    await controller.startSaved(savedTeam);
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
    final controller =
        RoleGroupController(savedCommand: (action, id, teamId, revision) async {
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
    await controller.startSaved(savedTeam);
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
    await controller.startSaved(savedTeam);
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
    final controller =
        RoleGroupController(savedCommand: (action, id, teamId, revision) async {
      if (action == 'close') remoteState = 'closing';
      return RoleGroupStatus(
          sessionId: id,
          state: remoteState,
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.startSaved(savedTeam);
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
  test('automatic confirmed closure preserves cause and permits a new team',
      () async {
    var remoteState = 'ready';
    final calls = <String>[];
    final controller =
        RoleGroupController(savedCommand: (action, id, teamId, revision) async {
      calls.add(action);
      return RoleGroupStatus(
          sessionId: id,
          state: remoteState,
          error: remoteState == 'closed' ? 'TEAM_DEVICE_DISCONNECTED' : '',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.startSaved(savedTeam);
    final previous = controller.sessionId;
    remoteState = 'closed';
    await controller.refresh();
    expect(controller.sessionId, isNull);
    expect(controller.notice, contains('设备连接中断'));
    expect(controller.notice, contains('可重新开始'));
    expect(calls, isNot(contains('close')));
    remoteState = 'ready';
    await controller.startSaved(savedTeam);
    expect(controller.sessionId, isNot(previous));
    expect(controller.state, 'ready');
    controller.dispose();
  });
}
