import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/activity_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_vitals_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/runtime_cockpit_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/workspace_runtime_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


WorkspaceRuntime _runtime() => WorkspaceRuntime.fromJson({
      'contract_version': '1',
      'state': 'ready',
      'operation_id': '32c421a3-e0df-40f9-8f75-68745ae39d81',
      'owner': {
        'owner_id': 'owner-1',
        'display_name': '曼森',
        'lifecycle_state': 'active',
      },
      'primary_companion': {
        'companion_id': 'cmp-1',
        'display_name': 'Eidolon',
        'lifecycle_state': 'active',
      },
      'persona': {
        'genome_id': 'gen-1',
        'version': 3,
        'schema_version': '1',
        'genome_hash': 'abc',
        'realizer_version': '1',
        'lifecycle_state': 'committed',
      },
      'memory_workspace': {
        'realm_id': 'realm-1',
        'lifecycle_state': 'active',
      },
    });

HostVitals _vitals(List<Map<String, dynamic>> rows) =>
    HostVitals.fromView(HostVitalsView.fromJson({
      'operation': 'host.vitals',
      'contract_version': '1',
      'observed_at': '2026-08-19T02:00:00Z',
      'vitals': rows,
    }));

HostServiceInventory _services({int ready = 2, int failed = 0}) =>
    HostServiceInventory(
      services: [
        for (var i = 0; i < ready; i += 1)
          HostService(
            serviceId: 'service-$i',
            required: true,
            enabled: true,
            revision: 1,
            runtimeState: HostServiceRuntimeState.ready,
            detail: null,
            observedAt: DateTime.utc(2026, 8, 19),
          ),
        for (var i = 0; i < failed; i += 1)
          HostService(
            serviceId: 'eidolon-channel',
            required: true,
            enabled: true,
            revision: 1,
            runtimeState: HostServiceRuntimeState.failed,
            detail: '停止接活',
            observedAt: DateTime.utc(2026, 8, 19),
          ),
      ],
    );

MountedDeviceInventory _devices(List<String> names) => MountedDeviceInventory(
      devices: [
        for (final name in names)
          MountedDevice(
            claim: ClaimRecordV1.fromJson({
              'device_ref': {
                'device_instance_id': 'device-$name',
                'owner_domain_id': 'owner-b0a862b0aab941d64554',
                'owner_domain_generation': 3,
                'claim_generation': 1,
                'trust_epoch': 1,
              },
              'business_owner_id': 'owner_683f0000000000000000',
              'manifest_ref': {
                'manifest_id': name,
                'revision': 1,
                'digest': 'sha256:${'a' * 64}',
              },
              'state': 'active',
              'revision': 1,
              'updated_at': '2026-08-19T00:00:00Z',
            }),
            mount: MountedDeviceMount(
              revision: 1,
              attachedCompanionId: 'cmp-1',
              updatedAt: DateTime.utc(2026, 8, 19),
            ),
          ),
      ],
    );

/// Distinguishes "the test did not say" from "the test said there is none".
/// `?? _runtime()` collapsed the two and quietly handed a Workspace to the one
/// test that was about not having one.
const _unset = Object();

Future<void> _open(
  WidgetTester tester, {
  Object? runtime = _unset,
  Future<HostVitals> Function()? loadVitals,
  Future<HostServiceInventory> Function()? listServices,
  Future<HostActivity> Function()? loadActivity,
  Future<List<ControllerView>> Function()? listControllers,
  MountedDeviceInventory? devices,
  String? devicesError,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RuntimeCockpitPage(
        runtime: identical(runtime, _unset)
            ? _runtime()
            : runtime as WorkspaceRuntime?,
        loadVitals: loadVitals ?? () async => _vitals(const []),
        listServices: listServices ?? () async => _services(),
        loadActivity: loadActivity ??
            () async => const HostActivity(moments: []),
        listControllers:
            listControllers ?? () async => const <ControllerView>[],
        devices: devices,
        devicesError: devicesError,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows whose the Host is, and what is attached to whom',
      (tester) async {
    // Devices carry no Owner-given name yet; the accepted Manifest is what a
    // row can honestly say a device is.
    await _open(tester, devices: _devices(['esp-box-3', 'waveshare-amoled']));

    // The information model the console cockpit uses, on a phone: Owner ▸
    // Companion ▸ devices and memory, drawn as containment.
    expect(find.byKey(const Key('cockpit-sovereign-domain')), findsOneWidget);
    expect(find.text('曼森'), findsOneWidget);
    expect(find.text('Eidolon'), findsOneWidget);
    expect(find.text('记忆领域 realm-1'), findsOneWidget);
    expect(find.text('esp-box-3'), findsOneWidget);
    expect(find.text('已附体'), findsNWidgets(2));
  });

  testWidgets('a lane that could not be read says so where it would have been',
      (tester) async {
    await _open(tester, loadVitals: () async => throw StateError('主机没答'));

    // Not a blank card. A section that fails silently is indistinguishable
    // from a healthy machine with nothing to report, and that difference is
    // the reason to look at this screen at all.
    expect(find.textContaining('读不到'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('one lane failing leaves the others standing', (tester) async {
    await _open(
      tester,
      loadVitals: () async => throw StateError('主机没答'),
      listServices: () async => _services(ready: 3, failed: 1),
    );

    // Each is asked for separately so its failure stays its own.
    expect(find.textContaining('读不到'), findsOneWidget);
    expect(find.textContaining('4 项服务，1 项不在就绪状态'), findsOneWidget);
    expect(find.text('eidolon-channel'), findsOneWidget);
  });

  testWidgets('a reading the Host could not take is not drawn as healthy',
      (tester) async {
    await _open(
      tester,
      loadVitals: () async => _vitals([
        {
          'name': '温度',
          'reading': '读不到',
          'concern': 'none',
          'unavailable_reason': '/sys/class/thermal: absent',
        },
        {'name': '内存', 'reading': '1.2 GB 可用', 'concern': 'act'},
      ]),
    );

    // A green tick would claim the machine is fine on exactly the evidence
    // that is missing, so unknown gets its own mark.
    expect(find.byIcon(Icons.help_outline), findsWidgets);
    expect(find.text('读不到'), findsOneWidget);
  });

  testWidgets('nobody having asked is not the same as having none',
      (tester) async {
    await _open(tester, devices: null);

    expect(find.textContaining('还没有问过这台主机的设备'), findsOneWidget);
  });

  testWidgets('what no authority publishes is named, not omitted',
      (tester) async {
    await _open(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('cockpit-not-published')),
      300,
    );

    // The console cockpit could show these when it read the database. Leaving
    // them out entirely would teach the reader this Host has no conversations
    // and no jobs, which is false.
    expect(find.byKey(const Key('cockpit-not-published')), findsOneWidget);
    expect(find.textContaining('对话记录'), findsOneWidget);
    expect(find.textContaining('Guard 绑定'), findsOneWidget);
  });

  testWidgets('a Host with no Workspace has no domain to draw', (tester) async {
    await _open(tester, runtime: null);

    expect(find.byKey(const Key('cockpit-sovereign-domain')), findsNothing);
    expect(find.textContaining('还没有建立 Workspace'), findsOneWidget);
  });
}
