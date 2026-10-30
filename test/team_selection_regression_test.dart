import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/teams/team_management_page.dart';
import 'package:eidolon_client_mobile/src/features/teams/team_run_page.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_controller.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show device;

const saved = TeamRevision(
    teamId: 'saved',
    revision: 1,
    configuration:
        TeamConfiguration(name: '朋友', inputDeviceId: 'input', members: [
      TeamMember(
          companionId: 'a',
          outputDeviceId: 'output',
          role: SceneRole(name: '向导'))
    ]));

void main() {
  testWidgets(
      'refresh preserves missing member and role until explicit removal',
      (tester) async {
    var present = true;
    var writes = 0;
    await tester.pumpWidget(MaterialApp(
        home: TeamEditorPage(
            initial: saved,
            loadDevices: () async => [
                  device('input', companion: null),
                  if (present) device('output', companion: 'a')
                ],
            openDevices: () async {},
            save: (_, __, config) async {
              writes++;
              expect(config.members.single.role?.name, '向导');
              return TeamRevision(
                  teamId: 'saved', revision: 2, configuration: config);
            })));
    await tester.pumpAndSettle();
    present = false;
    await tester.scrollUntilVisible(find.text('刷新设备'), 200,
        scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(find.text('刷新设备')),
        alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新设备'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存团队'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存团队'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    present = true;
    await tester.scrollUntilVisible(find.text('刷新设备'), -150,
        scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(find.text('刷新设备')),
        alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新设备'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存团队'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存团队'));
    await tester.pumpAndSettle();
    expect(writes, 1);
  });

  testWidgets(
      'leaving runtime does not close and close stays actionable during poll',
      (tester) async {
    Completer<void>? gate;
    final calls = <String>[];
    final controller =
        RoleGroupController(savedCommand: (action, id, team, revision) async {
      calls.add(action);
      if (action == 'status' && gate != null) await gate.future;
      return RoleGroupStatus(
          sessionId: id,
          state: action == 'close' ? 'closed' : 'ready',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await controller.startSaved(saved);
    Widget page() => MaterialApp(
        home: TeamRunPage(
            team: saved,
            controller: controller,
            loadRuns: () async => const TeamStarts(starts: []),
            reloadTeam: () async => saved));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final id = controller.sessionId;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 90));
    expect(controller.sessionId, id);
    expect(calls, isNot(contains('close')));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    gate = Completer<void>();
    final poll = controller.refresh();
    await tester.pump();
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '结束聊天'))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('结束聊天'));
    await tester.pump();
    await tester.tap(find.text('结束聊天'));
    gate.complete();
    await poll;
    await tester.pumpAndSettle();
    expect(calls.where((action) => action == 'close'), hasLength(1));
    expect(controller.sessionId, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
