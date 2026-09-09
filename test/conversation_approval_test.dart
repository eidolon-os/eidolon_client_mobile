import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_flow.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_authority_client.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_projection.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment_session.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

class _Platform extends FakePhonePlatform {
  bool hasKey = false;
  @override
  Future<bool> holdsHandoffKey() async => hasKey;
  @override
  Future<PlatformHandoffKey> issueHandoffKey() async {
    hasKey = true;
    return PlatformHandoffKey(
        handle: 'handle',
        publicKey: 'p256-spki:AAAA',
        keyId: 'sha256:${'a' * 64}');
  }
}

class _Admission implements DeviceAdmissionPort {
  late MobileBodyEnrollmentSession enrollment;
  int decisions = 0;
  bool wrongDevice = false;
  String? selected;
  @override
  Future<CommissioningVoucher> issueCommissioningVoucher(
          {required String operationalSpkiSha256}) async =>
      CommissioningVoucher(
          voucher: 'header.claims.signature',
          jti: 'jti-0f3a91c4d25b47e8a6031f7c8b9d2e50',
          deviceBaseId: 'software-body-${'a' * 40}',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)));
  @override
  Future<EnrollmentRecoveryProjectionV1> recover(
      {required String enrollmentId}) async {
    final pending = enrollment.pending!;
    expect(enrollmentId, pending.enrollmentId);
    final value = canonicalProjection(
            ownerDomainId: ownerDomainIdFixture,
            deviceId: phoneDeviceInstanceId,
            revision: pending.proposalRevision)
        .toJson();
    final proposal = Map<String, dynamic>.from(value['proposal'] as Map);
    proposal['enrollment_id'] = pending.enrollmentId;
    proposal['handoff_key_id'] = pending.handoffKeyId;
    if (wrongDevice) {
      proposal['device_instance_candidate_id'] = 'device-instance-${'f' * 64}';
    }
    return EnrollmentRecoveryProjectionV1.fromJson(
        {...value, 'proposal': proposal});
  }

  @override
  Future<EnrollmentRecoveryProjectionV1> decide(
      {required String requestId,
      required EnrollmentRecoveryProjectionV1 projection,
      String? initialCompanionId}) async {
    decisions++;
    selected = initialCompanionId;
    expect(projection.proposal.json['device_instance_candidate_id'],
        phoneDeviceInstanceId);
    return projection;
  }

  @override
  Future<EnrollmentProposalPageV1> listRecovery(
          {AdmissionListCursorV1? after}) async =>
      throw StateError('must read exact pending enrollment');
}

class _Provisioner implements ConversationProvisioner {
  _Provisioner(this.enrollment);
  final MobileBodyEnrollmentSession enrollment;
  @override
  String get serviceName => 'Host';
  @override
  Uri get serviceUri => Uri.parse('https://owner.test/descriptor');
  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async => HubConfig(
      status: enrollment.pending == null
          ? HubConfigStatus.unregistered
          : HubConfigStatus.pendingApproval,
      session: const RoomConfig(
          serverUrl: '', token: '', identity: '', roomName: ''),
      deviceFingerprint: phoneFingerprint,
      bodyStanding: enrollment.pending == null
          ? MobileBodyStanding.notEnrolled
          : MobileBodyStanding.pendingReview);
}

class _Harness {
  final platform = _Platform();
  final admission = _Admission();
  late final enrollment = MobileBodyEnrollmentSession(
      loadTarget: () async => deviceOnboardingTargetFixture(),
      platform: platform,
      buildAdmission: (_) => MobileBodyAdmission(
          issueVoucher: admission.issueCommissioningVoucher,
          claims: InMemoryMobileBodyClaimStore(),
          platform: platform,
          authority: AdmissionAuthorityClient(
              authority: Uri.parse('https://owner.test'),
              transport: MockClient((_) async => http.Response(
                  jsonEncode(canonicalContractValue(
                      'DF-ADMISSION-CREATE-RESULT-VALID')),
                  201)))));
  ConversationFlow flow() {
    admission.enrollment = enrollment;
    return ConversationFlow(
        hostName: 'Host',
        ownerDomainId: ownerDomainIdFixture,
        loadTarget: () async => deviceOnboardingTargetFixture(),
        enrollment: enrollment,
        platform: platform,
        provisioner: _Provisioner(enrollment),
        management: ConversationManagement(
            controllerId: 'controller',
            admission: admission,
            roster: ({cursor}) async => CompanionRosterView.fromJson({
                  'contract_version': '1',
                  'default_companion_id': null,
                  'companions': [
                    {
                      'companion_id': 'c_a',
                      'display_name': 'Eidolon',
                      'kind': 'standard',
                      'lifecycle_state': 'active',
                      'revision': 1,
                      'created_at': '2026-09-01T00:00:00Z',
                      'updated_at': '2026-09-01T00:00:00Z'
                    }
                  ],
                  'next_cursor': null
                }),
            device: (_) async => null,
            assign: (
                    {required deviceId,
                    required requestId,
                    required companionId,
                    required expectedRevision}) async =>
                throw StateError(
                    'initial choice belongs to explicit decision')));
  }
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
      'propose and read-only refresh never approve; only explicit confirmation does',
      () async {
    final h = _Harness();
    final flow = h.flow();
    await flow.initialize();
    await flow.propose();
    await settle();
    expect(flow.reviewedProposal, isNotNull);
    expect(h.admission.decisions, 0);
    await flow.choose('c_a');
    await flow.client.checkActivation();
    await settle();
    expect(h.admission.decisions, 0);
    await flow.approveAndStart();
    expect(h.admission.decisions, 1);
    expect(h.admission.selected, 'c_a');
    flow.dispose();
  });
  test('returning to the page preserves the proposal and handoff key',
      () async {
    final h = _Harness();
    final first = h.flow();
    await first.initialize();
    await first.propose();
    await settle();
    final id = h.enrollment.pending!.enrollmentId;
    await first.close();
    first.dispose();
    final second = h.flow();
    await second.initialize();
    await settle();
    expect(second.enrollment.pending!.enrollmentId, id);
    expect(await second.enrollment.canFinish(), true);
    expect(second.client.enrollmentAct, MobileBodyEnrollmentAct.approve);
    expect(h.admission.decisions, 0);
    second.dispose();
  });
  test('a projection for another device cannot be approved from this page',
      () async {
    final h = _Harness();
    h.admission.wrongDevice = true;
    final flow = h.flow();
    await flow.initialize();
    await flow.propose();
    await settle();
    await flow.choose('c_a');
    expect(flow.reviewedProposal, isNull);
    await flow.approveAndStart();
    expect(h.admission.decisions, 0);
    expect(flow.error, isNotNull);
    flow.dispose();
  });
}
