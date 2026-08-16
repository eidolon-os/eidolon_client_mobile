import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/workspace_runtime_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _companionId = 'c_683f963f54885e86892416894c9d92d1';

WorkspaceRuntime _runtime({String name = '小忆'}) =>
    WorkspaceRuntime.fromJson({
      'contract_version': '1',
      'operation_id': '32c421a3-e0df-40f9-8f75-68745ae39d81',
      'state': 'ready',
      'owner': {
        'owner_id': 'owner_primary',
        'display_name': 'Manson',
        'lifecycle_state': 'active',
      },
      'primary_companion': {
        'companion_id': _companionId,
        'display_name': name,
        'lifecycle_state': 'active',
      },
      'persona': {
        'genome_id': 'genome_current',
        'version': 2,
        'lifecycle_state': 'committed',
        'schema_version': 'eidolon.persona_genome',
        'genome_hash': 'sha256:abc',
        'realizer_version': 'realizer-1',
      },
      'memory_workspace': {
        'realm_id': 'realm_current',
        'lifecycle_state': 'active',
      },
    });

MountedDeviceInventory _devices(List<String?> attachedTo) =>
    MountedDeviceInventory.fromJson({
      'contract_version': '1',
      'coverage': 'mounted-devices',
      'devices': [
        for (final (index, companion) in attachedTo.indexed)
          {
            'device_id': 'device-$index',
            'admission_state': companion == null ? 'mounted' : 'ready',
            'mount': {
              'revision': 2,
              'attached_companion_id': companion,
              'updated_at': '2026-08-12T08:10:00Z',
            },
          },
      ],
    });

Future<void> _open(
  WidgetTester tester, {
  MountedDeviceInventory? devices,
  WorkspaceRuntime? runtime,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CompanionPage(
        runtime: runtime ?? _runtime(),
        devices: devices,
        onRename: () {},
        onOpenHistory: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the page is the Eidolon, not the machine it runs on',
      (tester) async {
    await _open(tester);

    expect(find.text('小忆'), findsWidgets);
    expect(find.text('你好，Manson'), findsOneWidget);
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
    await _open(tester, runtime: _runtime(name: ''));

    expect(find.textContaining(_companionId), findsNothing);
    expect(find.text('这个 Eidolon'), findsWidgets);
  });
}
