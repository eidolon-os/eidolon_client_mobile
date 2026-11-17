import 'package:eidolon_client_mobile/src/features/tools/tools_overview_page.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tool_fixtures.dart';

/// The overview shows every tool the Host could hand a conversation, grouped
/// the way a person looks for one, and writes the Owner's switches the way
/// every other revisioned write does.

Future<void> _open(WidgetTester tester, FakeToolPolicies tools,
    {List<String> devices = const []}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ToolsOverviewPage(
        tools: tools, devices: [for (final id in devices) mountedDevice(id)]),
  ));
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

Switch _switch(WidgetTester tester, String key) =>
    tester.widget<Switch>(find.byKey(Key('tool-switch-$key')));

void main() {
  testWidgets('groups in the order a person looks, reserved tools last',
      (tester) async {
    await _open(tester, FakeToolPolicies());

    final order = ['通用', '音乐', '视觉', '身体动作', '设备设置', '其他', '系统'];
    for (var i = 1; i < order.length; i++) {
      expect(_top(tester, order[i - 1]), lessThan(_top(tester, order[i])),
          reason: '${order[i - 1]} before ${order[i]}');
    }
    // A group this build has not heard of is still shown, as 其他.
    expect(find.text('新来的工具'), findsOneWidget);
    // Inside a group, the Host's order.
    expect(_top(tester, '查询时间'), lessThan(_top(tester, '查询天气')));
    // Each row says how many Eidolons use it.
    expect(
        find.descendant(
            of: find.byKey(const Key('tool-get_time')),
            matching: find.textContaining('2/2 个伙伴在用')),
        findsOneWidget);
  });

  testWidgets('reserved tools are folded under 系统 and locked', (tester) async {
    await _open(tester, FakeToolPolicies());

    // Folded: nothing reserved is drawn until 系统 is opened.
    expect(find.byKey(const Key('tool-emit_event')), findsNothing);
    await tester.tap(find.byKey(const Key('tools-group-system')));
    await tester.pumpAndSettle();

    for (final key in ['emit_event', 'delegate_to_coworker']) {
      final row = find.byKey(Key('tool-$key'));
      expect(row, findsOneWidget);
      expect(find.byKey(Key('tool-switch-$key')), findsNothing);
      expect(
          find.descendant(of: row, matching: find.byIcon(Icons.lock_outline)),
          findsOneWidget);
      expect(
          find.descendant(
              of: row, matching: find.textContaining('系统保留：语音对话中不开放')),
          findsOneWidget);
      expect(tester.widget<ListTile>(row).onTap, isNull);
    }
    // 恢复默认 is not offered for what cannot be switched.
    expect(find.byKey(const Key('tool-restore-emit_event')), findsNothing);
  });

  testWidgets('a switch sends only its own change, against the revision shown',
      (tester) async {
    final tools = FakeToolPolicies(owner: Switches(revision: 3));
    await _open(tester, tools);

    await tester.tap(find.byKey(const Key('tool-switch-get_weather')));
    await tester.pumpAndSettle();
    expect(tools.changes.single.expectedRevision, 3);
    expect(tools.changes.single.changes, {'get_weather': false});
    expect(tools.changes.single.allowBodyControl, isNull);
    expect(find.text('已关闭，正在进行的对话从下一句起生效'), findsOneWidget);
    expect(_switch(tester, 'get_weather').value, isFalse);
    // Every Eidolon loses it with the Owner's switch.
    expect(
        find.descendant(
            of: find.byKey(const Key('tool-get_weather')),
            matching: find.textContaining('0/2 个伙伴在用')),
        findsOneWidget);

    // The next change is made against what the Host answered.
    await tester.tap(find.byKey(const Key('tool-switch-get_weather')));
    await tester.pumpAndSettle();
    expect(tools.changes.last.expectedRevision, 4);
    expect(tools.changes.last.changes, {'get_weather': true});
    expect(find.text('已开启，下一次对话起生效'), findsOneWidget);
  });

  testWidgets('恢复默认 removes the override rather than writing a value',
      (tester) async {
    final tools = FakeToolPolicies(
        owner: Switches(overrides: {'music.play': false}, revision: 5));
    await _open(tester, tools);

    // Only the row that differs from its default offers it.
    expect(find.byKey(const Key('tool-restore-get_time')), findsNothing);
    await tester.tap(find.byKey(const Key('tool-restore-music.play')));
    await tester.pumpAndSettle();

    final change = tools.changes.single;
    expect(change.expectedRevision, 5);
    expect(change.changes, {'music.play': null});
    expect(change.changes!.containsKey('music.play'), isTrue);
    expect(find.text('已开启，下一次对话起生效'), findsOneWidget);
    expect(find.byKey(const Key('tool-restore-music.play')), findsNothing);
  });

  testWidgets('somebody else changing it first rereads instead of overwriting',
      (tester) async {
    final tools = FakeToolPolicies()..writeFailure = toolPolicyChanged;
    await _open(tester, tools);
    final reads = tools.reads('overview');

    await tester.tap(find.byKey(const Key('tool-switch-get_time')));
    await tester.pumpAndSettle();

    expect(tools.reads('overview'), reads + 1);
    expect(find.text('工具开关刚被改过，已经重新读取'), findsOneWidget);
    // Not retried: the switch shows what the Host has.
    expect(tools.changes, hasLength(1));
    expect(_switch(tester, 'get_time').value, isTrue);
  });

  testWidgets('a tool the Host no longer has is said, and the list reread',
      (tester) async {
    final tools = FakeToolPolicies()
      ..writeFailure = const ManagementRequestException('更改工具开关被拒绝',
          statusCode: 422,
          refusal: Refusal(kind: 'invalid', code: 'unknown_tool'));
    await _open(tester, tools);
    final reads = tools.reads('overview');

    await tester.tap(find.byKey(const Key('tool-switch-get_time')));
    await tester.pumpAndSettle();

    expect(tools.reads('overview'), reads + 1);
    expect(find.text('主机上已经没有这个工具了'), findsOneWidget);
  });

  group('one tool', () {
    testWidgets('each Eidolon\'s switch is written against its own revision',
        (tester) async {
      final tools = FakeToolPolicies(companions: {
        companionA: CompanionSwitches('小忆', revision: 7),
        companionB: CompanionSwitches('阿福',
            overrides: {'motion.nod': false}, revision: 2),
      });
      await _open(tester, tools);

      await tester.tap(find.text('点头'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tool-detail-page')), findsOneWidget);
      // Everything on it came with the overview row: no Eidolon is read.
      expect(tools.reads('companion $companionA'), 0);
      expect(tools.reads('companion $companionB'), 0);
      expect(
          tester
              .widget<Switch>(
                  find.byKey(const Key('tool-companion-switch-$companionB')))
              .value,
          isFalse);

      await tester
          .tap(find.byKey(const Key('tool-companion-switch-$companionA')));
      await tester.pumpAndSettle();
      final (id, change) = tools.companionChanges.single;
      expect(id, companionA);
      expect(change.expectedRevision, 7);
      expect(change.changes, {'motion.nod': false});
      expect(find.text('已关闭，正在进行的对话从下一句起生效'), findsOneWidget);
      expect(
          tester
              .widget<Switch>(
                  find.byKey(const Key('tool-companion-switch-$companionA')))
              .value,
          isFalse);

      // The next write is made against what the Host answered.
      await tester
          .tap(find.byKey(const Key('tool-companion-switch-$companionA')));
      await tester.pumpAndSettle();
      expect(tools.companionChanges.last.$2.expectedRevision, 8);
      expect(tools.companionChanges.last.$2.changes, {'motion.nod': true});
      // The other Eidolon's revision is its own.
      await tester
          .tap(find.byKey(const Key('tool-companion-switch-$companionB')));
      await tester.pumpAndSettle();
      expect(tools.companionChanges.last.$1, companionB);
      expect(tools.companionChanges.last.$2.expectedRevision, 2);
      expect(tools.reads('companion $companionA'), 0);

      // What it needs, in words.
      expect(find.text('需要设备允许动作'), findsOneWidget);
      expect(find.text('需要设备支持'), findsOneWidget);
    });

    testWidgets('somebody else changing one Eidolon first rereads only it',
        (tester) async {
      final tools = FakeToolPolicies(companions: {
        companionA: CompanionSwitches('小忆', revision: 7),
        companionB: CompanionSwitches('阿福', revision: 2),
      });
      await _open(tester, tools);
      await tester.tap(find.text('点头'));
      await tester.pumpAndSettle();

      // Meanwhile, elsewhere: 小忆's switch for it went off.
      tools.companions[companionA]!
        ..overrides['motion.nod'] = false
        ..revision = 9;
      tools.writeFailure = toolPolicyChanged;
      await tester
          .tap(find.byKey(const Key('tool-companion-switch-$companionA')));
      await tester.pumpAndSettle();

      expect(tools.reads('companion $companionA'), 1);
      expect(tools.reads('companion $companionB'), 0);
      expect(find.text('这个伙伴的能力刚被改过，已经重新读取'), findsOneWidget);
      expect(
          tester
              .widget<Switch>(
                  find.byKey(const Key('tool-companion-switch-$companionA')))
              .value,
          isFalse);

      // And the next write is made against the revision it reread.
      await tester
          .tap(find.byKey(const Key('tool-companion-switch-$companionA')));
      await tester.pumpAndSettle();
      expect(tools.companionChanges.last.$2.expectedRevision, 9);
    });

    testWidgets('an Eidolon not allowed to move its body says so',
        (tester) async {
      final tools = FakeToolPolicies(companions: {
        companionA: CompanionSwitches('小忆', allowBodyControl: false),
        companionB: CompanionSwitches('阿福'),
      });
      await _open(tester, tools);
      await tester.tap(find.text('点头'));
      await tester.pumpAndSettle();

      final held = tester.widget<Switch>(
          find.byKey(const Key('tool-companion-switch-$companionA')));
      expect(held.value, isTrue);
      expect(held.onChanged, isNull);
      expect(
          find.descendant(
              of: find.byKey(const Key('tool-companion-$companionA')),
              matching: find.text('已关闭操控身体')),
          findsOneWidget);
      expect(
          tester
              .widget<Switch>(
                  find.byKey(const Key('tool-companion-switch-$companionB')))
              .onChanged,
          isNotNull);
    });

    testWidgets('a tool the Owner turned off greys every Eidolon\'s switch',
        (tester) async {
      final tools =
          FakeToolPolicies(owner: Switches(overrides: {'motion.nod': false}));
      await _open(tester, tools);
      await tester.tap(find.text('点头'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tool-detail-global-off')), findsOneWidget);
      final own = tester.widget<Switch>(
          find.byKey(const Key('tool-companion-switch-$companionA')));
      expect(own.value, isTrue);
      expect(own.onChanged, isNull);
    });

    testWidgets('which devices can run it, and why not', (tester) async {
      final tools = FakeToolPolicies(devices: {
        'device-1': deviceTools('device-1', tools: [deviceRow('motion.nod')]),
        'device-2': deviceTools('device-2', tools: [
          deviceRow('motion.nod', reasons: ['output_not_allowed:motion'])
        ]),
      });
      await _open(tester, tools, devices: ['device-1', 'device-2']);
      await tester.tap(find.text('点头'));
      await tester.pumpAndSettle();

      expect(
          find.descendant(
              of: find.byKey(const Key('tool-device-device-1')),
              matching: find.text('现在能用')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('tool-device-device-2')),
              matching: find.text('这台设备没允许做动作')),
          findsOneWidget);
    });

    testWidgets('a tool that needs no device lists no devices', (tester) async {
      final tools = FakeToolPolicies();
      await _open(tester, tools, devices: ['device-1']);
      await tester.tap(find.text('查询时间'));
      await tester.pumpAndSettle();

      expect(find.text('哪些设备支持'), findsNothing);
      expect(tools.reads('device device-1'), 0);
    });
  });
}
