import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/activity_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_vitals_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/runtime_cockpit_page.dart';
import 'package:flutter/material.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/home_models.dart';
import 'package:flutter_test/flutter_test.dart';



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

/// One device as the Host now describes it: composed and phrased on that side,
/// so this fixture states an answer rather than three authorities' halves.
MountedDevice _mountedDevice(String name) => MountedDevice.fromView(
      DeviceView.fromJson({
        'device_id': 'device-$name',
        'label': name,
        'kind': name,
        'state': 'ready',
        'answers_as_companion_id': 'cmp-1',
        'answers_as_companion_name': '小忆',
        'revision': 1,
        'updated_at': '2026-08-19T00:00:00Z',
        'online': 'unknown',
        'online_reason': '这台主机没有任何东西在观测设备是否开着',
        'claim_state': 'active',
        'claim_generation': 1,
        'trust_epoch': 1,
        'owner_domain_generation': 3,
        'manifest_id': name,
        'manifest_revision': 1,
      }),
    );

MountedDeviceInventory _devices(List<String> names) => MountedDeviceInventory(
      devices: [
        for (final name in names)
          _mountedDevice(name),
      ],
    );

/// Distinguishes "the test did not say" from "the test said there is none".
/// `?? _runtime()` collapsed the two and quietly handed a Workspace to the one
/// test that was about not having one.
const _unset = Object();

/// What the Host now answers when a screen opens: words a person can act on,
/// with the identifiers underneath.
HostHome _home({String name = '小忆', String? companionId = 'cmp-1'}) =>
    HostHome.fromView(
      HomeView.fromJson({
        'contract_version': '1',
        'owner_display_name': 'Manson',
        'owner_revision': 3,
        'answering': companionId == null
            ? null
            : {
                'companion_id': companionId,
                'display_name': name,
                'lifecycle_state': 'active',
                'revision': 4,
                'has_face': false,
                'persona_chapter': '第 2 章 · 我发现你不喜欢被打断',
                'memory': '记着 12 条',
                'persona_genome_id': 'genome_2',
              },
        'companions': {'total': 1, 'ready': 1, 'waiting': 0, 'put_away': 0},
        'devices': {'total': 1, 'ready': 1, 'waiting': 0, 'put_away': 0},
        'machine_attention': <String>[],
        'unavailable': <String, String>{},
      }),
    );

Future<void> _open(
  WidgetTester tester, {
  Object? home = _unset,
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
        home: identical(home, _unset) ? _home() : home as HostHome?,
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
    expect(find.text('Manson'), findsOneWidget);
    expect(find.text('小忆'), findsOneWidget);
    // Words, not identifiers: which chapter it is on and how much it remembers,
    // where a genome version and a realm id used to be.
    expect(find.text('第 2 章 · 我发现你不喜欢被打断'), findsOneWidget);
    expect(find.text('记着 12 条'), findsOneWidget);
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
    await _open(tester, home: null);

    expect(find.byKey(const Key('cockpit-sovereign-domain')), findsNothing);
    expect(find.textContaining('还没有建立 Workspace'), findsOneWidget);
  });
}
