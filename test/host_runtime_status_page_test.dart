import 'dart:async';

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/activity_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_runtime_status_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_vitals_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';

/// 主机运行状态 — one page where there were three.
///
/// 运行驾驶舱, 主机动态 and 查看系统状态 read overlapping sources (services three
/// times, activity twice) and each drew everything at full size, always. What
/// makes this one page rather than those three stacked is the verdict: one line
/// computed from the same reads the rows are drawn from, with the deviations
/// under it and their actions beside them.
///
/// The assertions here are the ones those three screens earned, ported to where
/// the behaviour now lives — plus the ones the merge itself creates: a reason
/// appears once, a healthy Host is one line, and nothing is called 正常 before
/// the reading lands.
///
/// What is *not* here on purpose: whose the Host is, which Eidolons exist, what
/// is happening for them. That is 驾驶舱. The old 运行驾驶舱 read `home` and
/// blurred the boundary §3.2 argued for.

ManagedHost _host() => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: '客厅主机',
      claimedAt: DateTime.utc(2026, 8, 5),
    );

HostProductConnection _connection() => HostProductConnection(
      endpoint: const LocalApiEndpoint(
        instanceName: 'eidolon-local-api',
        baseUrl: 'https://192.168.1.26:9002',
        ipAddress: '192.168.1.26',
        contractVersion: '1',
      ),
      overview: HostOverview.fromJson({
        'contract_version': '1',
        'status': 'running',
        'mode': 'production',
        'descriptor': {
          'contract_version': '1',
          'host_id': validHostId,
          'host_public_key': validHostPublicKey,
          'host_public_key_fingerprint': validHostPublicKeyFingerprint,
          'ble_service_uuid': validBleServiceUuid,
        },
        'state': {
          'reset_epoch': 2,
          'claim_state': 'claimed',
          'network_state': 'connected',
          'updated_at': '2026-08-11T00:00:00Z',
        },
      }),
      controllerId: 'ectrl-0123456789abcdefabcd',
      ownerId: 'owner-1',
      sessionExpiresAt: DateTime.utc(2026, 8, 11, 1),
    );

HostMoment _moment({
  String eventId = 'evt-1',
  String action = 'companion.archived',
  String subjectName = '小忆',
  Map<String, String> detail = const {},
}) =>
    HostMoment(
      eventId: eventId,
      occurredAt: DateTime.utc(2026, 8, 17, 2, 14),
      action: action,
      subjectType: 'companion',
      subjectId: 'companion-a',
      subjectName: subjectName,
      outcome: 'success',
      detail: detail,
    );

HostVitals _vitals(List<Map<String, dynamic>> rows) =>
    HostVitals.fromView(HostVitalsView.fromJson({
      'operation': 'host.vitals',
      'contract_version': '1',
      'observed_at': '2026-08-19T02:00:00Z',
      'vitals': rows,
    }));

HostService _service(
  String id, {
  HostServiceRuntimeState state = HostServiceRuntimeState.ready,
  bool required = true,
}) =>
    HostService(
      serviceId: id,
      required: required,
      enabled: true,
      revision: 1,
      runtimeState: state,
      detail: null,
      observedAt: DateTime.utc(2026, 8, 27),
    );

