import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/device_control_client.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/protocol/livekit_session_binding.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';
import 'package:eidolon_client_mobile/src/features/conversation/channel_refusal.dart';

/// What a claimed phone is told, and what it does with each answer.
///
/// Three outcomes on one edge, and they are three different sentences: the
/// Claim is gone, there is a channel, or there is not one yet. The last two are
/// easy to confuse and only one of them is a wait — and the first is news that
/// arrives nowhere else, because revocation happens between the Owner and the
/// Authority while the phone is not looking.
/// This phone's own reference in the fixture Owner Domain.
///
/// One value, used by the projection, the stored Claim and the Device Control
/// answer alike: the provisioner cross-checks all three, and three fixtures
/// that drifted would fail for a reason unrelated to channels.
final Map<String, Object?> claimedDeviceRef = <String, Object?>{
  'device_instance_id': phoneDeviceInstanceId,
  'owner_domain_id': ownerDomainIdFixture,
  'owner_domain_generation': 1,
  'claim_generation': 2,
  'trust_epoch': 1,
};

class _ClaimedAdmission implements DeviceAdmissionPort {
  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) async {
    final projection = canonicalContractValue(
      'DF-PH2B0-RECOVERY-PROJECTION-VALID',
    );
    // The projection has to be about this phone, in this Owner Domain: the
    // provisioner finds its own record by instance id and then validates it
    // against the target it just read.
    final proposal = Map<String, dynamic>.from(projection['proposal']! as Map)
      ..['device_instance_candidate_id'] = phoneDeviceInstanceId
      ..['requested_owner_domain_id'] = ownerDomainIdFixture;
    // `claimActive` is read off the Claim record, not the proposal's state —
    // the proposal's own lifecycle ends at `grant_acknowledged`.
    final claimRecord = Map<String, dynamic>.from(
      canonicalContractValue('DF-ADMISSION-CLAIM-RECORD-VALID'),
    )
      ..['device_ref'] = claimedDeviceRef
      ..['state'] = 'active';
    // The page shape comes from the contract's own example rather than being
    // typed here: it is strict about its member set, and a page this test
    // invented would fail for a reason that has nothing to do with channels.
    final page = canonicalContractValue('DF-PH2B0-PROPOSAL-PAGE-VALID');
    return EnrollmentProposalPageV1.fromJson(<String, dynamic>{
      ...page,
      'owner_domain_id': ownerDomainDescriptorJsonFixture['owner_domain_id'],
      'items': <Object?>[
        <String, dynamic>{
          ...projection,
          'proposal': proposal,
          'claim': claimRecord,
        },
      ],
    });
  }

  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) =>
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) =>
      throw UnimplementedError();

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) =>
      throw UnimplementedError();
}

