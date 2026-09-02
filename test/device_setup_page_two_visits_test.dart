import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_domain_fixtures.dart';

/// Setting up a device is two visits to it, and the Host is asked between them.
///
/// Not a preference about ordering. A phone joins a device's access point with
/// the same radio it reaches the Host on, and while it is there the platform
/// reports that access point as the only network the phone has — measured on
/// real hardware, where a request meant for the Host sat for 26 seconds and
/// then failed. So the session must be closed before the Host is asked, and
/// re-opened afterwards to hand over what the Host said.
void main() {
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
    expect(transport.opened, 1);
    expect(transport.sessions.single.closed, isTrue);
  });
}

class _Admission implements DeviceAdmissionPort {
  _Admission(this._transport);

  final _Transport _transport;
  final List<int> sessionsOpenWhenAsked = [];

  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) async {
    sessionsOpenWhenAsked.add(_transport.openSessions);
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
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) async =>
      throw UnimplementedError();
}

class _Transport implements DeviceProvisioningTransport {
  final List<_Session> sessions = [];
  int opened = 0;

  int get openSessions => sessions.where((session) => !session.closed).length;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<DeviceProvisioningCandidate>> discover() async => const [
        DeviceProvisioningCandidate(
          transportId: 'eidolon-52f354',
          displayName: 'Eidolon Body 1',
          transportKind: 'softap',
          trust: SetupDescriptorTrustV1.manufacturerBound,
        ),
      ];

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async {
    opened += 1;
    final session = _Session();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {}
}

class _Session implements DeviceProvisioningSession {
  bool closed = false;

  @override
  DeviceProvisioningDescriptor get descriptor => DeviceProvisioningDescriptor(
        setup: SetupDescriptorV1.fromJson({
          'contract_version': '1',
          'device_id': 'device-instance-${'7' * 64}',
          'device_kind': 'esp32-display',
          'display_name': 'Eidolon Body 1',
          'identity_fingerprint': 'p256:${'5' * 64}',
          'session_id': 'setup_session_01',
          'expires_in_seconds': 600,
          'trust': 'manufacturer-bound',
        }),
        expiresAt: DateTime.utc(2026, 9, 2, 12),
      );

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async => const [
        DeviceWifiNetwork(
          ssid: 'owner-wifi',
          signalStrength: -40,
          security: 'wpa2',
        ),
      ];

  @override
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> close() async {
    closed = true;
  }
}
