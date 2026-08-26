import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_page.dart';
import 'package:flutter/material.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/home_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _companionId = 'c_683f963f54885e86892416894c9d92d1';


MountedDeviceInventory _devices(List<String?> attachedTo) =>
    MountedDeviceInventory.fromView(
      DevicesView.fromJson({
        'contract_version': '1',
        'coverage': '只包含已经属于你的设备。',
        'devices': [
          for (final (index, companion) in attachedTo.indexed)
            {
              'device_id': 'device-$index',
              'label': 'box3-device-manifest',
              'kind': 'box3-device-manifest',
              'state': companion == null ? 'awaiting_companion' : 'ready',
              'answers_as_companion_id': companion,
              'answers_as_companion_name': companion == null ? '' : '小忆',
              'revision': 1,
              'mount_revision': 2,
              'updated_at': '2026-08-25T08:10:00Z',
              'online': 'unknown',
              'online_reason': '这台主机没有任何东西在观测设备是否开着',
              'claim_state': 'active',
              'claim_generation': 1,
              'trust_epoch': 1,
              'owner_domain_generation': 3,
              'manifest_id': 'box3-device-manifest',
              'manifest_revision': 1,
            },
        ],
      }),
    );


Future<void> _open(
  WidgetTester tester, {
  MountedDeviceInventory? devices,
  HostCompanion? companion,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CompanionPage(
        companion: companion ?? _companion(),
        devices: devices,
        onRename: () {},
        onOpenPersona: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The Eidolon this page is about.
///
/// A Companion, not a home read. This page used to take the whole home answer
/// and pull ``answering`` out of it, which meant it could only ever be the
/// Eidolon that replies when nobody was named — so an Owner with three of them
/// could open one.
HostCompanion _companion({
  String name = '小忆',
  String id = _companionId,
  bool? running = true,
  String lifecycleState = 'active',
}) =>
    HostCompanion.fromView(
      CompanionSummaryView.fromJson({
        'companion_id': id,
        'display_name': name,
        'kind': 'conversational',
        'lifecycle_state': lifecycleState,
        'revision': 4,
        'created_at': '2026-08-01T00:00:00+00:00',
        'updated_at': '2026-08-01T00:00:00+00:00',
        'running': running,
        'last_active_at': running == true ? '2026-08-26T09:30:00+00:00' : '',
      }),
    );

void main() {
  _withheldRowTests();
  testWidgets('the page is the Eidolon, not the machine it runs on',
      (tester) async {
    await _open(tester);

    expect(find.text('小忆'), findsWidgets);
    // What state *this Eidolon* is in, where it used to greet the Owner —
    // 「你好，Manson」 under the Eidolon's name, beside a pencil, made the card
    // read as the person's own profile.
    expect(find.text('这台主机正在运行它'), findsOneWidget);
    expect(find.textContaining('你好'), findsNothing);
    // Nothing about the Host, the session or the parts it is built from.
    expect(find.textContaining('Host IP'), findsNothing);
    expect(find.textContaining('genome'), findsNothing);
    expect(find.textContaining('realm'), findsNothing);
  });

  testWidgets('shows only the devices attached to this Eidolon',
      (tester) async {
    // The Host answers with everything it has mounted. Which of them belong to
    // this Eidolon is decided here rather than asked for again.
    await _open(
      tester,
      devices: _devices([_companionId, 'c_somebody_else', null]),
    );

    expect(find.byKey(const Key('companion-device-device-0')), findsOneWidget);
    expect(find.byKey(const Key('companion-device-device-1')), findsNothing);
    expect(find.byKey(const Key('companion-device-device-2')), findsNothing);
  });

  testWidgets('says what a device is to it, not what state a mount is in',
      (tester) async {
    await _open(tester, devices: _devices([_companionId]));

    expect(find.text('可以通过它和你说话'), findsOneWidget);
    expect(find.textContaining('revision'), findsNothing);
  });

  testWidgets('an Eidolon nothing is connected to says so plainly',
      (tester) async {
    await _open(tester, devices: _devices([null]));

    expect(find.byKey(const Key('companion-devices-empty')), findsOneWidget);
  });

  testWidgets('a Host that cannot say what is connected does not claim none',
      (tester) async {
    // devices is null when the inventory has not been read, which is not the
    // same as an Eidolon with nothing attached — but the honest fallback here
    // is the empty state, and it says "not yet" rather than "never".
    await _open(tester);

    expect(find.byKey(const Key('companion-devices-empty')), findsOneWidget);
    expect(find.textContaining('还没有设备连到它'), findsOneWidget);
  });

  testWidgets('an unnamed Eidolon is not called by its identifier',
      (tester) async {
    await _open(tester, companion: _companion(name: ''));

    expect(find.textContaining(_companionId), findsNothing);
    expect(find.text('这个 Eidolon'), findsWidgets);
  });
}

/// A Host with a stated opinion about what it can do.
ManagementContextView _context({
  required Map<String, bool> capabilities,
  Map<String, String> unavailable = const {},
}) =>
    ManagementContextView(
      owner: const OwnerContextView(
        ownerId: 'owner-1',
        displayName: 'Manson',
        revision: 4,
      ),
      capabilities: capabilities,
      unavailable: unavailable,
      limits: const {'max_active_companions': null},
    );

Future<void> _pumpWithContext(
  WidgetTester tester,
  ManagementContextView? context,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CompanionPage(
        companion: _companion(),
        devices: null,
        onRename: () {},
        onOpenPersona: () {},
        onOpenRecollections: () {},
        onOpenTasks: () {},
        onOpenConversations: () {},
        hostContext: context,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _withheldRowTests() {
  group('a row this Host cannot serve', () {
    testWidgets('stays, and says which kind of cannot', (tester) async {
      // The state this page could not express. A Host missing its memory
      // credential used to answer memory.read: true, so the row opened onto a
      // page that always failed; hiding the row instead taught people the
      // feature was gone. Neither is the truth, and the truth is short.
      await _pumpWithContext(
        tester,
        _context(
          capabilities: {
            'memory.read': false,
            'task.read': false,
            'conversation.read': true,
            'persona.author': true,
          },
          unavailable: {
            'memory.read': 'host_not_configured',
            'task.read': 'not_built',
          },
        ),
      );

      expect(find.text('它记得什么'), findsOneWidget);
      expect(find.text('主机未配置'), findsOneWidget);
      expect(find.text('尚未开放'), findsOneWidget);

      // Held back means not openable: tapping must do nothing rather than
      // navigate to a page that cannot load.
      final row = tester.widget<ListTile>(
        find.byKey(const Key('companion-open-recollections')),
      );
      expect(row.enabled, isFalse);
      expect(row.onTap, isNull);
    });

    testWidgets('an available row is openable and unlabelled', (tester) async {
      await _pumpWithContext(
        tester,
        _context(
          capabilities: {
            'memory.read': true,
            'task.read': true,
            'conversation.read': true,
            'persona.author': true,
          },
        ),
      );

      final row = tester.widget<ListTile>(
        find.byKey(const Key('companion-open-recollections')),
      );
      expect(row.enabled, isTrue);
      expect(row.onTap, isNotNull);
      expect(find.text('主机未配置'), findsNothing);
      expect(find.text('尚未开放'), findsNothing);
    });

    testWidgets('a Host that has not answered yet withdraws nothing',
        (tester) async {
      // Null is "not read", not "refused". A page that treated silence as a no
      // would show every feature withdrawn for the moment after connecting.
      await _pumpWithContext(tester, null);

      for (final key in const [
        'companion-open-recollections',
        'companion-open-tasks',
        'companion-open-conversations',
        'companion-open-persona',
      ]) {
        final row = tester.widget<ListTile>(find.byKey(Key(key)));
        expect(row.enabled, isTrue, reason: key);
      }
    });

    testWidgets('a reason this build has not heard of still reads',
        (tester) async {
      // The Host may be newer than the phone. An unknown reason degrades to a
      // neutral label rather than being dropped, which would silently restore
      // the "row opens onto a failing page" behaviour.
      await _pumpWithContext(
        tester,
        _context(
          capabilities: {
            'memory.read': false,
            'task.read': true,
            'conversation.read': true,
            'persona.author': true,
          },
          unavailable: {'memory.read': 'something_new'},
        ),
      );

      expect(find.text('暂不可用'), findsOneWidget);
    });

    testWidgets('a capability this Host has never heard of is held back too',
        (tester) async {
      // The other direction of skew: this app is newer than the Host, so the
      // name is simply absent from the map. Absent and false mean the same
      // thing to a person — the Host is not offering it — and the row says so
      // rather than pretending the feature works.
      await _pumpWithContext(
        tester,
        _context(capabilities: {'persona.author': true}),
      );

      expect(find.text('暂不可用'), findsNWidgets(3));
      final persona = tester.widget<ListTile>(
        find.byKey(const Key('companion-open-persona')),
      );
      expect(persona.enabled, isTrue, reason: 'the one it did name');
    });
  });
}
