import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/admission_authority_client.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment_session.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

/// What this phone may do about an Enrollment, and when it may not.
///
/// The decisions here rest on two facts read out of the Authority rather than
/// chosen: the collection challenge exists only in the answer to the proposal
/// (`hub/admission/application.py` stores its digest), and
/// `approved_awaiting_handoff` has no transition to `canceled`
/// (`hub/admission/domain.py`). Together they mean an approved Enrollment this
/// process can no longer finish also cannot be withdrawn — and a screen
/// offering to cancel it would be a button the Authority refuses.
class _KeyedPlatform extends FakePhonePlatform {
  _KeyedPlatform({this.holdsKey = true});

  bool holdsKey;

  @override
  Future<bool> holdsHandoffKey() async => holdsKey;

  @override
  Future<PlatformHandoffKey> issueHandoffKey() async {
    holdsKey = true;
    return PlatformHandoffKey(
      handle: 'handle-1',
      publicKey: 'p256-spki:AAAA',
      keyId: 'sha256:${'a' * 64}',
    );
  }

  @override
  Future<String> signDeviceCanonicalDocument(String document) async =>
      base64Url.encode(List<int>.filled(64, 7)).replaceAll('=', '');

  @override
  Future<void> discardHandoffKey() async {
    holdsKey = false;
  }
}

class _StubController implements DeviceAdmissionPort {
  @override
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) async =>
      CommissioningVoucher(
        voucher: 'header.claims.signature',
        jti: 'jti-0f3a91c4d25b47e8a6031f7c8b9d2e50',
        deviceBaseId: 'software-body-${'a' * 40}',
        expiresAt: DateTime.utc(2026, 9, 6, 1),
      );

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
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
  MobileBodyEnrollmentSession session(
    _KeyedPlatform platform, {
    MockClient? transport,
  }) {
    return MobileBodyEnrollmentSession(
      buildAdmission: (target) => MobileBodyAdmission(
        issueVoucher: _StubController().issueCommissioningVoucher,
        authority: AdmissionAuthorityClient(
          authority: Uri.parse('https://hub.owner-domain.invalid'),
          transport: transport ??
              MockClient((_) async => http.Response(
                    jsonEncode(
                      canonicalContractValue(
                          'DF-ADMISSION-CREATE-RESULT-VALID'),
                    ),
                    201,
                    headers: const {'content-type': 'application/json'},
                  )),
        ),
        claims: InMemoryMobileBodyClaimStore(),
        platform: platform,
      ),
      loadTarget: () async => deviceOnboardingTargetFixture(),
      platform: platform,
    );
  }

  test('with nothing in flight, the act is to propose', () async {
    final flow = session(_KeyedPlatform(holdsKey: false));

    for (final standing in const [
      MobileBodyStanding.notEnrolled,
      MobileBodyStanding.claimRevoked,
      MobileBodyStanding.admissionEnded,
    ]) {
      expect(await flow.actFor(standing), MobileBodyEnrollmentAct.propose);
    }
  });

  test('a proposal in hand waits on the person, not on the network', () async {
    final platform = _KeyedPlatform(holdsKey: false);
    final flow = session(platform);

    await flow.propose(
      title: 'Eidolon Mobile',
    );

    expect(
      await flow.actFor(MobileBodyStanding.pendingReview),
      MobileBodyEnrollmentAct.approve,
    );
  });

  test('an approved proposal this phone still holds is collected', () async {
    final platform = _KeyedPlatform(holdsKey: false);
    final flow = session(platform);
    await flow.propose(
      title: 'Eidolon Mobile',
    );

    expect(
      await flow.actFor(MobileBodyStanding.approvedAwaitingHandoff),
      MobileBodyEnrollmentAct.collect,
    );
  });

  test('a pending proposal this phone lost can be withdrawn', () async {
    // This is what a restart looks like: the Authority still shows the
    // proposal, and this process has neither the challenge nor the key. From
    // `pending_review` the Authority does allow a cancellation, so there is a
    // real way out.
    final flow = session(_KeyedPlatform(holdsKey: false));

    expect(
      await flow.actFor(MobileBodyStanding.pendingReview),
      MobileBodyEnrollmentAct.abandon,
    );
  });

  test('an approved proposal this phone lost can only expire', () async {
    // The case that would have shipped a button the Authority refuses:
    // `approved_awaiting_handoff` has no transition to `canceled`. Offering
    // 「取消重来」 here would be a control that fails every time it is pressed.
    final flow = session(_KeyedPlatform(holdsKey: false));

    expect(
      await flow.actFor(MobileBodyStanding.approvedAwaitingHandoff),
      MobileBodyEnrollmentAct.waitForExpiry,
    );
    expect(
      await flow.actFor(MobileBodyStanding.grantDelivered),
      MobileBodyEnrollmentAct.waitForExpiry,
    );
  });

  test('a Claim with no Channel is not this phone\'s to act on', () async {
    final flow = session(_KeyedPlatform());

    expect(
      await flow.actFor(MobileBodyStanding.claimActiveWithoutChannel),
      MobileBodyEnrollmentAct.none,
    );
  });

  test('a second proposal over a finishable one is refused', () async {
    // Proposing again would mint a new handoff key and strand the first
    // proposal — and if that one has been approved, it cannot be cancelled.
    final platform = _KeyedPlatform(holdsKey: false);
    final flow = session(platform);
    await flow.propose(
      title: 'Eidolon Mobile',
    );

    await expectLater(
      flow.propose(
        title: 'Eidolon Mobile',
      ),
      throwsA(isA<MobileBodyEnrollmentUnavailable>()),
    );
  });

  test('an ended proposal permits a new proposal', () async {
    // The other side of the same rule: once the key is gone the old proposal
    // can never be used, so it must not stand in the way of a new one.
    final platform = _KeyedPlatform(holdsKey: false);
    final flow = session(platform);
    await flow.propose(
      title: 'Eidolon Mobile',
    );
    platform.holdsKey = false;
    await flow.actFor(MobileBodyStanding.admissionEnded);

    final again = await flow.propose(
      title: 'Eidolon Mobile',
    );

    expect(again.enrollmentId, isNotEmpty);
  });

  test('completing without the key names what is gone, and does not ask',
      () async {
    // Not an AdmissionRefusal: nothing was asked of the Authority, and the
    // reason is local. Reporting it as a server refusal would send the reader
    // looking in the wrong place.
    var reached = false;
    final platform = _KeyedPlatform(holdsKey: false);
    final flow = session(
      platform,
      transport: MockClient((_) async {
        reached = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      flow.complete(),
      throwsA(
        isA<MobileBodyEnrollmentUnavailable>().having(
          (error) => error.message,
          'message',
          contains('只在这次运行里存在'),
        ),
      ),
    );
    expect(reached, isFalse);
  });

  test('command ids do not repeat', () async {
    // A repeated idempotency key makes the Authority replay instead of act,
    // which is what makes a lost reply safe and a reused key unsafe.
    final platform = _KeyedPlatform(holdsKey: false);
    final sent = <String>{};
    final flow = session(
      platform,
      transport: MockClient((request) async {
        sent.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['command_id']!
              as String,
        );
        return http.Response(
          jsonEncode(
              canonicalContractValue('DF-ADMISSION-CREATE-RESULT-VALID')),
          201,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    for (var index = 0; index < 4; index += 1) {
      platform.holdsKey = false;
      await flow.actFor(MobileBodyStanding.admissionEnded);
      await flow.propose(
        title: 'Eidolon Mobile',
      );
    }

    expect(sent, hasLength(4));
  });
}
