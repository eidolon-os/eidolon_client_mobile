import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/teams/team_run_page.dart';
import 'package:eidolon_client_mobile/src/features/conversation/role_group_controller.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';

const team = TeamRevision(
    teamId: 'saved',
    revision: 2,
    configuration:
        TeamConfiguration(name: '朋友', inputDeviceId: 'input', members: []));

void main() {
  testWidgets('conflict locator opens occupying team without cancelling it',
      (tester) async {
    final opened = <String>[];
    final controller = RoleGroupController(
        savedCommand: (_, __, ___, ____) async =>
            throw StateError('should not start or close'));
    await tester.pumpWidget(MaterialApp(
        home: TeamRunPage(
            team: team,
            controller: controller,
            loadRuns: () async => const TeamStarts(starts: []),
            reloadTeam: () async => team,
            loadConflicts: () async => const TeamConflicts(conflicts: [
                  TeamConflict(
                      teamId: 'other',
                      name: '另一个团队',
                      sessionId: 'running',
                      revision: 3,
                      companionIds: ['a'])
                ]),
            openConflict: (id) async {
              opened.add(id);
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看伙伴与设备占用'));
    await tester.pumpAndSettle();
    expect(find.text('另一个团队'), findsOneWidget);
    await tester.tap(find.text('另一个团队'));
    await tester.pumpAndSettle();
    expect(opened, ['other']);
    expect(controller.sessionId, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'restores active version without opening another run, then closes',
      (tester) async {
    final calls = <String>[];
    final controller =
        RoleGroupController(savedCommand: (action, id, team, revision) async {
      calls.add(action);
      expect(revision, 1);
      return RoleGroupStatus(
          sessionId: id,
          state: action == 'close' ? 'closed' : 'ready',
          scenario: 'ip_role_group',
          completionBasis: 'native_playout');
    });
    await tester.pumpWidget(MaterialApp(
        home: TeamRunPage(
            team: team,
            controller: controller,
            reloadTeam: () async => team,
            loadRuns: () async => const TeamStarts(starts: [
                  TeamStartRecord(
                      teamId: 'saved',
                      sessionId: 'previous',
                      revision: 1,
                      closed: false)
                ]))));
    await tester.pumpAndSettle();
    expect(calls, ['status']);
    expect(find.text('本次使用第 1 版'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始聊天'))
            .onPressed,
        isNull);
    await tester.tap(find.text('结束聊天'));
    await tester.pumpAndSettle();
    expect(calls, ['status', 'close']);
    expect(controller.sessionId, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
