import 'package:eidolon_client_mobile/src/features/host_setup/companion_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/home_models.dart';
import 'package:eidolon_client_mobile/src/features/tools/companion_tools_page.dart';
import 'package:eidolon_client_mobile/src/features/tools/companion_tools_tile.dart';
import 'package:eidolon_client_mobile/src/features/tools/tool_policies.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tool_fixtures.dart';

/// 「它能做的事」: one Eidolon's own switches, inside what the Owner allows.

Future<void> _open(WidgetTester tester, FakeToolPolicies tools,
    {List<String> devices = const []}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: CompanionToolsPage(
      companionId: companionA,
      companionName: '小忆',
      tools: tools,
      devices: [
        for (final id in devices) mountedDevice(id),
        // Somebody else's device is not counted as its.
        mountedDevice('elsewhere', companionId: companionB),
      ],
    ),
  ));
  await tester.pumpAndSettle();
}

Switch _switch(WidgetTester tester, String key) =>
    tester.widget<Switch>(find.byKey(Key('companion-tool-switch-$key')));

ManagementContextView _context(Map<String, bool> capabilities,
        [Map<String, String> unavailable = const {}]) =>
    ManagementContextView.fromJson({
      'contract_version': '1',
      'owner': {'owner_id': 'owner-1', 'display_name': 'Manson', 'revision': 1},
      'default_companion_id': companionA,
      'capabilities': capabilities,
      'unavailable': unavailable,
      'limits': {'max_active_companions': null},
    });

