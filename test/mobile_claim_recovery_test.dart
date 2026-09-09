import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/channel_refusal.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_flow.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_control_client.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_device_runtime.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_projection.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

class _Admission implements DeviceAdmissionPort {
  List<EnrollmentRecoveryProjectionV1> records = [];
  int reads = 0;
  @override
  Future<EnrollmentProposalPageV1> listRecovery(
      {AdmissionListCursorV1? after}) async {
    reads++;
    return EnrollmentProposalPageV1.fromJson({
      ...canonicalContractValue('DF-PH2B0-PROPOSAL-PAGE-VALID'),
      'owner_domain_id': ownerDomainIdFixture,
      'items': records.map((p) => p.json).toList(),
    });
  }

  // Recovery must never issue a voucher, create an enrollment or approve one.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
      'Unexpected Admission operation: ${invocation.memberName}');
}

MobileBodyClaimRecord oldClaim({bool ackPending = false}) =>
    MobileBodyClaimRecord(
        deviceRef: {
          'device_instance_id': phoneDeviceInstanceId,
          'owner_domain_id': 'owner-previous',
          'owner_domain_generation': 3,
          'claim_generation': 1,
          'trust_epoch': 1,
        },
        grantId: 'grant_previous',
        ownerDomainId: 'owner-previous',
        deviceInstanceId: phoneDeviceInstanceId,
        acknowledgedAt: DateTime.utc(2026, 9, 8),
        ackPending: ackPending);

EnrollmentRecoveryProjectionV1 completed(
    {String? deviceId, String? owner, bool acknowledged = true}) {
  final p = canonicalProjection(
      state: 'grant_acknowledged',
      ownerDomainId: owner ?? ownerDomainIdFixture,
      deviceId: deviceId ?? phoneDeviceInstanceId,
      claimOwnerDomainGeneration: 1,
      claimState: 'active',
      withDecision: true,
      withDelivery: true);
  return EnrollmentRecoveryProjectionV1.fromJson({
    ...p.json,
    'grant_delivery': {
      ...p.grantDelivery!.json,
      'state': acknowledged ? 'acknowledged' : 'delivered',
      'acknowledged_at': acknowledged ? '2026-09-07T13:02:18Z' : null,
    },
  });
}