void main() {
  Map<String, Object?> deviceRef() =>
      Map<String, Object?>.from(claimedDeviceRef);

  MobileBodyClaimRecord claim() => MobileBodyClaimRecord(
        deviceRef: deviceRef(),
        grantId: 'grant_01',
        ownerDomainId: deviceRef()['owner_domain_id']! as String,
        deviceInstanceId: phoneDeviceInstanceId,
        acknowledgedAt: DateTime.utc(2026, 9, 6, 12),
      );

  String sealSession() => base64.encode(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'schema_version': 2,
            'session': <String, Object?>{
              'server_url': 'wss://livekit.owner-domain.invalid',
              'token': 'a.jwt.token',
              'identity': phoneDeviceInstanceId,
              'room_name': 'eidolon-0123456789abcdef01234567',
            },
            'audio': <String, Object?>{'sample_rate': 16000, 'channels': 1},
          }),
        ),
      );

  /// One answer from Device Control, with [ref] as the ref it says it holds.
  ///
  /// A parameter rather than an echo of the request, because the Authority
  /// finds the Claim by identity and answers with its own ref — which is
  /// exactly how a phone that fell behind learns that it did.
  http.Response configuration({
    required String nonce,
    String lifecycle = 'approved',
    bool withChannel = false,
    Map<String, Object?>? ref,
  }) =>
      http.Response(
        jsonEncode(<String, Object?>{
          'operation': 'device-control.configuration',
          'nonce': nonce,
          'device_ref': ref ?? deviceRef(),
          'lifecycle_state': lifecycle,
          'manifest': null,
          'channels': withChannel
              ? <Object?>[
                  <String, Object?>{
                    'channel_id': 'channel_01',
                    'purpose': 'conversation',
                    'kinds': <String>['audio'],
                    'binding_format': liveKitSessionBindingFormat,
                    'issued_at_ms': 1,
                    'expires_at_ms': 2,
                    'opaque_binding': sealSession(),
                  },
                ]
              : const <Object?>[],
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );

  Future<HubConfig> provision({
    required MockClient deviceControl,
    MobileBodyClaimStore? claims,
  }) {
    return MobileConversationProvisioner(
      loadTarget: () async => deviceOnboardingTargetFixture(),
      admission: _ClaimedAdmission(),
      claims: claims ?? InMemoryMobileBodyClaimStore(claim()),
      buildDeviceControl: (target) => DeviceControlClient(
        authority: Uri.parse('https://hub.owner-domain.invalid'),
        transport: deviceControl,
      ),
      platform: FakePhonePlatform(),
    ).provision();
  }

  /// What the Host said about the channel, against what the screen told a
  /// person about it.
  ///
  /// Device Control refuses with a tagged reason. This provisioner used to
  /// catch every one of them with a bare `on Exception` that did not bind the
  /// object, report them all as `claimActiveWithoutChannel`, and then show a
  /// sentence that said 「这两种情况主机的回答是一样的，这台手机分不出来」 —
  /// while the tag that distinguished them was in the exception it had just
  /// discarded. The three refusals differ in who has to act next, which is the
  /// only thing the sentence needed to get right.
  group('a refusal says which refusal it is', () {
    MockClient refusing(String detail, {int status = 409}) =>
        MockClient((request) async => http.Response(
              jsonEncode(<String, Object?>{'detail': detail}),
              status,
              headers: const {'content-type': 'application/json'},
            ));

    test('an inactive claim does not end by waiting',
        () async {
      final config = await provision(deviceControl: refusing('CLAIM_NOT_ACTIVE'));

      expect(config.channelRefusal, ChannelRefusal.claimNotActive);
      expect(config.channelRefusal!.advances, isFalse);
    });

    test('a stale record does not end by waiting either', () async {
      final config = await provision(deviceControl: refusing('STALE_GENERATION'));

      expect(config.channelRefusal, ChannelRefusal.deviceFactsStale);
      expect(config.channelRefusal!.advances, isFalse);
    });

    test('a manifest conflict lands on the same remedy', () async {
      final config =
          await provision(deviceControl: refusing('MANIFEST_REVISION_CONFLICT'));

      expect(config.channelRefusal, ChannelRefusal.deviceFactsStale);
    });

    test('a tag this build does not know is not guessed at', () async {
      // Mapping an unrecognised reason onto a remedy would have the screen
      // advise an act that cannot help. Null means the sentence says only that
      // the Host refused.
      final config =
          await provision(deviceControl: refusing('SOMETHING_ELSE_ENTIRELY'));

      expect(config.channelRefusal, isNull);
    });

    test('a request that never completed is not the Host saying no', () async {
      final config = await provision(
        deviceControl: MockClient((_) async => throw const _NoAnswer()),
      );

      expect(config.channelRefusal, ChannelRefusal.hostUnanswered);
    });

    test('the Host answering with no channel is still its own state', () async {
      // The one case the old sentence was true for: nothing was refused, and
      // waiting is honest advice.
      final config = await provision(
        deviceControl: MockClient((request) async {
          final nonce = (jsonDecode(request.body) as Map<String, dynamic>)['nonce']!
              as String;
          return configuration(nonce: nonce, withChannel: false);
        }),
      );

      expect(config.channelRefusal, isNull);
      expect(config.bodyStanding, MobileBodyStanding.claimActiveWithoutChannel);
    });
  });

  /// The client half of the stale-DeviceRef recovery.
  ///
  /// The Host stopped refusing a ref that fell behind: it finds the Claim by
  /// identity and answers with the ref it holds. Without this group the phone
  /// recovered its channel and its conversation on that answer and then threw
  /// the correction away — so its stored ref stayed stale forever, and the two
  /// surfaces that are still matched on the exact generation (a Manifest
  /// assertion, and the erase ACK that is a device's durable evidence it
  /// dropped what it held) would keep being addressed with a ref no Claim
  /// carries.
  group('the ref that comes back is pinned', () {
    /// What the Authority holds: the same device, two generations on.
    final held = <String, Object?>{
      ...claimedDeviceRef,
      'owner_domain_generation': 2,
      'claim_generation': 3,
      'trust_epoch': 2,
    };

    MockClient answering(
      Map<String, Object?> ref, {
      bool withChannel = true,
      List<Map<String, Object?>>? asked,
    }) =>
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          asked?.add(Map<String, Object?>.from(body['device_ref']! as Map));
          return configuration(
            nonce: body['nonce']! as String,
            ref: ref,
            withChannel: withChannel,
          );
        });

    test('the record ends up holding the ref the Host answered with', () async {
      final claims = InMemoryMobileBodyClaimStore(claim());

      final config = await provision(claims: claims, deviceControl: answering(held));

      final stored = await claims.load();
      expect(stored!.deviceRef, held);
      expect(stored.claimGeneration, 3);
      expect(stored.trustEpoch, 2);
      // A correction to one fact, not a re-enrollment: the Grant this Claim
      // was opened with, the key it belongs to and the moment it was
      // acknowledged all happened, and none of them moved.
      expect(stored.grantId, 'grant_01');
      expect(stored.ownerDomainId, ownerDomainIdFixture);
      expect(stored.deviceInstanceId, phoneDeviceInstanceId);
      expect(stored.acknowledgedAt, DateTime.utc(2026, 9, 6, 12));
      // And the answer was still an answer: the recovery is that this phone
      // talks *and* stops being behind.
      expect(config.status, HubConfigStatus.active);
    });

    test('the next ask is addressed to it', () async {
      // The assertion the store one cannot make. A write nothing reads back is
      // indistinguishable from no write at all, and the reason this re-pin
      // exists is that the *next* request must not carry the stale ref.
      final claims = InMemoryMobileBodyClaimStore(claim());
      final asked = <Map<String, Object?>>[];
      final transport = answering(held, asked: asked);

      await provision(claims: claims, deviceControl: transport);
      await provision(claims: claims, deviceControl: transport);

      expect(
        asked.map((ref) => ref['claim_generation']).toList(),
        <int>[2, 3],
        reason: 'the second ask still carried the stale generation',
      );
      expect(asked.last, held);
    });

    test('an answer that did not move is not written at all', () async {
      // The ordinary case, which is every pull on a phone that is current —
      // and on the five second activation poll, every five seconds.
      //
      // The one assertion here that counts a write rather than reading what
      // the store holds, because for this property there is nothing else to
      // read: an unconditional re-pin leaves the record byte-identical, so a
      // content assertion passes whether the guard exists or not. What is
      // being pinned is that a poll on a current phone does no storage write,
      // and the count is that fact rather than a stand-in for it.
      final claims = _CountingClaimStore(claim());

      await provision(claims: claims, deviceControl: answering(deviceRef()));

      expect((await claims.load())!.deviceRef, claimedDeviceRef);
      expect(claims.writes, 0, reason: 'rewrote a record that had not moved');
    });

    test('a correction is one write, not one per member', () async {
      final claims = _CountingClaimStore(claim());

      await provision(claims: claims, deviceControl: answering(held));

      expect((await claims.load())!.deviceRef, held);
      expect(claims.writes, 1);
    });

    test('an answer about another device does not touch the record', () async {
      // Not a correction: a different `device_instance_id` is a different
      // device, and this phone cannot sign for it. Writing it would replace a
      // usable Claim with one that is refused at every later ask — the failure
      // this whole recovery exists to end, arriving from the other side.
      final claims = InMemoryMobileBodyClaimStore(claim());

      final config = await provision(
        claims: claims,
        deviceControl: answering(<String, Object?>{
          ...held,
          'device_instance_id': 'device-instance-${'b' * 64}',
        }),
      );

      expect((await claims.load())!.deviceRef, claimedDeviceRef);
      expect(config.status, HubConfigStatus.waitingBinding);
      expect(config.bodyStanding, MobileBodyStanding.claimActiveWithoutChannel);
    });

    test('a revoked answer drops the record rather than re-pinning it',
        () async {
      // Both things are true at once — the ref moved and the Claim is gone —
      // and only one of them matters. A re-pin here would leave a record whose
      // whole purpose is to name a Claim that no longer exists.
      final claims = InMemoryMobileBodyClaimStore(claim());

      final config = await provision(
        claims: claims,
        deviceControl: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return configuration(
            nonce: body['nonce']! as String,
            lifecycle: 'revoked',
            ref: held,
          );
        }),
      );

      expect(await claims.load(), isNull);
      expect(config.status, HubConfigStatus.revoked);
    });
  });

  test('a delivered channel makes this phone ready to talk', () async {
    final config = await provision(
      deviceControl: MockClient((request) async {
        final nonce = (jsonDecode(request.body) as Map<String, dynamic>)['nonce']!
            as String;
        return configuration(nonce: nonce, withChannel: true);
      }),
    );

    expect(config.status, HubConfigStatus.active);
    expect(config.session.usable, isTrue);
    expect(config.session.serverUrl, 'wss://livekit.owner-domain.invalid');
  });

  test('no channel yet stays the sentence it already was', () async {
    // Still true, still the Host's to close. What must not happen is this
    // becoming a failure — the screen has a standing and a sentence for it.
    final config = await provision(
      deviceControl: MockClient((request) async {
        final nonce = (jsonDecode(request.body) as Map<String, dynamic>)['nonce']!
            as String;
        return configuration(nonce: nonce);
      }),
    );

    expect(config.status, HubConfigStatus.waitingBinding);
    expect(config.bodyStanding, MobileBodyStanding.claimActiveWithoutChannel);
  });

  test('a revocation is learned here, and the local record is dropped',
      () async {
    // The only place this news arrives. Keeping the record would let the next
    // launch present an identity the Authority has withdrawn.
    final claims = InMemoryMobileBodyClaimStore(claim());

    final config = await provision(
      claims: claims,
      deviceControl: MockClient((request) async {
        final nonce = (jsonDecode(request.body) as Map<String, dynamic>)['nonce']!
            as String;
        return configuration(nonce: nonce, lifecycle: 'revoked');
      }),
    );

    expect(config.status, HubConfigStatus.revoked);
    expect(config.bodyStanding, MobileBodyStanding.claimRevoked);
    expect(await claims.load(), isNull);
  });

  test('a Device Control fault does not become a failed conversation',
      () async {
    // The screen already has a true sentence for this standing. Replacing it
    // with a transport error would trade something a person can act on for
    // something they cannot.
    final config = await provision(
      deviceControl: MockClient((_) async => http.Response('nope', 503)),
    );

    expect(config.status, HubConfigStatus.waitingBinding);
    expect(config.bodyStanding, MobileBodyStanding.claimActiveWithoutChannel);
  });

  test('a Claim from another installation is not asked about', () async {
    // Uninstalling destroyed the key that record belongs to. Asking would
    // present a device_ref this phone cannot sign for, and the Authority would
    // answer with a rejected proof rather than anything useful.
    var asked = false;
    final config = await provision(
      claims: InMemoryMobileBodyClaimStore(
        MobileBodyClaimRecord(
          deviceRef: deviceRef(),
          grantId: 'grant_01',
          ownerDomainId: deviceRef()['owner_domain_id']! as String,
          deviceInstanceId: 'device-instance-${'f' * 64}',
          acknowledgedAt: DateTime.utc(2026, 9, 6, 12),
        ),
      ),
      deviceControl: MockClient((_) async {
        asked = true;
        return http.Response('{}', 200);
      }),
    );

    expect(asked, isFalse);
    expect(config.bodyStanding, MobileBodyStanding.claimActiveWithoutChannel);
  });
}

/// A request that does not complete, as distinct from a Host that refuses.
class _NoAnswer implements Exception {
  const _NoAnswer();
}

/// The in-memory store, plus how many times it was written.
///
/// Only for the one property that is a write and not a state: whether a pull
/// that corrected nothing touched storage at all.
class _CountingClaimStore implements MobileBodyClaimStore {
  _CountingClaimStore(MobileBodyClaimRecord record)
      : _inner = InMemoryMobileBodyClaimStore(record);

  final InMemoryMobileBodyClaimStore _inner;

  int writes = 0;

  @override
  Future<MobileBodyClaimRecord?> load() => _inner.load();

  @override
  Future<MobileBodyClaimRecord?> loadFor(String operationalPublicKey) =>
      _inner.loadFor(operationalPublicKey);

  @override
  Future<void> save(MobileBodyClaimRecord record) {
    writes += 1;
    return _inner.save(record);
  }

  @override
  Future<void> clear() => _inner.clear();
}