Future<void> _open(
  WidgetTester tester, {
  Future<HostVitals> Function()? readVitals,
  Future<HostServiceInventory> Function()? listServices,
  Future<HostActivity> Function()? loadActivity,
  Future<List<ControllerView>> Function()? listControllers,
  MountedDeviceInventory? devices,
  String? devicesError,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: HostRuntimeStatusPage(
        host: _host(),
        connection: _connection(),
        readVitals: readVitals ?? () async => _vitals(const []),
        listServices: listServices ??
            () async => HostServiceInventory(services: [_service('hub')]),
        loadActivity:
            loadActivity ?? () async => const HostActivity(moments: []),
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
  testWidgets('一台没事的主机就是一行', (tester) async {
    await _open(tester);

    expect(find.byKey(const Key('host-runtime-verdict')), findsOneWidget);
    expect(find.text('这台主机一切正常'), findsOneWidget);
    // 三块屏的老毛病：把能读到的一切按原尺寸铺开。正常的东西压成一行。
    expect(find.textContaining('需要处理'), findsNothing);
  });

  testWidgets('读完之前不宣布正常', (tester) async {
    // 「一切正常」出自一块还没问过的屏，是这一屏上最贵的一句话。
    final gate = Completer<HostVitals>();
    await tester.pumpWidget(
      MaterialApp(
        home: HostRuntimeStatusPage(
          host: _host(),
          connection: _connection(),
          readVitals: () => gate.future,
          listServices: () async =>
              HostServiceInventory(services: [_service('hub')]),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在读这台主机'), findsOneWidget);
    expect(find.text('这台主机一切正常'), findsNothing);

    gate.complete(_vitals(const []));
    await tester.pumpAndSettle();
    expect(find.text('这台主机一切正常'), findsOneWidget);
  });

  testWidgets('主机说该处理的就排在最上面，动作在它自己那一行', (tester) async {
    var restarted = <String>[];
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostRuntimeStatusPage(
          host: _host(),
          connection: _connection(),
          readVitals: () async => _vitals(const []),
          listServices: () async => HostServiceInventory(
            services: [
              _service('memory', state: HostServiceRuntimeState.failed)
            ],
          ),
          changeService: ({
            required String serviceId,
            required String operation,
            required int expectedRevision,
          }) async {
            restarted.add(serviceId);
            return HostServiceChange(
              serviceId: serviceId,
              operation: operation,
              enabled: true,
              revision: expectedRevision + 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('有 1 项需要处理'), findsOneWidget);
    // 不用展开底座就能动手：动作和它作用的东西在一起，这是没有独立服务卡的原因。
    await tester.tap(find.byKey(const Key('restart-memory')));
    await tester.pumpAndSettle();
    expect(restarted, ['memory']);
  });

  testWidgets('读不到的来源自成一类，而且原因只说一次', (tester) async {
    await _open(
      tester,
      readVitals: () async => throw Exception('Host vitals 返回 HTTP 500'),
    );

    expect(find.text('有 1 项读不到，状态未知'), findsOneWidget);
    // 原因在判词里，一次。那一行只说短状态 —— 同一句话不在一屏上出现两次。
    expect(find.textContaining('HTTP 500'), findsOneWidget);
    expect(find.text('读不到'), findsWidgets);
  });

  testWidgets('一个来源塌了，其余照读', (tester) async {
    await _open(
      tester,
      readVitals: () async => throw Exception('机器读不到'),
      listServices: () async =>
          HostServiceInventory(services: [_service('hub'), _service('agent')]),
    );

    // 底座照样答了 2/2，机器那一行自己说读不到。
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byKey(const Key('host-machine-line')), findsOneWidget);
  });

  testWidgets('没人问过设备，不等于没有设备', (tester) async {
    await _open(tester);

    // 那一行自己说「还没有问过」，而不是「0 台」——一块开早了的屏不该读成一台
    // 没有设备的主机。（管理手机那一行的 0 台是真的：清单读到了，就是空的。）
    final bodies = find.descendant(
      of: find.byKey(const Key('host-bodies-line')),
      matching: find.text('还没有问过'),
    );
    expect(bodies, findsOneWidget);
  });

  testWidgets('改动说成句子，不说事件类型', (tester) async {
    await _open(
      tester,
      loadActivity: () async => HostActivity(
        moments: [
          _moment(eventId: 'evt-2', action: 'companion.workspace.initialized'),
          _moment(detail: const {'companion_id_name': '阿力'}),
        ],
      ),
    );

    expect(find.text('「小忆」来了'), findsOneWidget);
    expect(find.text('你把「小忆」收了起来，改由「阿力」回答'), findsOneWidget);
    // 主机自己的措辞永远不到人面前。
    expect(find.textContaining('companion.'), findsNothing);
  });

  testWidgets('这份清单不知道什么，说出来', (tester) async {
    await _open(tester,
        loadActivity: () async => HostActivity(moments: [_moment()]));

    final coverage = tester.widget<Text>(
      find.byKey(const Key('host-changes-coverage')),
    );
    // 从主机动态原样搬过来：看起来完整而其实不完整的清单，比一份说清自己装了
    // 什么的短清单更糟。
    expect(coverage.data, contains('设备是否在线不在其中'));
    expect(find.text('最近的改动'), findsOneWidget);
  });

  testWidgets('出问题时要引用的东西，默认收起', (tester) async {
    await _open(tester);

    // Host ID 和 fingerprint 是抄给别人的，不是读的 —— 三块老屏各自把它们按原
    // 尺寸摊开。
    expect(find.text(validHostId), findsNothing);
    await tester.tap(find.byKey(const Key('host-for-quoting')));
    await tester.pumpAndSettle();
    expect(find.text(validHostId), findsOneWidget);
  });

  testWidgets('这一屏不画当前的域，只在改动记录里复述对它做过的事', (tester) async {
    await _open(tester,
        loadActivity: () async => HostActivity(moments: [_moment()]));

    // 边界是「当前状态」而不是「这个词」：谁是主人、有哪些 Eidolon、正在为它们
    // 发生什么，归驾驶舱 —— 老的运行驾驶舱读 home，把这条边界糊掉了。
    // 改动记录会提到伙伴，因为它本来就是伙伴变动的记录（主机动态一直如此），
    // 这是这次合并把它放在这里的代价，也是它被命名为「最近的改动」的原因。
    expect(find.textContaining('位伙伴'), findsNothing);
    expect(find.byKey(const Key('host-changes-coverage')), findsOneWidget);
    // 而且它明确把域指向另一块屏。
    expect(find.textContaining('在「驾驶舱」'), findsOneWidget);
  });
}
