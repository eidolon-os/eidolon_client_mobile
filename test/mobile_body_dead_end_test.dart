import 'dart:async';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment_session.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

/// The screen stops polling for something that cannot arrive.
///
/// A phone with no Enrollment used to reach `pendingApproval`, be drawn as
/// 「待批准 / 主机正在认领 Mobile」, and re-ask the Host every five seconds for the
/// rest of the session. Nothing was going to answer differently: only a device
/// may propose itself, and this version cannot. The retry was the whole product
/// in that state.
void main() {
  HubConfig standing(MobileBodyStanding value, HubConfigStatus status) =>
      HubConfig(
        status: status,
        session: const RoomConfig(
          serverUrl: '',
          token: '',
          identity: '',
          roomName: '',
        ),
        deviceFingerprint: phoneFingerprint,
        bodyStanding: value,
      );

  Future<ClientController> connect(HubConfig config) async {
    final provisioner = _FakeProvisioner(config);
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: provisioner,
    );
    await controller.start();
    return controller;
  }

  test('no Enrollment is a stop, not a wait', () async {
    final controller = await connect(
      standing(MobileBodyStanding.notEnrolled, HubConfigStatus.unregistered),
    );

    expect(controller.phase, ClientPhase.bodyBlocked);
    expect(controller.isWaiting, isFalse);
    expect(controller.failure, isNull, reason: 'nothing failed');
    expect(controller.uiState.headline, isNot(contains('正在')));
    controller.dispose();
  });

  test('a stop does not poll', () async {
    final provisioner = _FakeProvisioner(
      standing(MobileBodyStanding.notEnrolled, HubConfigStatus.unregistered),
    );
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: provisioner,
    );

    await controller.start();
    final afterStart = provisioner.calls;
    // Comfortably past the five-second activation refresh this used to arm.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await controller.checkActivation();

    expect(provisioner.calls, afterStart,
        reason: 'a state that cannot advance must not be re-asked');
    controller.dispose();
  });

  test('ClaimActive without a Channel waits, and says what it cannot tell',
      () async {
    // This asserted a stop, and that was right while the app could not ask for
    // a channel at all — 「当前版本到此为止」 was the honest sentence and
    // re-asking would have been a retry in front of nothing.
    //
    // The app asks now (`device_control_client.dart`), and the Host provisions
    // the channel after the Claim, so this is a wait that can end. What it must
    // not do is promise: a provisioning that was refused looks identical from
    // here, and the sentence says that rather than choosing the hopeful
    // reading.
    final controller = await connect(
      standing(
        MobileBodyStanding.claimActiveWithoutChannel,
        HubConfigStatus.waitingBinding,
      ),
    );

    expect(controller.phase, ClientPhase.awaitingBinding);
    expect(controller.isWaiting, isTrue);
    expect(controller.uiState.supportingText, contains('分不出来'));
    expect(controller.uiState.supportingText, isNot(contains('当前版本')));
    controller.dispose();
  });

  test('a stage that does advance still waits, and offers the approval',
      () async {
    final controller = await connect(
      standing(
        MobileBodyStanding.pendingReview,
        HubConfigStatus.pendingApproval,
      ),
    );

    expect(controller.phase, ClientPhase.awaitingApproval);
    expect(controller.isWaiting, isTrue);
    expect(controller.awaitsThisControllersApproval, isTrue);
    controller.dispose();
  });

  test('an approved Grant is redeemed without anyone tapping', () async {
    // The bug this test exists for, found on real hardware after the suite was
    // green: the phone proposed itself, the Owner approved, and the chain then
    // stopped one step short of a Claim.
    //
    // `collect` was computed correctly and never acted on. It was drawn only
    // from `ClientPhase.bodyBlocked`, and this stage is not blocked — it
    // advances and this phone can advance it — so the screen fell through to a
    // bare 「立即检查状态」 above a card reading 「不需要你做什么」. Nothing was
    // performing the collection and nothing could.
    //
    // Redeeming a Grant the Authority has already approved is the device's own
    // step with no decision left in it, so the assertion is that it happens by
    // itself.
    final enrollment = _CollectingEnrollment();
    final provisioner = _FakeProvisioner(
      standing(
        MobileBodyStanding.approvedAwaitingHandoff,
        HubConfigStatus.waitingBinding,
      ),
    );
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: provisioner,
      enrollment: enrollment,
    );

    await controller.start();

    expect(enrollment.completions, 1, reason: 'nobody tapped anything');
    expect(controller.failure, isNull);
    controller.dispose();
  });

  test('a collection that failed leaves the act for a person', () async {
    // The other half. An automatic step that cannot report its own failure is
    // how a person ends up in front of a screen doing nothing forever — so the
    // refusal is surfaced and `collect` stays the act, which is what draws the
    // control.
    final enrollment = _CollectingEnrollment(refuse: true);
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: _FakeProvisioner(
        standing(
          MobileBodyStanding.approvedAwaitingHandoff,
          HubConfigStatus.waitingBinding,
        ),
      ),
      enrollment: enrollment,
    );

    await controller.start();

    expect(enrollment.completions, 1);
    expect(controller.failure, isNotNull);
    expect(controller.enrollmentAct, MobileBodyEnrollmentAct.collect);
    controller.dispose();
  });

  test('the legacy register path keeps its own refusal', () async {
    // `unregistered` with no standing is the old Hub register response, and it
    // must keep throwing rather than quietly becoming a blocked screen.
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: _FakeProvisioner(
        const HubConfig(
          status: HubConfigStatus.unregistered,
          session: RoomConfig(
            serverUrl: '',
            token: '',
            identity: '',
            roomName: '',
          ),
        ),
      ),
    );

    await controller.start();

    expect(controller.phase, ClientPhase.error);
    controller.dispose();
  });
}

class _FakeProvisioner implements ConversationProvisioner {
  _FakeProvisioner(this.response);

  final HubConfig response;
  var calls = 0;

  @override
  String get serviceName => 'Product Hub';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/descriptor');

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async {
    calls += 1;
    return response;
  }
}

class _FakeSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();

  @override
  Stream<SessionState> get stateEvents => _states.stream;

  @override
  bool get isConnected => false;

  @override
  Future<void> connect(RoomConfig config) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}

/// A session that says it can collect, and counts how often it is asked to.
///
/// Subclassed rather than mocked because the two members under test are the
/// decision (`actFor`) and the step (`complete`), and the real class's own
/// constructor dependencies are not reached by either.
class _CollectingEnrollment extends MobileBodyEnrollmentSession {
  _CollectingEnrollment({this.refuse = false})
      : super(
          buildAdmission: (_) =>
              throw StateError('the proposal path is not under test'),
          loadTarget: () =>
              throw StateError('the directory is not under test'),
          platform: FakePhonePlatform(),
        );

  final bool refuse;
  int completions = 0;

  @override
  Future<MobileBodyEnrollmentAct> actFor(MobileBodyStanding standing) async =>
      standing == MobileBodyStanding.approvedAwaitingHandoff
          ? MobileBodyEnrollmentAct.collect
          : MobileBodyEnrollmentAct.none;

  @override
  Future<MobileBodyClaim> complete({String? correlationId}) async {
    completions += 1;
    if (refuse) {
      throw const MobileBodyEnrollmentUnavailable('the Authority refused');
    }
    return MobileBodyClaim(
      grant: ClaimGrantV1.fromJson(
        canonicalContractValue('DF-ADMISSION-CLAIM-GRANT-VALID'),
      ),
      claimState: 'active',
    );
  }
}
