import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/teams/team_management_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'shared_conversation_preparation_test.dart' show device;

void main() {
  testWidgets('editing saved team preserves identity and saves next version',
      (tester) async {
    final original = TeamRevision(
        teamId: 'saved',
        revision: 3,
        configuration: const TeamConfiguration(
            name: '朋友',
            inputDeviceId: 'input',
            members: [TeamMember(companionId: 'a', outputDeviceId: 'output')]));
    TeamConfiguration? written;
    await tester.pumpWidget(MaterialApp(
        home: TeamEditorPage(
            initial: original,
            loadDevices: () async => [
                  device('input', companion: null),
                  device('output', companion: 'a')
                ],
            openDevices: () async {},
            save: (id, revision, configuration) async {
              expect(id, 'saved');
              expect(revision, 3);
              written = configuration;
              return TeamRevision(
                  teamId: id, revision: 4, configuration: configuration);
            })));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '新名字');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存团队'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存团队'));
    await tester.pumpAndSettle();
    expect(written?.name, '新名字');
    expect(written?.members.single.companionId, 'a');
  });

  testWidgets(
      'copy creates a new asset and unknown save retries the same identity',
      (tester) async {
    const config =
        TeamConfiguration(name: '朋友', inputDeviceId: 'input', members: [
      TeamMember(
          companionId: 'a',
          outputDeviceId: 'output',
          role: SceneRole(name: '向导', description: '介绍路线'))
    ]);
    final ids = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: TeamEditorPage(
            copyFrom: config,
            loadDevices: () async => [
                  device('input', companion: null),
                  device('output', companion: 'a')
                ],
            openDevices: () async {},
            save: (id, revision, configuration) async {
              ids.add(id);
              expect(revision, 0);
              expect(configuration.name, '朋友 副本');
              expect(configuration.members.single.role?.name, '向导');
              if (ids.length == 1) throw StateError('response lost');
              return TeamRevision(
                  teamId: id, revision: 1, configuration: configuration);
            })));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存团队'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存团队'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存团队'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存团队'));
    await tester.pumpAndSettle();
    expect(ids.length, 2);
    expect(ids.first, ids.last);
  });

  testWidgets('load failure is not displayed as an empty team list',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: TeamManagementPage(
            load: (_) async => throw StateError('offline'),
            save: (_, __, ___) async => throw StateError('unexpected'),
            remove: (_, __) async {},
            loadDevices: () async => [],
            openDevices: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('还没有团队'), findsNothing);
  });
}
