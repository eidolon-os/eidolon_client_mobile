import 'dart:async';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_locator.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';
import 'support/admission_fixtures.dart';

/// Setting up a device is two visits to it, and the Host is asked between them.
///
/// Not a preference about ordering. A phone joins a device's access point with
/// the same radio it reaches the Host on, and while it is there the platform
/// reports that access point as the only network the phone has — measured on
/// real hardware, where a request meant for the Host sat for 26 seconds and
/// then failed. So the session must be closed before the Host is asked, and
/// re-opened afterwards to hand over what the Host said.
void main() {
  testWidgets(
      'refused rescan preserves the last device with an explicit warning',
      (tester) async {
    final transport = _Transport();
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: _Admission(transport),
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    expect(find.text('Eidolon Body 1'), findsOneWidget);
    transport.discoveryFailure = const DeviceProvisioningTransportException(
        'device_scan_stale', '扫描未刷新');
    await tester.tap(find.text('重新查找'));
    await tester.pumpAndSettle();
    expect(find.text('Eidolon Body 1'), findsOneWidget);
    expect(find.textContaining('以下为上次发现的设备'), findsOneWidget);
    expect(find.text('扫描未刷新'), findsOneWidget);
  });

  testWidgets(
      'phone Wi-Fi shortcut selects the captured network without submitting',
      (tester) async {
    final transport = _Transport()..requiresVoucher = false;
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: _Admission(transport),
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-phone-wifi')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListTile>(find.byKey(const Key('network-owner-wifi')))
            .selected,
        isTrue);
    expect(transport.sessions.single.writes, 0);
  });

  testWidgets('failed authority query never opens a device setup session',
      (tester) async {
    final transport = _Transport();
    final admission = _Admission(transport)
      ..claimsFailure = StateError('Host unavailable');
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: admission,
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    expect(transport.sessions, isEmpty);
    expect(find.textContaining('Eidolon Body 1'), findsNothing);
    expect(admission.voucherAttempts, 0);
  });
  for (final rotates in [true, false]) {
    testWidgets(
        'revoked Host claim renews authorization with stable identity: rotates=$rotates',
        (tester) async {
      const channel = MethodChannel('live.eidolon.mobile/platform');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'verifyOwnerDomainDescriptor' ? true : null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final id = 'device-instance-${'a' * 64}';
      final transport = _Transport()
        ..configureFailure = const DeviceProvisioningTransportException(
            'commissioning_terminal_timeout', 'Unknown',
            outcomeUnknown: true)
        ..preparedDeviceId = rotates ? 'device-instance-${'b' * 64}' : id;
      final admission = _Admission(transport)..publishEnrollment = false;
      final claim = canonicalContractValue('DF-ADMISSION-CLAIM-RECORD-VALID');
      admission.claims = [
        {
          ...claim,
          'state': 'revoked',
          'device_ref': {
            ...Map<String, dynamic>.from(claim['device_ref'] as Map),
            'owner_domain_id': ownerDomainIdFixture,
            'device_instance_id': id,
          }
        }
      ];
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
        knownDevices: {id: 'old StackChan'},
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      expect(transport.sessions.single.replacementRequested, isTrue);
      expect(transport.sessions.single.writes, 0);
      expect(admission.voucherAttempts, rotates ? 0 : 1);
      expect(find.text('需要作为新设备添加'), rotates ? findsOneWidget : findsNothing);
      if (rotates) {
        await tester.tap(find.byKey(const Key('accept-new-device-identity')));
        await tester.pumpAndSettle();
        expect(admission.requestedKey, 'p256:${'b' * 64}');
      }
      {
        await tester.tap(find.byKey(const Key('network-owner-wifi')));
        await tester.pump();
        await tester.enterText(
            find.byKey(const Key('device-wifi-password')), 'pw');
        await tester.tap(find.byKey(const Key('confirm-device-setup')));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(transport.sessions.last.writes, 1);
        expect(transport.sessions.last.sentReplacement, isTrue);
        expect(transport.sessions.last.sentVoucher, isNotNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
      'unknown network outcome keeps admission recovery visible across restart',
      (tester) async {
    const channel = MethodChannel('live.eidolon.mobile/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'verifyOwnerDomainDescriptor' ? true : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final transport = _Transport()
      ..configureFailure = const DeviceProvisioningTransportException(
          'commissioning_terminal_timeout', 'Unknown',
          outcomeUnknown: true);
    final admission = _Admission(transport)..publishEnrollment = false;
    final store = InMemoryDeviceSetupCheckpointStore();
    Widget page() => MaterialApp(
        home: DeviceSetupPage(
            transport: transport,
            admission: admission,
            checkpoints: store,
            loadTarget: () async => deviceOnboardingTargetFixture()));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('network-owner-wifi')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('device-wifi-password')), 'pw');
    await tester.tap(find.byKey(const Key('confirm-device-setup')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('正在确认设备接入结果'), findsOneWidget);
    expect(find.text('Wi-Fi 已配置，正在接入主机'), findsNothing);
    expect(find.byKey(const Key('resume-device-admission')), findsOneWidget);
    expect(transport.opened, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('继续接入'), findsOneWidget);
    admission.publishEnrollment = true;
    await tester.tap(find.text('继续接入'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(admission.decisions, 1);
    expect(transport.opened, 2);
    expect(find.text('选择家庭 Wi-Fi'), findsNothing);
    admission.current = canonicalProjection(
        state: 'grant_acknowledged',
        ownerDomainId: ownerDomainIdFixture,
        deviceId: 'device-instance-${'a' * 64}',
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
        claimOwnerDomainGeneration: 1);
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('主机已确认设备接入'), findsOneWidget);
    expect(find.textContaining('本次 Wi-Fi 配置结果仍未确认'), findsOneWidget);
    expect(find.text('设备已接入这台主机'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'network maintenance refuses another identity before owner preparation',
      (tester) async {
    final transport = _Transport();
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: _Admission(transport),
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
      expectedDeviceId: 'device-instance-${'b' * 64}',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发现的设备身份与原记录不同'), findsOneWidget);
    expect(transport.sessions.single.prepared, isFalse);
    expect(transport.sessions.single.closed, isTrue);
    expect(transport.sessions.single.writes, 0);
  });

  testWidgets('duplicate Wi-Fi SSIDs keep only the strongest network',
      (tester) async {
    final transport = _Transport()
      ..scanNetworksResult = const [
        DeviceWifiNetwork(
          ssid: 'mesh-wifi',
          signalStrength: -40,
          security: 'strongest',
        ),
        DeviceWifiNetwork(
          ssid: 'mesh-wifi',
          signalStrength: -67,
          security: 'weaker',
        ),
      ];
    await tester.pumpWidget(MaterialApp(
      home: DeviceSetupPage(
        transport: transport,
        admission: _Admission(transport),
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();

    expect(find.text('mesh-wifi'), findsOneWidget);
    expect(find.text('strongest'), findsOneWidget);
    expect(find.text('weaker'), findsNothing);
  });

  testWidgets(
      'network maintenance recognizes the original device and reuses standing',
      (tester) async {
    final transport = _Transport()..requiresVoucher = false;
    final id = 'device-instance-${'a' * 64}';
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: _Admission(transport),
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
      expectedDeviceId: id,
      knownDevices: {id: '书房 BOX-3'},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已识别原设备：书房 BOX-3'), findsOneWidget);
    expect(transport.sessions.single.closed, isTrue);
    expect(transport.sessions.single.writes, 0);
  });

  testWidgets(
      'changed identity asks before requesting new authority or writing network',
      (tester) async {
    final id = 'device-instance-${'a' * 64}';
    final transport = _Transport()
      ..preparedDeviceId = 'device-instance-${'b' * 64}';
    final admission = _Admission(transport);
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: admission,
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
      knownDevices: {id: 'BOX-3'},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(find.text('需要作为新设备添加'), findsOneWidget);
    expect(transport.sessions.single.closed, isTrue);
    expect(transport.sessions.single.writes, 0);
    expect(admission.voucherAttempts, 0);
    expect(find.textContaining('列表可能同时显示新旧两条记录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-new-device-identity')));
    await tester.pumpAndSettle();
    expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
    expect(admission.requestedKey, 'p256:${'b' * 64}');
    expect(admission.sessionsOpenWhenAsked, [0]);
    expect(transport.sessions.single.writes, 0);
  });

  testWidgets('changed identity cannot reuse old authorization',
      (tester) async {
    final transport = _Transport()
      ..preparedDeviceId = 'device-instance-${'b' * 64}'
      ..requiresVoucher = false;
    final admission = _Admission(transport);
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: admission,
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未请求新的授权'), findsOneWidget);
    expect(find.byKey(const Key('accept-new-device-identity')), findsNothing);
    expect(admission.voucherAttempts, 0);
    expect(transport.sessions.single.writes, 0);
    expect(transport.sessions.single.closed, isTrue);
  });

  testWidgets(
      'cancelling identity change creates no authorization or network write',
      (tester) async {
    final transport = _Transport()
      ..preparedDeviceId = 'device-instance-${'b' * 64}';
    final admission = _Admission(transport);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
      builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => DeviceSetupPage(
                  transport: transport,
                  admission: admission,
                  checkpoints: InMemoryDeviceSetupCheckpointStore(),
                  loadTarget: () async => deviceOnboardingTargetFixture(),
                ),
              )),
          child: const Text('open setup')),
    )));
    await tester.tap(find.text('open setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel-new-device-identity')));
    await tester.pumpAndSettle();
    expect(find.text('open setup'), findsOneWidget);
    expect(admission.voucherAttempts, 0);
    expect(transport.sessions.single.writes, 0);
    expect(transport.sessions.single.closed, isTrue);
  });

  testWidgets('cancelling setup returns no completed device', (tester) async {
    String? completedDeviceId = 'must not survive cancellation';
    final transport = _Transport();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
      builder: (context) => TextButton(
          onPressed: () async {
            completedDeviceId =
                await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => DeviceSetupPage(
                transport: transport,
                admission: _Admission(transport),
                checkpoints: InMemoryDeviceSetupCheckpointStore(),
                loadTarget: () async => deviceOnboardingTargetFixture(),
              ),
            ));
          },
          child: const Text('open setup')),
    )));
    await tester.tap(find.text('open setup'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(completedDeviceId, isNull);
    expect(transport.opened, 0);
  });

  testWidgets(
      'scan failure releases visit and exposes manual network input without submitting',
      (tester) async {
    final transport = _Transport()
      ..requiresVoucher = false
      ..scanFailure = const DeviceProvisioningTransportException(
          'device_scan_failed', 'scan failed');
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: _Admission(transport),
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
    expect(find.textContaining('可以手动输入网络名称'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Wi-Fi 名称'), findsOneWidget);
    expect(transport.sessions.single.closed, isTrue);
    expect(transport.sessions.single.writes, 0);
  });

  testWidgets(
      'Owner preparation refusal remains visible and releases the session',
      (tester) async {
    final transport = _Transport()
      ..preparationFailure = const DeviceProvisioningTransportException(
          'owner_preparation_failed', '设备尚未完成归属准备，请保持配置连接后重试。');
    await tester.pumpWidget(MaterialApp(
        home: DeviceSetupPage(
      transport: transport,
      admission: _Admission(transport),
      checkpoints: InMemoryDeviceSetupCheckpointStore(),
      loadTarget: () async => deviceOnboardingTargetFixture(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(find.text('设备尚未完成归属准备，请保持配置连接后重试。'), findsOneWidget);
    expect(find.text('这台手机没能完成这次操作。'), findsNothing);
    expect(transport.sessions.single.closed, isTrue);
  });

  for (final restart in [false, true]) {
    testWidgets(
        'duplicate confirmation converges without replay (restart: $restart)',
        (tester) async {
      const channel = MethodChannel('live.eidolon.mobile/platform');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'verifyOwnerDomainDescriptor' ? true : null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final transport = _Transport();
      final admission = _Admission(transport);
      final store = InMemoryDeviceSetupCheckpointStore();
      if (restart) {
        admission.current = canonicalProjection(
            state: 'rejected',
            ownerDomainId: ownerDomainIdFixture,
            deviceId: 'device-instance-${'a' * 64}');
        await store.save(DeviceSetupCheckpoint(
          commissioningProofDigest:
              'sha256:256d04db4e5e4ac308751ed0885b722b758630567c53a7125ed9fbd068e5c3f6',
          contractVersion: DeviceSetupCheckpoint.currentContractVersion,
          setupId: 'previous',
          requestId: 'previous-intent',
          createCommandId: 'previous-create',
          decisionRequestId: 'previous-decision',
          collectCommandId: 'previous-collect',
          ackCommandId: 'previous-ack',
          provisioningState: DeviceProvisioningState.networkConfigured,
          admissionState: DeviceAdmissionState.pendingReview,
          updatedAt: DateTime.now().toUtc(),
          onboardingTarget: deviceOnboardingTargetFixture(),
          deviceId: 'device-instance-${'a' * 64}',
          enrollmentId: 'enrollment_01',
        ));
      }
      final gate = Completer<void>();
      transport.configurationGate = gate.future;
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: store,
        loadTarget: () async => deviceOnboardingTargetFixture(),
      )));
      await tester.pumpAndSettle();
      if (restart) {
        await tester.tap(find.text('继续接入'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('restart-device-setup')));
        await tester.pumpAndSettle();
        admission.current = canonicalProjection(
            state: 'pending_review',
            ownerDomainId: ownerDomainIdFixture,
            deviceId: 'device-instance-${'a' * 64}');
      }
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network-owner-wifi')));
      await tester.pump();
      final confirm = tester
          .widget<FilledButton>(find.byKey(const Key('confirm-device-setup')))
          .onPressed!;
      if (!restart) {
        await tester.enterText(
            find.byKey(const Key('device-wifi-password')), 'test-password');
        await tester.testTextInput.receiveAction(TextInputAction.go);
      }
      // Keyboard submission and a button callback must not start two writes.
      confirm();
      confirm();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(transport.opened, 2);
      expect(find.byKey(const Key('resume-device-admission')), findsNothing);
      expect(find.byKey(const Key('restart-device-setup')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(transport.opened, 2);
      expect(find.text('选择家庭 Wi-Fi'), findsNothing);
      expect(find.text('Wi-Fi 已配置，正在接入主机'), findsNothing);
      admission.publishEnrollment = false;
      gate.complete();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      // A committed network is visible even when device enrollment is late.
      // Waiting must not reopen SoftAP or need a refresh/approval tap.
      expect(find.text('Wi-Fi 已配置，正在接入主机'), findsOneWidget);
      expect(find.text('等待设备向主机登记，状态会自动更新'), findsOneWidget);
      expect(find.text('设备已接入这台主机'), findsNothing);
      expect(admission.decisions, 0);
      await tester.pump(const Duration(seconds: 30));
      expect(transport.opened, 2);
      admission.publishEnrollment = true;
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(admission.decisions, 1);
      expect(find.text('选择家庭 Wi-Fi'), findsNothing);
      admission.current = canonicalProjection(
        state: 'grant_acknowledged',
        ownerDomainId: ownerDomainIdFixture,
        deviceId: 'device-instance-${'a' * 64}',
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
        claimOwnerDomainGeneration: 1,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('设备已接入这台主机'), findsOneWidget);
      expect(transport.opened, 2);
      expect(transport.sessions.fold<int>(0, (sum, s) => sum + s.writes), 1);
      expect(admission.decisions, 1);
    });
  }

  testWidgets(
      'same Owner network maintenance reuses admission without a voucher',
      (tester) async {
    const channel = MethodChannel('live.eidolon.mobile/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'verifyOwnerDomainDescriptor' ? true : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final transport = _Transport()..requiresVoucher = false;
    final admission = _Admission(transport)
      ..current = canonicalProjection(
        state: 'grant_acknowledged',
        ownerDomainId: ownerDomainIdFixture,
        deviceId: 'device-instance-${'a' * 64}',
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
        claimOwnerDomainGeneration: 1,
      );
    admission.claims = [
      Map<String, dynamic>.from(admission.current.json['claim'] as Map)
    ];
    String? completedDeviceId;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
      builder: (context) => TextButton(
          onPressed: () async {
            completedDeviceId =
                await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => DeviceSetupPage(
                transport: transport,
                admission: admission,
                checkpoints: InMemoryDeviceSetupCheckpointStore(),
                loadTarget: () async => deviceOnboardingTargetFixture(),
              ),
            ));
          },
          child: const Text('open setup')),
    )));
    await tester.tap(find.text('open setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();
    expect(admission.sessionsOpenWhenAsked, isEmpty);
    await tester.tap(find.byKey(const Key('network-owner-wifi')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-setup')));
    await tester.pumpAndSettle();
    expect(transport.sessions.last.sentVoucher, isNull);
    expect(transport.sessions.last.writes, 1);
    expect(admission.decisions, 0);
    expect(find.text('设备已接入这台主机'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(completedDeviceId, 'device-instance-${'a' * 64}');
  });

  testWidgets('the Host is asked only while no session is held',
      (tester) async {
    final transport = _Transport();
    final admission = _Admission(transport);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceSetupPage(
          transport: transport,
          admission: admission,
          checkpoints: InMemoryDeviceSetupCheckpointStore(),
          loadTarget: () async => deviceOnboardingTargetFixture(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('查找设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eidolon Body 1'));
    await tester.pumpAndSettle();

    expect(admission.sessionsOpenWhenAsked, [0]);
    expect(admission.requestedKey, 'p256:${'a' * 64}');
    expect(transport.sessions.single.prepared, isTrue);
    expect(transport.opened, 1);
    expect(transport.sessions.single.closed, isTrue);
  });

  // Leaving the device's access point hands the radio back to the platform,
  // and getting back onto the Host's network is the platform's and the
  // router's step. Measured on real hardware: a tablet's own home router
  // refused its re-association for over a minute after a setup visit, and
  // Android then disabled that network for consecutive failures. The Host
  // was never asked anything it could have refused.
  group('the Host is asked only once this phone is back on its network', () {
    PinnedHttpException notBack() => PinnedHttpException(
          kind: PinnedHttpFailureKind.unreachable,
          message: 'Failed to connect to /192.168.100.21:9002',
        );

    testWidgets('a Host that is not reachable yet is waited for, not reported',
        (tester) async {
      var now = DateTime.utc(2026, 10, 9, 22, 28);
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => attempt <= 3 ? notBack() : null;
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
        clock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pump();
      await tester.pump();
      // The device has answered and been left; what is waited for is the Host.
      expect(transport.sessions.single.prepared, isTrue);
      expect(transport.sessions.single.closed, isTrue);
      expect(admission.voucherAttempts, 1);
      expect(find.textContaining('正在等手机回到主机所在的网络'), findsOneWidget);
      expect(find.textContaining('如系统要求连接设备'), findsNothing);
      expect(find.textContaining('签发准入凭据：'), findsNothing);
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
      }
      expect(admission.voucherAttempts, 4);
      expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
      // The device was not visited again for the Host's delay.
      expect(transport.opened, 1);
      expect(transport.sessions.single.writes, 0);
    });

    testWidgets(
        'past the budget the prepared device is kept and the Host is asked again without a second visit',
        (tester) async {
      var now = DateTime.utc(2026, 10, 9, 22, 28);
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => notBack();
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
        hostReturnBudget: const Duration(seconds: 10),
        hostReturnInterval: const Duration(seconds: 2),
        clock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('手机还没回到主机所在的网络'), findsOneWidget);
      expect(find.textContaining('不用再碰设备'), findsOneWidget);
      expect(find.byKey(const Key('provisionable-device')), findsOneWidget);
      // Not an error: nothing has refused anything.
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(admission.voucherAttempts, 6);
      expect(transport.opened, 1);

      admission.voucherFailure = null;
      await tester.tap(find.byKey(const Key('retry-host-voucher')));
      await tester.pumpAndSettle();
      expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
      expect(admission.voucherAttempts, 7);
      expect(admission.requestedKey, 'p256:${'a' * 64}');
      expect(transport.opened, 1);
      expect(transport.sessions.single.writes, 0);
    });

    testWidgets('coming back to the app asks the Host again by itself',
        (tester) async {
      var now = DateTime.utc(2026, 10, 9, 22, 28);
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => notBack();
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
        hostReturnBudget: const Duration(seconds: 4),
        hostReturnInterval: const Duration(seconds: 2),
        clock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('手机还没回到主机所在的网络'), findsOneWidget);

      // The person went to the system Wi-Fi settings and came back.
      admission.voucherFailure = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
      expect(transport.opened, 1);
    });

    testWidgets('a refusal from the Host is reported at once, not waited out',
        (tester) async {
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => const LocalApiRequestException(
              'refused',
              statusCode: 403,
              reason: '这台管理设备不能为设备签发凭据',
            );
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      expect(find.text('主机没有为这台设备签发准入凭据：这台管理设备不能为设备签发凭据'), findsOneWidget);
      expect(admission.voucherAttempts, 1);
      expect(find.text('手机还没回到主机所在的网络'), findsNothing);
      expect(transport.sessions.single.closed, isTrue);
      expect(transport.sessions.single.writes, 0);
    });

    // A relocation that ends with nothing carries every address it tried and
    // why. Only silence on all of them is "not on the Host's network yet".
    HostCandidateFailure candidateFailure(
      Object error, {
      HostAddressEvidence evidence = HostAddressEvidence.announced,
    }) =>
        HostCandidateFailure(
          HostAddressCandidate(
            endpoint: const LocalApiEndpoint(
              instanceName: 'mac-dev',
              baseUrl: 'https://192.168.100.21:9002',
              ipAddress: '192.168.100.21',
              contractVersion: '1',
            ),
            evidence: evidence,
          ),
          error,
        );

    testWidgets('a relocation that found only silence is waited for',
        (tester) async {
      var now = DateTime.utc(2026, 10, 9, 22, 28);
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => switch (attempt) {
              1 => HostLocationException(const []),
              2 => HostLocationException([
                  candidateFailure(PinnedHttpException(
                      kind: PinnedHttpFailureKind.secureChannel,
                      message: 'another Host on this network')),
                  candidateFailure(TimeoutException('no answer')),
                  candidateFailure(notBack(),
                      evidence: HostAddressEvidence.remembered),
                ]),
              _ => null,
            };
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
        clock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pump();
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
      }
      expect(admission.voucherAttempts, 3);
      expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
      expect(transport.opened, 1);
    });

    testWidgets(
        'a published target address with another identity stops the wait',
        (tester) async {
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => HostLocationException([
              candidateFailure(
                  PinnedHttpException(
                    kind: PinnedHttpFailureKind.secureChannel,
                    message: 'pin mismatch',
                  ),
                  evidence: HostAddressEvidence.published),
            ]);
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不是这台手机配对过的那一台'), findsOneWidget);
      expect(find.textContaining('回到主机所在的网络'), findsNothing);
      expect(admission.voucherAttempts, 1);
    });

    // Re-authentication starts because the Host answered 401, and then has
    // to reach that Host again. The network going away between those two
    // requests arrives here wrapped as an authorization failure — with the
    // transport's own grading kept as its cause, which is what decides.
    testWidgets(
        'a re-authentication that lost the network is waited for; one the Host refused is not',
        (tester) async {
      var now = DateTime.utc(2026, 10, 9, 22, 28);
      final transport = _Transport();
      final admission = _Admission(transport)
        ..voucherFailure = (attempt) => attempt == 1
            ? HostControllerAuthorizationException(
                '管理会话已失效，且当前网络无法完成重新认证。请重新连接主机。',
                cause: notBack(),
              )
            : null;
      await tester.pumpWidget(MaterialApp(
          home: DeviceSetupPage(
        transport: transport,
        admission: admission,
        checkpoints: InMemoryDeviceSetupCheckpointStore(),
        loadTarget: () async => deviceOnboardingTargetFixture(),
        clock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('正在等手机回到主机所在的网络'), findsOneWidget);
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('选择家庭 Wi-Fi'), findsOneWidget);
      expect(admission.voucherAttempts, 2);
      expect(transport.opened, 1);
    });

    for (final refusal in [
      const HostControllerAuthorizationException(
        '主机已重置或不再授权这台管理设备。',
        reclaimRequired: true,
        cause: LocalApiRequestException('refused', statusCode: 403),
      ),
      HostControllerAuthorizationException(
        '管理会话已失效，且当前网络无法完成重新认证。请重新连接主机。',
        cause: PinnedHttpException(
          kind: PinnedHttpFailureKind.secureChannel,
          message: 'pin mismatch',
        ),
      ),
      const HostControllerAuthorizationException('请先安全连接主机'),
    ]) {
      testWidgets('an authorization refusal is reported at once: $refusal',
          (tester) async {
        final transport = _Transport();
        final admission = _Admission(transport)
          ..voucherFailure = (attempt) => refusal;
        await tester.pumpWidget(MaterialApp(
            home: DeviceSetupPage(
          transport: transport,
          admission: admission,
          checkpoints: InMemoryDeviceSetupCheckpointStore(),
          loadTarget: () async => deviceOnboardingTargetFixture(),
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查找设备'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Eidolon Body 1'));
        await tester.pumpAndSettle();
        expect(find.textContaining('签发准入凭据：'), findsOneWidget);
        expect(find.textContaining('回到主机所在的网络'), findsNothing);
        expect(admission.voucherAttempts, 1);
      });
    }
  });

  group('the code on the device screen', () {
    const scanned = '{"name":"eidolon-52f354","pop":"40718256","security":2,'
        '"transport":"softap","username":"eidolon-setup","ver":"v1"}';

    Widget page(_Transport transport,
            {String? scan, DeviceSetupCheckpointStore? checkpoints}) =>
        MaterialApp(
            home: DeviceSetupPage(
          transport: transport,
          admission: _Admission(transport),
          checkpoints: checkpoints ?? InMemoryDeviceSetupCheckpointStore(),
          loadTarget: () async => deviceOnboardingTargetFixture(),
          scanSetupCode: (_) async => scan,
        ));

    void allowDirectoryVerification(WidgetTester tester) {
      const channel = MethodChannel('live.eidolon.mobile/platform');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'verifyOwnerDomainDescriptor' ? true : null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
    }

    testWidgets('a scanned code names the device and goes to both visits',
        (tester) async {
      allowDirectoryVerification(tester);
      final transport = _Transport();
      await tester.pumpWidget(page(transport, scan: scanned));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scan-setup-code')));
      await tester.pumpAndSettle();
      // Nothing to choose: the QR code said which device.
      expect(transport.openedCandidates.single.transportId, 'eidolon-52f354');
      await tester.tap(find.byKey(const Key('network-owner-wifi')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('device-wifi-password')), 'pw');
      await tester.tap(find.byKey(const Key('confirm-device-setup')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(transport.openedCandidates, hasLength(2));
      expect(transport.openedCandidates.map((c) => c.setupCode),
          everyElement('40718256'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('a QR code that is not a setup code opens nothing',
        (tester) async {
      final transport = _Transport();
      await tester.pumpWidget(page(transport, scan: 'WIFI:S:home;P:x;;'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scan-setup-code')));
      await tester.pumpAndSettle();
      expect(find.textContaining('这不是 Eidolon 设备的设置码'), findsOneWidget);
      expect(transport.opened, 0);
    });

    testWidgets('a scanned device that is not nearby is named, not guessed',
        (tester) async {
      final transport = _Transport();
      await tester.pumpWidget(page(transport,
          scan: scanned.replaceFirst('eidolon-52f354', 'eidolon-ffffff')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scan-setup-code')));
      await tester.pumpAndSettle();
      expect(find.textContaining('eidolon-ffffff'), findsOneWidget);
      expect(transport.opened, 0);
    });

    testWidgets('a typed code goes with the device the person picks',
        (tester) async {
      final transport = _Transport();
      await tester.pumpWidget(page(transport));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('enter-setup-code')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('setup-code-field')), '4071825');
      await tester.tap(find.byKey(const Key('setup-code-continue')));
      await tester.pumpAndSettle();
      expect(find.text('请输入设备屏幕上的 8 位数字。'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('setup-code-field')), '40718256');
      await tester.tap(find.byKey(const Key('setup-code-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      expect(transport.openedCandidates.single.setupCode, '40718256');
    });

    testWidgets('the development entry opens without a code', (tester) async {
      final transport = _Transport();
      await tester.pumpWidget(page(transport));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      expect(transport.openedCandidates.single.setupCode, isNull);
    });

    // Bench, 2026-11-05: the refusal said "scan again" on the device list,
    // which had no way to scan, and its one button searched again with the
    // refused code. The only way out was Back, which left setup altogether.
    const refused = DeviceProvisioningTransportException('setup_code_rejected',
        '设置码不对，或者设备已经换了新码。请重新扫描设备屏幕上的二维码。');

    testWidgets('a refused code goes back to where a new one is read',
        (tester) async {
      final transport = _Transport()..openFailures[1] = refused;
      await tester.pumpWidget(page(transport));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('enter-setup-code')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('setup-code-field')), '12345678');
      await tester.tap(find.byKey(const Key('setup-code-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();

      expect(find.text(refused.message), findsOneWidget);
      expect(find.byKey(const Key('scan-setup-code')), findsOneWidget);
      expect(find.textContaining('Eidolon Body 1'), findsNothing);
      // The refused digits are not offered again.
      expect(find.byKey(const Key('setup-code-field')), findsNothing);

      await tester.tap(find.byKey(const Key('enter-setup-code')));
      await tester.pump();
      expect(find.text('12345678'), findsNothing);
      await tester.enterText(
          find.byKey(const Key('setup-code-field')), '40718256');
      await tester.tap(find.byKey(const Key('setup-code-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();
      expect(transport.openedCandidates.map((c) => c.setupCode),
          ['12345678', '40718256']);
      expect(find.byKey(const Key('network-owner-wifi')), findsOneWidget);
    });

    testWidgets('a device that wants a code it was not given sends the '
        'person to its screen', (tester) async {
      const required = DeviceProvisioningTransportException(
          'setup_code_required', '这台设备的屏幕上有设置码。请扫描屏幕上的二维码，或输入屏幕上的 8 位数字。');
      final transport = _Transport()..openFailures[1] = required;
      await tester.pumpWidget(page(transport));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Eidolon Body 1'));
      await tester.pumpAndSettle();

      expect(find.text(required.message), findsOneWidget);
      expect(find.byKey(const Key('scan-setup-code')), findsOneWidget);
      expect(find.textContaining('Eidolon Body 1'), findsNothing);
    });

    testWidgets('a code refused on the second visit drops the attempt',
        (tester) async {
      // The device opened a new window between the visits, so it shows a
      // new code; nothing was written to it, and the attempt cannot go on.
      allowDirectoryVerification(tester);
      final checkpoints = InMemoryDeviceSetupCheckpointStore();
      final transport = _Transport()..openFailures[2] = refused;
      await tester.pumpWidget(
          page(transport, scan: scanned, checkpoints: checkpoints));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scan-setup-code')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network-owner-wifi')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('device-wifi-password')), 'pw');
      await tester.tap(find.byKey(const Key('confirm-device-setup')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(transport.opened, 2);
      expect(transport.sessions.every((s) => s.writes == 0), isTrue);
      expect(find.text(refused.message), findsOneWidget);
      expect(find.byKey(const Key('scan-setup-code')), findsOneWidget);
      expect(await checkpoints.list(), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  });
}

class _Admission implements DeviceAdmissionPort {
  List<Map<String, dynamic>> claims = [];
  Object? claimsFailure;
  @override
  Future<ClaimPageV1> listClaims({AdmissionListCursorV1? after}) async =>
      claimsFailure != null
          ? throw claimsFailure!
          : currentClaimPage(claims, ownerDomainId: ownerDomainIdFixture);

  _Admission(this._transport);

  final _Transport _transport;
  final List<int> sessionsOpenWhenAsked = [];
  String? requestedKey;
  int decisions = 0;
  int voucherAttempts = 0;

  /// What the Host answers, by attempt number: a failure to throw, or null to
  /// sign. Stands in for a phone that is not yet back on the Host's network.
  Object? Function(int attempt)? voucherFailure;
  bool publishEnrollment = true;
  EnrollmentRecoveryProjectionV1 current = canonicalProjection(
    state: 'pending_review',
    ownerDomainId: ownerDomainIdFixture,
    deviceId: 'device-instance-${'a' * 64}',
  );

  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) async {
    sessionsOpenWhenAsked.add(_transport.openSessions);
    requestedKey = operationalSpkiSha256;
    voucherAttempts += 1;
    final failure = voucherFailure?.call(voucherAttempts);
    if (failure != null) throw failure;
    return CommissioningVoucher(
      voucher: 'header.payload.signature',
      jti: 'jti-01',
      deviceBaseId: 'device-base-${'a' * 64}',
      expiresAt: DateTime.utc(2027),
    );
  }

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async =>
      canonicalRecoveryPage(publishEnrollment ? [current] : [],
          ownerDomainId: ownerDomainIdFixture);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async =>
      current;

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async {
    decisions += 1;
    return current = canonicalProjection(
      state: 'approved_awaiting_handoff',
      ownerDomainId: ownerDomainIdFixture,
      deviceId: 'device-instance-${'a' * 64}',
      withDecision: true,
    );
  }
}

class _Transport implements DeviceProvisioningTransport, PhoneWifiSource {
  @override
  Future<String?> currentWifiSsid() async => "owner-wifi";
  Object? discoveryFailure;
  Object? configureFailure;
  Object? preparationFailure;
  Object? scanFailure;
  List<DeviceWifiNetwork>? scanNetworksResult;
  bool requiresVoucher = true;
  String? preparedDeviceId;
  final List<_Session> sessions = [];
  final List<DeviceProvisioningCandidate> openedCandidates = [];
  int opened = 0;
  Future<void>? configurationGate;

  /// What the nth visit (1-based) fails with before any session exists, the
  /// way a refused handshake does.
  final Map<int, Object> openFailures = {};

  int get openSessions => sessions.where((session) => !session.closed).length;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<DeviceProvisioningCandidate>> discover() async {
    if (discoveryFailure != null) throw discoveryFailure!;
    return const [
      DeviceProvisioningCandidate(
        transportId: 'eidolon-52f354',
        displayName: 'Eidolon Body 1',
        transportKind: 'softap',
        trust: SetupDescriptorTrustV1.manufacturerBound,
      ),
    ];
  }

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async {
    opened += 1;
    openedCandidates.add(candidate);
    if (openFailures[opened] case final failure?) throw failure;
    final session = _Session()
      ..configureFailure = configureFailure
      ..configurationGate = configurationGate
      ..preparationFailure = preparationFailure
      ..scanFailure = scanFailure
      ..scanNetworksResult = scanNetworksResult
      ..requiresVoucher = requiresVoucher
      ..preparedDeviceId = preparedDeviceId
      ..usePreparedDescriptor = sessions.isNotEmpty;
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {}
}

class _Session implements DeviceProvisioningSession {
  Object? configureFailure;
  Object? preparationFailure;
  Object? scanFailure;
  List<DeviceWifiNetwork>? scanNetworksResult;
  bool requiresVoucher = true;
  String? preparedDeviceId;
  String? sentVoucher;
  Future<void>? configurationGate;
  int writes = 0;
  bool prepared = false;
  bool usePreparedDescriptor = false;
  bool sentReplacement = false;
  bool replacementRequested = false;
  @override
  Future<DeviceProvisioningDescriptor> prepareOwner(
      DeviceOnboardingTarget target) async {
    if (preparationFailure != null) throw preparationFailure!;
    prepared = true;
    replacementRequested = target.replaceRevokedIdentity;
    return DeviceProvisioningDescriptor(
      setup: SetupDescriptorV1.fromJson({
        ...descriptor.setup.toJson(),
        'device_id': preparedDeviceId ?? 'device-instance-${'a' * 64}',
        'identity_fingerprint':
            'p256:${(preparedDeviceId ?? 'device-instance-${'a' * 64}').substring(16)}',
      }),
      expiresAt: descriptor.expiresAt,
      requiresVoucher: requiresVoucher,
    );
  }

  bool closed = false;

  @override
  DeviceProvisioningDescriptor get descriptor => DeviceProvisioningDescriptor(
        setup: SetupDescriptorV1.fromJson({
          'contract_version': '1',
          'device_id': usePreparedDescriptor && preparedDeviceId != null
              ? preparedDeviceId
              : 'device-instance-${'a' * 64}',
          'device_kind': 'esp32-display',
          'display_name': 'Eidolon Body 1',
          'identity_fingerprint': 'p256:${'5' * 64}',
          'session_id': 'setup_session_01',
          'expires_in_seconds': 600,
          'trust': 'manufacturer-bound',
        }),
        expiresAt: DateTime.utc(2036),
      );

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async {
    if (scanFailure != null) throw scanFailure!;
    if (scanNetworksResult case final result?) return result;
    return const [
      DeviceWifiNetwork(
        ssid: 'owner-wifi',
        signalStrength: -40,
        security: 'wpa2',
      ),
    ];
  }

  @override
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  }) async {
    sentVoucher = onboardingTarget.commissioningVoucher;
    sentReplacement = onboardingTarget.replaceRevokedIdentity;
    writes += 1;
    if (configureFailure != null) throw configureFailure!;
    await configurationGate;
    return const CommissioningStatusEvidenceV1(
      sessionId: 'setup_session_01',
      setupGeneration: 1,
      stateRevision: 5,
      state: CommissioningStatusStateV1.committed,
      conditions: CommissioningConditionsV1(
          wifiConnected: true,
          ownerRouteValidated: true,
          trustCommitted: true,
          networkCommitted: true),
      failureCode: null,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
