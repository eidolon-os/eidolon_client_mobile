import 'dart:async';

import 'package:eidolon_client_mobile/src/features/host_setup/host_runtime_status_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/monitor_fixtures.dart';

Future<void> openMonitor(
    WidgetTester tester, Future<HostMonitorWire> Function() read,
    {Size size = const Size(900, 1800)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: HostRuntimeStatusPage(
    host: monitorHost(),
    connection: monitorConnection(),
    readMonitor: read,
  )));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('10 second polling never overlaps; only one snapshot is shown',
      (tester) async {
    var reads = 0;
    final pending = Completer<HostMonitorWire>();
    await openMonitor(tester, () {
      reads++;
      return reads == 1 ? Future.value(monitorSnapshot()) : pending.future;
    });
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 9));
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 2);
    await tester.pump(const Duration(seconds: 30));
    expect(reads, 2);
    pending.complete(monitorSnapshot(cpu: 77));
    await tester.pump();
    expect(find.text('77.0%'), findsWidgets);
    expect(find.text('30.0%'), findsNothing);
    expect(find.textContaining('最近 15 分钟'), findsNothing);
    expect(find.text('每 10 秒刷新'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
    expect(reads, 2);
  });

  testWidgets('background pauses and foreground immediately refreshes',
      (tester) async {
    var reads = 0;
    await openMonitor(tester, () async {
      reads++;
      return monitorSnapshot();
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 40));
    expect(reads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('covered route pauses and popping it reads immediately',
      (tester) async {
    var reads = 0;
    await openMonitor(tester, () async {
      reads++;
      return monitorSnapshot();
    });
    final context = tester.element(find.byType(HostRuntimeStatusPage));
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('other page')))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 40));
    expect(reads, 1);
    Navigator.of(tester.element(find.text('other page'))).pop();
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed refresh marks old snapshot stale and can recover',
      (tester) async {
    var reads = 0;
    await openMonitor(tester, () async {
      reads++;
      if (reads == 2) throw Exception('private transport exception');
      return monitorSnapshot();
    });
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.textContaining('数据已过期'), findsOneWidget);
    expect(find.textContaining('private transport'), findsNothing);
    expect(find.text('主机本地管理正常'), findsNothing);
    await tester.tap(find.byKey(const Key('host-runtime-status-refresh')));
    await tester.pump();
    expect(find.textContaining('数据已过期'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'legacy host offers update guidance instead of fabricated numbers',
      (tester) async {
    await openMonitor(
        tester,
        () async =>
            throw const ManagementRequestException('missing', statusCode: 404));
    expect(find.textContaining('请更新主机软件'), findsOneWidget);
    expect(find.text('0.0%'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'narrow page shows core models and startup details without overflow',
      (tester) async {
    await openMonitor(tester, () async => monitorSnapshot(),
        size: const Size(360, 2200));
    expect(find.text('Cortex-A55'), findsOneWidget);
    expect(find.text('Cortex-A76'), findsOneWidget);
    expect(find.text('CPU 0'), findsOneWidget);
    expect(find.text('NPU 1'), findsOneWidget);
    expect(find.text('驱动未提供'), findsOneWidget);
    expect(find.text('0.0%'), findsOneWidget);
    await tester.ensureVisible(find.text('hub'));
    await tester.tap(find.text('hub'));
    await tester.pumpAndSettle();
    expect(find.text('/etc/systemd/eidolon-hub.service'), findsOneWidget);
    await tester.ensureVisible(find.text('python · PID 100'));
    await tester.tap(find.text('python · PID 100'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('/opt/eidolon/hub/server.py'));
    expect(find.text('/opt/eidolon/hub/server.py'), findsOneWidget);
    expect(find.text('python server.py --token [redacted]'), findsOneWidget);
    expect(find.text('重启'), findsNothing);
    expect(find.text('让所有设备重新登录'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('/opt/eidolon/hub/server.py'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