void main() {
  late _Admission admission;
  late InMemoryMobileBodyClaimStore store;
  late List<Map<String, dynamic>> requests;
  late MobileConversationProvisioner provisioner;
  http.Response Function(Map<String, dynamic>)? answer;
  setUp(() {
    admission = _Admission()..records = [completed()];
    store = InMemoryMobileBodyClaimStore(oldClaim());
    requests = [];
    answer = null;
    provisioner = MobileConversationProvisioner(
        loadTarget: () async => deviceOnboardingTargetFixture(),
        admission: admission,
        claims: store,
        platform: FakePhonePlatform(),
        buildDeviceControl: (_) => DeviceControlClient(
            authority: Uri.parse('https://authority.test'),
            transport: MockClient((request) async {
              expect(request.headers.containsKey('authorization'), false);
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              requests.add(body);
              return answer?.call(body) ??
                  http.Response(
                      jsonEncode({
                        'operation': deviceControlConfigurationOperation,
                        'nonce': body['nonce'],
                        'device_ref': {
                          ...body['device_ref'] as Map,
                          'claim_generation': 4
                        },
                        'lifecycle_state': 'approved',
                        'manifest': null,
                        'channels': [],
                      }),
                      200);
            })));
  });

  test('ordinary open preserves foreign reference and never signs for it',
      () async {
    final before = (await store.load())!.toJson();
    final config = await provisioner.provision();
    expect(config.channelRefusal, ChannelRefusal.ownerMismatch);
    expect(requests, isEmpty);
    expect(admission.reads, 0);
    expect((await store.load())!.toJson(), before);
  });

  test(
      'explicit recovery uses existing target ref and Device proof, then persists authoritative generation',
      () async {
    await provisioner.recoverClaim();
    expect(requests.single['device_ref'],
        admission.records.single.claim!.json['device_ref']);
    expect(requests.single['public_key_spki'], phoneOperationalPublicKey);
    expect(requests.single['device_signature'], isNotEmpty);
    final recovered = (await store.load())!;
    expect(recovered.ownerDomainId, ownerDomainIdFixture);
    expect(recovered.deviceInstanceId, phoneDeviceInstanceId);
    expect(recovered.claimGeneration, 4);
    expect(recovered.grantId, 'grant_01');
    expect(recovered.ackPending, false);
    // Subsequent normal operation is Device-only again.
    admission.records.clear();
    await provisioner.provision();
    expect(admission.reads, 1);
    expect(requests.length, 2);
  });

  test('missing local reference uses the same recovery without re-enrollment',
      () async {
    await store.clear();
    await provisioner.recoverClaim();
    expect((await store.load())!.ownerDomainId, ownerDomainIdFixture);
  });

  for (final failure in [
    'absent',
    'foreign-device',
    'wrong-owner',
    'unacknowledged',
    'pending-ack',
    'proof-rejected',
    'revoked',
    'invalid-nonce',
    'concurrent-change'
  ]) {
    test('$failure cannot overwrite the previous reference', () async {
      if (failure == 'absent') admission.records.clear();
      if (failure == 'foreign-device') {
        admission.records = [
          completed(deviceId: namedDeviceInstanceId('stranger'))
        ];
      }
      if (failure == 'wrong-owner') {
        admission.records = [completed(owner: 'owner-stranger')];
      }
      if (failure == 'unacknowledged') {
        admission.records = [completed(acknowledged: false)];
      }
      if (failure == 'pending-ack') {
        await store.save(oldClaim(ackPending: true));
      }
      final before = (await store.load())!.toJson();
      if (failure == 'proof-rejected') {
        answer = (_) => http.Response('{"detail":"REJECTED"}', 403);
      }
      if (failure == 'revoked' || failure == 'invalid-nonce') {
        answer = (body) => http.Response(
            jsonEncode({
              'operation': deviceControlConfigurationOperation,
              'nonce': failure == 'invalid-nonce' ? 'wrong' : body['nonce'],
              'device_ref': body['device_ref'],
              'lifecycle_state': failure == 'revoked' ? 'revoked' : 'approved',
              'manifest': null,
              'channels': [],
            }),
            200);
      }
      if (failure == 'concurrent-change') {
        answer = (body) {
          store.clear();
          return http.Response(
              jsonEncode({
                'operation': deviceControlConfigurationOperation,
                'nonce': body['nonce'],
                'device_ref': body['device_ref'],
                'lifecycle_state': 'approved',
                'manifest': null,
                'channels': [],
              }),
              200);
        };
      }
      await expectLater(provisioner.recoverClaim(), throwsA(isA<Exception>()));
      if (failure == 'concurrent-change') {
        expect(await store.load(), isNull);
      } else {
        expect((await store.load())!.toJson(), before);
      }
    });
  }

  test(
      'runtime opens a recovery-capable page rather than rejecting a cached Owner mismatch',
      () async {
    final runtime = MobileDeviceRuntime(
        platform: FakePhonePlatform(),
        claims: store,
        directory: DeviceOwnerDirectory(
            preferences: InMemoryAppPreferences(),
            verifier: const AcceptingOwnerDomainDirectoryVerifier()));
    final flow = await runtime.open(
        hostId: 'host',
        hostName: '工作室',
        bootstrap: () async => deviceOnboardingTargetFixture(),
        management: ConversationManagement(
            controllerId: 'controller',
            admission: admission,
            roster: ({cursor}) => throw StateError('not called'),
            device: (_) => throw StateError('not called'),
            assign: (
                    {required deviceId,
                    required requestId,
                    required companionId,
                    required expectedRevision}) =>
                throw StateError('not called')));
    expect(flow.ownerDomainId, ownerDomainIdFixture);
    expect((await store.load())!.ownerDomainId, 'owner-previous');
    flow.dispose();
  });
}
