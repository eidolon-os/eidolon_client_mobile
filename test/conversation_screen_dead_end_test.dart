import 'package:eidolon_client_mobile/src/models/conversation_mode.dart';
import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/admission_authority_client.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment_session.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';

import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

/// What the person holding the phone can actually do.
///
/// The report this fixes: 「打开对话」→「连接我的 Eidolon」 reaches 待批准 with
/// 「主机正在认领 Mobile」 and one control, 「立即检查状态」, forever. Two things
/// had to change on this screen — the sentence, and the button.
void main() {
  Future<void> open(
    WidgetTester tester,
    MobileBodyStanding standing,
    HubConfigStatus status, {
    bool withApprovalRoute = true,
    MobileBodyEnrollmentSession? enrollment,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: ClientPage(
          platform: FakePhonePlatform(),
          provisioner: _FakeProvisioner(
            HubConfig(
              status: status,
              session: const RoomConfig(
                serverUrl: '',
                token: '',
                identity: '',
                roomName: '',
              ),
              deviceFingerprint: phoneFingerprint,
              bodyStanding: standing,
            ),
          ),
          onApproveThisPhone: withApprovalRoute ? (_) async {} : null,
          enrollment: enrollment,
        ),
      ),
    );
    // The headline says the same words as the button in this phase, so aim at
    // the actions block rather than at the text.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('compact-actions')),
        matching: find.text('连接我的 Eidolon'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an unenrolled phone is offered the act, not a retry',
      (tester) async {
    // This used to assert that nothing was offered, which was right while no
    // version of this app could propose an Enrollment. It can now — so the
    // screen owes an act. What must never come back is the *retry*: 「立即检查
    // 状态」 in front of a proposal nobody has made is asking a person to wait
    // for something that starts only when they act.
    await open(
      tester,
      MobileBodyStanding.notEnrolled,
      HubConfigStatus.unregistered,
      enrollment: _lostSession(),
    );

    expect(find.text('登记这台手机'), findsWidgets);
    expect(find.text('立即检查状态'), findsNothing);
    expect(find.text('正在检查…'), findsNothing);
    expect(find.text('将本机接入对话'), findsWidgets);
    expect(find.textContaining('主机正在认领 Mobile'), findsNothing);
    expect(find.textContaining('自动向前推进'), findsNothing);
    // Proposing is the first of two acts by the same person, and the sentence
    // has to keep saying the second one is coming.
    expect(find.textContaining('再由你明确确认接入'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an Enrollment that ended can be proposed again', (tester) async {
    await open(
      tester,
      MobileBodyStanding.admissionEnded,
      HubConfigStatus.unregistered,
      enrollment: _lostSession(),
    );

    expect(find.text('登记这台手机'), findsWidgets);
    expect(find.text('立即检查状态'), findsNothing);
  });

  testWidgets('a revoked Claim can be proposed again', (tester) async {
    await open(
      tester,
      MobileBodyStanding.claimRevoked,
      HubConfigStatus.revoked,
      enrollment: _lostSession(),
    );

    expect(find.text('登记这台手机'), findsWidgets);
  });

  testWidgets('an approved Enrollment this phone cannot finish stops, and is '
      'offered nothing', (tester) async {
    // The Authority says this stage advances, and it does — for a phone that
    // still holds the challenge and the handoff key. This one does not, and
    // neither can be recovered by anyone. Left to the Authority's answer alone
    // the screen would draw 「正在领取归属凭证」 with 「立即检查状态」 beside it,
    // which is this screen's original defect arriving from the other side.
    //
    // And no withdrawal either: `approved_awaiting_handoff` has no transition
    // to `canceled`, so a 「撤回」 here would fail every time it was pressed.
    await open(
      tester,
      MobileBodyStanding.approvedAwaitingHandoff,
      HubConfigStatus.waitingBinding,
      enrollment: _lostSession(),
    );

    expect(find.text('立即检查状态'), findsNothing);
    expect(find.text('正在检查…'), findsNothing);
    expect(find.text('撤回这次登记'), findsNothing);
    expect(find.text('登记这台手机'), findsNothing);
    // And the words have to change too. The Authority's own sentence for this
    // stage says 「不需要你做什么」 about a collection that is running — which
    // is a claim about the present, and false here.
    expect(find.textContaining('不需要你做什么'), findsNothing);
    expect(find.text('这次登记已经无法完成'), findsWidgets);
    // A wait is honest only when it names its end.
    expect(find.textContaining('过期'), findsWidgets);
  });

  testWidgets('a pending Enrollment this phone cannot finish can be withdrawn',
      (tester) async {
    // Same loss, different stage — and here the Authority does allow the
    // withdrawal, so there is a real way out rather than a wait.
    await open(
      tester,
      MobileBodyStanding.pendingReview,
      HubConfigStatus.pendingApproval,
      enrollment: _lostSession(),
    );

    expect(find.text('撤回这次登记'), findsWidgets);
    expect(find.text('立即检查状态'), findsNothing);
    // Not the approval sentence: approving this would carry it into the state
    // that cannot be withdrawn at all.
    expect(find.textContaining('你自己就能给'), findsNothing);
    expect(find.text('这次登记已经无法完成'), findsWidgets);
  });

  testWidgets('a Claim with no Channel may be asked about again',
      (tester) async {
    // This test used to assert that nothing at all was offered, and that was
    // right while the app could not ask for a channel: 「立即检查状态」 would
    // have been a retry in front of a question nobody was asking. The app asks
    // now, and the Host provisions the channel after the Claim — so asking
    // again is how it arrives, and withholding the control would be the
    // opposite mistake.
    //
    // What must still not appear is enrollment: this phone is already a Body,
    // and proposing again would undo something.
    await open(
      tester,
      MobileBodyStanding.claimActiveWithoutChannel,
      HubConfigStatus.waitingBinding,
      enrollment: _lostSession(),
    );

    expect(find.text('登记这台手机'), findsNothing);
    expect(find.text('立即检查状态'), findsWidgets);
    // And the sentence must not promise the channel is coming. This used to
    // assert 「分不出来」 on the belief that the Authority answers the same way
    // whether provisioning is unfinished or was refused. It does not — Device
    // Control tags its refusal — so the unrefused case says the one true thing
    // about itself: the Host did not refuse, and asking again may work.
    expect(find.textContaining('服务尚未提供原因'), findsWidgets);
    expect(find.textContaining('分不出来'), findsNothing);
    expect(find.textContaining('当前版本'), findsNothing);
  });

  testWidgets('with no route to enrollment, nothing is drawn', (tester) async {
    // A button wired to nothing would be worse than the silence it replaced —
    // and unlike the pending-approval case there is no honest fallback, because
    // this standing does not advance on its own.
    await open(
      tester,
      MobileBodyStanding.notEnrolled,
      HubConfigStatus.unregistered,
    );

    expect(find.text('登记这台手机'), findsNothing);
    expect(find.text('立即检查状态'), findsNothing);
  });

  testWidgets('a phone awaiting its own approval is offered the approval',
      (tester) async {
    // The real path: this phone made the proposal and still holds what it
    // takes to finish, so approving it leads somewhere. A phone that had lost
    // either half would be offered a withdrawal instead — approving there walks
    // the person into `approved_awaiting_handoff`, which cannot be cancelled.
    await open(
      tester,
      MobileBodyStanding.pendingReview,
      HubConfigStatus.pendingApproval,
      enrollment: await _holdingSession(),
    );

    expect(find.text('去批准这台手机'), findsWidgets);
    expect(find.text('等你批准这台手机'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no route to the queue, the check button is still there',
      (tester) async {
    // Falling back rather than showing a dead button: this state does advance,
    // so re-asking is a real action even when this screen cannot navigate.
    await open(
      tester,
      MobileBodyStanding.pendingReview,
      HubConfigStatus.pendingApproval,
      withApprovalRoute: false,
      enrollment: await _holdingSession(),
    );

    expect(find.text('去批准这台手机'), findsNothing);
    expect(find.text('立即检查状态'), findsWidgets);
  });

  testWidgets('the id on screen is the one Hub would recognise',
      (tester) async {
    await open(
      tester,
      MobileBodyStanding.notEnrolled,
      HubConfigStatus.unregistered,
    );

    expect(find.text(phoneDeviceInstanceId), findsWidgets);
    expect(find.text(phoneInstallId), findsNothing);
  });
}

/// A session that holds nothing: no proposal, no handoff key.
///
/// What a relaunched process has. Both halves an Enrollment needs to finish —
/// the collection challenge and the one-shot key — exist only in the process
/// that proposed, and neither can be recovered by anyone.
MobileBodyEnrollmentSession _lostSession() => MobileBodyEnrollmentSession(
      loadTarget: () async => deviceOnboardingTargetFixture(),
      buildAdmission: (_) => throw UnimplementedError(
        'a lost session decides what to offer; it performs nothing',
      ),
      platform: FakePhonePlatform(),
    );

/// A session that proposed and still holds what it takes to finish.
class _HoldingPlatform extends FakePhonePlatform {
  bool _holds = false;

  @override
  Future<bool> holdsHandoffKey() async => _holds;

  @override
  Future<PlatformHandoffKey> issueHandoffKey() async {
    _holds = true;
    return PlatformHandoffKey(
      handle: 'handle-1',
      publicKey: 'p256-spki:AAAA',
      keyId: 'sha256:${'a' * 64}',
    );
  }

  @override
  Future<String> signDeviceCanonicalDocument(String document) async =>
      base64Url.encode(List<int>.filled(64, 7)).replaceAll('=', '');
}

class _StubAdmissionController implements DeviceAdmissionPort {
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

Future<MobileBodyEnrollmentSession> _holdingSession() async {
  final platform = _HoldingPlatform();
  final session = MobileBodyEnrollmentSession(
    loadTarget: () async => deviceOnboardingTargetFixture(),
    buildAdmission: (_) => MobileBodyAdmission(
      issueVoucher: _StubAdmissionController().issueCommissioningVoucher,
      authority: AdmissionAuthorityClient(
        authority: Uri.parse('https://hub.owner-domain.invalid'),
        transport: MockClient(
          (_) async => http.Response(
            jsonEncode(
              canonicalContractValue('DF-ADMISSION-CREATE-RESULT-VALID'),
            ),
            201,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      ),
      claims: InMemoryMobileBodyClaimStore(),
      platform: platform,
    ),
    platform: platform,
  );
  await session.propose(title: 'Eidolon Mobile');
  return session;
}

class _FakeProvisioner implements ConversationProvisioner {
  _FakeProvisioner(this.response);

  final HubConfig response;

  @override
  String get serviceName => 'owner-domain_01';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/admission');

  @override
  Future<HubConfig> provision({String sessionIntent = '', ConversationMode? mode}) async => response;
}