void main() {
  testWidgets('a tool the Owner turned off shows its own value, greyed',
      (tester) async {
    final tools =
        FakeToolPolicies(owner: Switches(overrides: {'get_weather': false}));
    await _open(tester, tools);

    final own = _switch(tester, 'get_weather');
    expect(own.value, isTrue, reason: 'its own choice, kept for later');
    expect(own.onChanged, isNull);
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const Key('companion-tool-get_weather')))
            .enabled,
        isFalse);
    expect(find.byKey(const Key('companion-tool-global-off-get_weather')),
        findsOneWidget);
    expect(find.text('已在工具总览中关闭'), findsOneWidget);
    // Everything else is its own to switch.
    expect(_switch(tester, 'get_time').onChanged, isNotNull);

    // And the way to the switch that decides it.
    await tester
        .tap(find.byKey(const Key('companion-tool-open-overview-get_weather')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tools-overview-page')), findsOneWidget);
  });

  testWidgets('a switch is written against the revision shown, then says when',
      (tester) async {
    final tools = FakeToolPolicies(
        companions: {companionA: CompanionSwitches('小忆', revision: 4)});
    await _open(tester, tools);

    await tester.tap(find.byKey(const Key('companion-tool-switch-music.play')));
    await tester.pumpAndSettle();

    final (id, change) = tools.companionChanges.single;
    expect(id, companionA);
    expect(change.expectedRevision, 4);
    expect(change.changes, {'music.play': false});
    expect(change.allowBodyControl, isNull);
    expect(find.text('已关闭，正在进行的对话从下一句起生效'), findsOneWidget);
  });

  testWidgets('a whole group is a change to each tool in it', (tester) async {
    final tools = FakeToolPolicies(
      owner: Switches(overrides: {'get_weather': false}),
      companions: {
        companionA: CompanionSwitches('小忆',
            overrides: {'motion.look': false}, revision: 2),
      },
    );
    await _open(tester, tools);

    // Part of the group is off: the group turns on, and only what is off is
    // sent — a tool already on keeps following its default.
    final motion = find.byKey(const Key('tool-group-toggle-motion'));
    expect(find.descendant(of: motion, matching: find.text('全部开启')),
        findsOneWidget);
    await tester.tap(motion);
    await tester.pumpAndSettle();
    expect(tools.companionChanges.last.$2.changes, {'motion.look': true});
    expect(tools.companionChanges.last.$2.expectedRevision, 2);
    expect(find.text('已开启，下一次对话起生效'), findsOneWidget);

    // All on: the group turns off, every tool in it.
    expect(find.descendant(of: motion, matching: find.text('全部关闭')),
        findsOneWidget);
    await tester.tap(motion);
    await tester.pumpAndSettle();
    expect(tools.companionChanges.last.$2.changes,
        {'motion.look': false, 'motion.nod': false});
    expect(tools.companionChanges.last.$2.expectedRevision, 3);

    // A tool the Owner turned off is not this Eidolon's to switch, so the
    // group leaves it alone.
    await tester.tap(find.byKey(const Key('tool-group-toggle-general')));
    await tester.pumpAndSettle();
    expect(tools.companionChanges.last.$2.changes, {'get_time': false});
  });

  testWidgets('「允许操控身体」 stands above both body groups and greys them',
      (tester) async {
    final tools = FakeToolPolicies(
        companions: {companionA: CompanionSwitches('小忆', revision: 6)});
    await _open(tester, tools);

    final master = find.byKey(const Key('companion-tools-body-control'));
    final top = tester.getTopLeft(master).dy;
    expect(top, lessThan(tester.getTopLeft(find.text('身体动作')).dy));
    expect(top, lessThan(tester.getTopLeft(find.text('设备设置')).dy));
    expect(top, greaterThan(tester.getTopLeft(find.text('视觉')).dy));

    await tester.tap(master);
    await tester.pumpAndSettle();
    final (_, change) = tools.companionChanges.single;
    expect(change.expectedRevision, 6);
    expect(change.allowBodyControl, isFalse);
    expect(change.changes, isNull);
    expect(find.text('已关闭，正在进行的对话从下一句起生效'), findsOneWidget);

    // Every body tool keeps its own value, greyed, and says why.
    for (final key in ['motion.nod', 'motion.look', 'audio.volume.set']) {
      expect(_switch(tester, key).value, isTrue, reason: key);
      expect(_switch(tester, key).onChanged, isNull, reason: key);
      expect(find.byKey(Key('companion-tool-body-off-$key')), findsOneWidget);
    }
    expect(find.byKey(const Key('tool-group-toggle-motion')), findsNothing);
    // Nothing outside the body is touched.
    expect(_switch(tester, 'get_time').onChanged, isNotNull);

    await tester.tap(master);
    await tester.pumpAndSettle();
    expect(tools.companionChanges.last.$2.allowBodyControl, isTrue);
    expect(tools.companionChanges.last.$2.expectedRevision, 7);
    expect(find.text('已开启，下一次对话起生效'), findsOneWidget);
  });

  testWidgets('somebody else changing it first rereads instead of overwriting',
      (tester) async {
    final tools = FakeToolPolicies()..writeFailure = toolPolicyChanged;
    await _open(tester, tools);
    final reads = tools.reads('companion $companionA');

    await tester.tap(find.byKey(const Key('companion-tool-switch-get_time')));
    await tester.pumpAndSettle();

    expect(tools.reads('companion $companionA'), reads + 1);
    expect(find.text('这个伙伴的能力刚被改过，已经重新读取'), findsOneWidget);
    expect(_switch(tester, 'get_time').value, isTrue);
  });

  testWidgets('a reserved tool is locked here too', (tester) async {
    await _open(tester, FakeToolPolicies());
    await tester.tap(find.byKey(const Key('tools-group-system')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion-tool-switch-emit_event')),
        findsNothing);
    expect(find.text('系统保留：语音对话中不开放'), findsNWidgets(2));
  });

  testWidgets('a tool that needs a device counts its devices that can',
      (tester) async {
    final tools = FakeToolPolicies(devices: {
      'device-1': deviceTools('device-1', tools: [
        deviceRow('motion.nod'),
        // Its own switch being off is not about the device.
        deviceRow('music.play', reasons: ['companion_off']),
      ]),
      'device-2': deviceTools('device-2', tools: [
        deviceRow('motion.nod', reasons: ['output_not_allowed:motion']),
        deviceRow('music.play'),
      ]),
    });
    await _open(tester, tools, devices: ['device-1', 'device-2']);

    expect(
        tester
            .widget<Text>(
                find.byKey(const Key('companion-tool-devices-motion.nod')))
            .data,
        '需要设备支持 · 它的设备里有 1 台支持');
    expect(
        tester
            .widget<Text>(
                find.byKey(const Key('companion-tool-devices-music.play')))
            .data,
        '需要设备支持 · 它的设备里有 2 台支持');
    expect(tools.reads('device elsewhere'), 0);
    // A tool that needs no device says nothing about devices.
    expect(
        find.byKey(const Key('companion-tool-devices-get_time')), findsNothing);
  });

  testWidgets('an Eidolon with no device says so under such a tool',
      (tester) async {
    await _open(tester, FakeToolPolicies());
    expect(
        tester
            .widget<Text>(
                find.byKey(const Key('companion-tool-devices-motion.nod')))
            .data,
        '需要设备支持 · 它还没有设备');
  });

  group('the way in', () {
    test('is offered only while the Host offers tool switches', () {
      // Only on the Host's own word: unread cannot tell a Host that has them
      // from one too old to have heard of them.
      expect(hostOffersToolSwitches(null), isFalse);
      expect(hostOffersToolSwitches(_context({'tools.govern': true})), isTrue);
      expect(
          hostOffersToolSwitches(_context({'tools.govern': false},
              {'tools.govern': 'host_not_configured'})),
          isFalse);
      // A Host too old to have heard of them.
      expect(
          hostOffersToolSwitches(_context({'companion.read': true})), isFalse);
    });

    testWidgets('the Eidolon page draws the row only when it is given one',
        (tester) async {
      Future<void> pump(Widget? tools) async {
        await tester.pumpWidget(MaterialApp(
          home: CompanionPage(
            companion: HostCompanion.fromView(CompanionSummaryView.fromJson({
              'companion_id': companionA,
              'display_name': '小忆',
              'kind': 'conversational',
              'lifecycle_state': 'active',
              'revision': 1,
              'created_at': '2026-11-01T00:00:00+00:00',
              'updated_at': '2026-11-01T00:00:00+00:00',
            })),
            devices: null,
            onRename: () {},
            onOpenPersona: () {},
            tools: tools,
          ),
        ));
        await tester.pumpAndSettle();
      }

      await pump(null);
      expect(find.byKey(const Key('companion-tools')), findsNothing);

      final tools =
          FakeToolPolicies(owner: Switches(overrides: {'get_time': false}));
      var opened = 0;
      await pump(CompanionToolsTile(
          companionId: companionA, tools: tools, onOpen: () async => opened++));
      final row = find.byKey(const Key('companion-tools'));
      await tester.ensureVisible(row);
      expect(find.text('它能做的事'), findsOneWidget);
      expect(find.text('能用 7 个，1 个用不了'), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(opened, 1);
      // Read again on the way back, so a change made there shows here.
      expect(tools.reads('companion $companionA'), 2);
    });
  });
}
