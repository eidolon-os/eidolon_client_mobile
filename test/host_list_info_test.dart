import 'dart:async';

import 'package:eidolon_client_mobile/src/features/setup/eidolon_app_shell.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_list_info.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ManagedHost host() => ManagedHost(
      hostId: 'ehost-0123456789abcdefabcd',
      hostPublicKey: 'key',
      hostFingerprint: 'fingerprint',
      bleServiceUuid: 'uuid',
      controllerId: 'controller',
      displayName: '书房主机',
      claimedAt: DateTime.utc(2026),
      lastKnownBaseUrl: 'https://192.168.1.32:9002',
    );
const info = HostMachineInfo(
    hostname: 'study.local',
    model: 'Mac15,6',
    cpuModel: 'Apple M3 Pro',
    operatingSystem: 'macOS 15',
    cpuCores: 12,
    memoryBytes: 36 * 1024 * 1024 * 1024);

void main() {
  test('old records load and identification survives rename without telemetry',
      () {
    final old = ManagedHost.fromJson(host().toJson());
    expect(old.machineInfo, isNull);
    final saved = ManagedHost.fromJson(old
            .copyWith(
                machineInfo: info, lastConnectedAt: DateTime.utc(2026, 9, 9))
            .toJson())
        .copyWith(displayName: '新备注');
    expect(saved.machineInfo!.model, 'Mac15,6');
    expect(saved.lastConnectedAt, DateTime.utc(2026, 9, 9));
    expect(saved.toJson().toString(), isNot(contains('usage_percent')));
  });

  testWidgets(
      'shows address immediately and verified hardware later on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reply = Completer<HostListInfo>();
    final registry = InMemoryHostRegistry([host()]);
    await tester.pumpWidget(MaterialApp(
        home: EidolonAppShell(
            registry: registry, hostInfoReader: (_) => reply.future)));
    await tester.pumpAndSettle();
    expect(find.text('上次连接地址：192.168.1.32'), findsOneWidget);
    expect(find.text('正在确认连接'), findsOneWidget);
    reply.complete(HostListInfo(
        host().copyWith(machineInfo: info, lastConnectedAt: DateTime.now()),
        '上次验证可连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Apple M3 Pro'), findsOneWidget);
    expect(find.text('主机名：study.local'), findsOneWidget);
    expect(find.text('上次验证可连接'), findsOneWidget);
    expect((await registry.load()).single.machineInfo!.cpuCores, 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late metadata never restores a removed Host', (tester) async {
    final reply = Completer<HostListInfo>();
    final registry = InMemoryHostRegistry([host()]);
    await tester.pumpWidget(MaterialApp(
        home: EidolonAppShell(
            registry: registry, hostInfoReader: (_) => reply.future)));
    await tester.pumpAndSettle();
    await registry.remove(host().hostId);
    reply.complete(HostListInfo(host().copyWith(machineInfo: info), '上次验证可连接'));
    await tester.pumpAndSettle();
    expect(await registry.load(), isEmpty);
  });
}
