/// The one Enrollment this phone has in flight, and what can still be done
/// about it.
///
/// ## The fact this whole file is shaped around
///
/// The collection challenge is returned exactly once, in the answer to
/// `POST /enrollments`, and the Authority keeps only its SHA-256
/// (`hub/admission/application.py`). So a proposal whose challenge this process
/// no longer has **cannot be collected by anybody, ever** — not by re-reading
/// the projection, not by another device, not by the Owner. The same is true of
/// the handoff key, which lives only in memory.
///
/// Both losses have one cause — this process ended, or its answer never
/// arrived — and one meaning: that Enrollment is over, whatever the Authority
/// still says about it. What differs is only what can be done next, and that
/// is decided by the Authority's transition table rather than by preference.
///
/// ## Cancelling is not always available, and the button must not pretend
///
/// `ALLOWED_PROPOSAL_TRANSITIONS` lets `pending_review` go to `canceled`. It
/// does **not** let `approved_awaiting_handoff` go there: from approved, a
/// proposal may only be delivered, expire, or have its Claim revoked. So an
/// approved Enrollment this phone can no longer finish cannot be withdrawn
/// either — the only thing that ends it is its own expiry, and the only honest
/// screen is one that says so and names the time.
///
/// That is still not the shape this project keeps deleting. 「正在领取归属凭证 /
/// 不需要你做什么」 in front of a collection that is not happening is a lie
/// about the present. 「这次登记已经无法完成，它会在 <时刻> 过期」 is a wait with
/// a named end and a stated cause, which is a different thing.
library;

import '../../platform/platform_bridge.dart';
import '../conversation/mobile_body_standing.dart';
import '../conversation/mobile_conversation_provisioner.dart';
import 'admission_authority_client.dart';
import 'device_setup_models.dart';
import 'mobile_body_enrollment.dart';
import 'mobile_body_claim_store.dart';

/// Builds the admission chain for one reading of the Owner Domain directory.
///
/// A function of the target rather than a value, because the Authority's
/// address and the trust anchor that reaches it are two facts from the same
/// signed descriptor. Built from separate readings they could disagree, and the
/// disagreement would look like a network problem.
typedef MobileBodyAdmissionBuilder = MobileBodyAdmission Function(
  DeviceOnboardingTarget target,
);

/// What the person holding this phone can do about its Enrollment now.
enum MobileBodyEnrollmentAct {
  /// Nothing is in flight. Propose this phone.
  propose,

  /// Proposed, and waiting on an approval this same person can give.
  approve,

  /// Approved, and this phone still holds what it takes to finish.
  collect,

  /// In flight, unfinishable, and still withdrawable. Cancel, then propose.
  abandon,

  /// In flight, unfinishable, and not withdrawable. Only expiry ends it.
  waitForExpiry,

  /// Nothing to offer, because the gap is not this phone's to close.
  none,
}

/// Raised when an act is asked for that this session cannot perform.
///
/// Distinct from [AdmissionRefusal]: nothing was asked of the Authority, and
/// the reason is local. Presenting this as a server refusal would send the
/// reader looking in the wrong place.
class MobileBodyEnrollmentUnavailable implements Exception {
  const MobileBodyEnrollmentUnavailable(this.message);

  final String message;

  @override
  String toString() => 'MobileBodyEnrollmentUnavailable: $message';
}

/// Holds the in-flight proposal for exactly as long as it can be finished.
///
/// Not persisted, deliberately, and this is the one place where "in memory
/// only" is the correct storage rather than a compromise: what it holds is
/// only useful while the handoff key it names is also in memory, and writing
/// half of a pair to disk produces a record that looks resumable and is not.
class MobileBodyEnrollmentSession {
  MobileBodyEnrollmentSession({
    required MobileBodyAdmissionBuilder buildAdmission,
    required DeviceOnboardingTargetLoader loadTarget,
    PlatformBridge platform = const PlatformBridge(),
    String Function()? newCommandId,
    MobileBodyClaimStore? claims,
    void Function(MobileBodyAdmission, DeviceOnboardingTarget)? rebindAdmission,
  })  : _buildAdmission = buildAdmission,
        _loadTarget = loadTarget,
        _platform = platform,
        _newCommandId = newCommandId ?? _defaultCommandId,
        _claims = claims,
        _rebindAdmission = rebindAdmission;

  final MobileBodyAdmissionBuilder _buildAdmission;

  /// Where this Owner Domain's signed directory comes from.
  ///
  /// Held rather than passed in per call: a caller that supplied the target
  /// could supply a different one for the proposal than the Authority the
  /// Claim ends up at, and nothing downstream would notice.
  final DeviceOnboardingTargetLoader _loadTarget;
  final PlatformBridge _platform;
  final String Function() _newCommandId;

  final MobileBodyClaimStore? _claims;
  final void Function(MobileBodyAdmission, DeviceOnboardingTarget)?
      _rebindAdmission;
  String? _directoryVersion;
  MobileBodyAdmission? _admission;
  String? _ownerDomainId;
  String? _proposeCommand;
  String? _collectCommand;
  String? _ackCommand;
  String? _abandonCommand;
  String? _proposalTitle;
  MobileBodyProposal? _pending;

  Future<MobileBodyAdmission> _client() async {
    final target = await _loadTarget();
    if (_ownerDomainId != null && _ownerDomainId != target.ownerDomainId) {
      throw const MobileBodyEnrollmentUnavailable('不能把进行中的登记转到另一个 Owner。');
    }
    _ownerDomainId = target.ownerDomainId;
    final version =
        '${target.hostAddress}|${target.ownerDomainDescriptor.toJson()}';
    if (_admission != null && version != _directoryVersion) {
      _rebindAdmission?.call(_admission!, target);
    }
    _directoryVersion = version;
    return _admission ??= _buildAdmission(target);
  }

  Future<bool> resumeAcknowledgement() async {
    final identity = await _platform.getDeviceIdentity();
    final record = await _claims?.loadFor(identity.operationalPublicKey);
    if (record == null || !record.ackPending) return false;
    final target = await _loadTarget();
    if (record.ownerDomainId != target.ownerDomainId) {
      throw const MobileBodyEnrollmentUnavailable('本机凭证属于另一个 Owner。');
    }
    await (await _client()).resumeAcknowledgement(
        correlationId: record.ackCommandId ?? _newCommandId());
    _clearOperation();
    return true;
  }

  void _clearOperation() {
    _pending = null;
    _proposeCommand = _collectCommand = _ackCommand = _abandonCommand = null;
    _proposalTitle = null;
    _admission = null;
  }

  /// The proposal this session made, if it still has one.
  MobileBodyProposal? get pending => _pending;
  bool get hasInFlightOperation =>
      _pending != null || (_admission?.hasPreparedProposal ?? false);

  /// Whether an Enrollment in flight can still be carried to a Claim.
  ///
  /// Both halves are required and neither can be recovered: the challenge this
  /// session is holding, and the handoff key the platform is holding. Asking
  /// the platform rather than assuming is the point — a hot restart keeps this
  /// object and loses the key.
  Future<bool> canFinish() async {
    if (_pending == null) return false;
    return _platform.holdsHandoffKey();
  }

  /// What to offer, given what the Authority says and what this session holds.
  ///
  /// One decision in one place. Split across the screen and the controller it
  /// would be two, and the second one would eventually disagree.
  Future<MobileBodyEnrollmentAct> actFor(MobileBodyStanding standing) async {
    if (_pending == null &&
        _proposeCommand != null &&
        await _platform.holdsHandoffKey()) {
      // A lost create reply can be replayed with its original command, proof
      // and key. Do not strand it merely because navigation rebuilt the page.
      return MobileBodyEnrollmentAct.propose;
    }
    if (standing.canProposeItself) {
      if (_pending != null) _clearOperation();
      return MobileBodyEnrollmentAct.propose;
    }
    switch (standing) {
      case MobileBodyStanding.pendingReview:
        // Withdrawable, so an unfinishable one has a way out.
        return await canFinish()
            ? MobileBodyEnrollmentAct.approve
            : MobileBodyEnrollmentAct.abandon;
      case MobileBodyStanding.approvedAwaitingHandoff:
      case MobileBodyStanding.grantDelivered:
        // Past the point the Authority allows a cancellation.
        return await canFinish()
            ? MobileBodyEnrollmentAct.collect
            : MobileBodyEnrollmentAct.waitForExpiry;
      case MobileBodyStanding.claimActiveWithoutChannel:
      case MobileBodyStanding.notEnrolled:
      case MobileBodyStanding.claimRevoked:
      case MobileBodyStanding.admissionEnded:
        return MobileBodyEnrollmentAct.none;
    }
  }

  /// Propose this phone, keeping what it takes to finish.
  ///
  /// Refuses while a finishable proposal is in hand. Proposing over one would
  /// replace the handoff key and strand the first at the Authority — silently,
  /// and in the one state that cannot be cancelled if it has been approved.
  Future<MobileBodyProposal> propose({
    required String title,
    String? correlationId,
  }) async {
    if (_pending != null) {
      throw const MobileBodyEnrollmentUnavailable(
        '这台手机已经提出过一次登记，还没有走完。先处理那一次，再提出新的。',
      );
    }
    // An uncertain create retries the retained command and prepared evidence.
    final target = await _loadTarget();
    final proposal = await (await _client()).propose(
      target: target,
      title: _proposalTitle ??= title,
      commandId: _proposeCommand ??= _newCommandId(),
      correlationId: correlationId ?? _proposeCommand!,
    );
    _pending = proposal;
    return proposal;
  }

  /// Finish an approved Enrollment.
  Future<MobileBodyClaim> complete({String? correlationId}) async {
    final proposal = _pending;
    if (proposal == null || !await _platform.holdsHandoffKey()) {
      throw const MobileBodyEnrollmentUnavailable(
        '这次登记已经无法完成：领取凭证需要的一次性密钥和挑战只在这次运行里存在，'
        '它们已经不在了。任何一方都收不了这份凭证。',
      );
    }
    final claim = await (await _client()).completeAdmission(
      proposal: proposal,
      collectCommandId: _collectCommand ??= _newCommandId(),
      ackCommandId: _ackCommand ??= _newCommandId(),
      correlationId: correlationId ?? _newCommandId(),
    );
    _clearOperation();
    return claim;
  }

  /// Withdraw an Enrollment that is still withdrawable.
  ///
  /// Only `pending_review` is, and the Authority is the one that says so —
  /// this refuses on its own only for the case it can know locally, which is
  /// having nothing to withdraw.
  Future<void> abandon({
    required String enrollmentId,
    required String reason,
    String? correlationId,
  }) async {
    if (enrollmentId.isEmpty) {
      throw const MobileBodyEnrollmentUnavailable(
        '没有可撤回的登记。',
      );
    }
    await (await _client()).abandon(
      enrollmentId: enrollmentId,
      commandId: _abandonCommand ??= _newCommandId(),
      correlationId: correlationId ?? _abandonCommand!,
      reason: reason,
    );
    _clearOperation();
  }

  /// Forget an unfinishable proposal without asking the Authority anything.
  ///
  /// For the case where the Enrollment will end on its own: the record here is
  /// of no further use, and keeping it would let a later `canFinish` speak
  /// about a proposal whose key is already gone.
  void forget() {
    _clearOperation();
  }
}

int _commandCounter = 0;

/// A command id that is unique within this process.
///
/// Idempotency keys, not secrets. What they must not do is repeat across two
/// different commands, because the Authority replays a repeated one instead of
/// acting — which is exactly what makes a lost reply safe to retry and a reused
/// key unsafe to send.
String _defaultCommandId() {
  _commandCounter += 1;
  return 'mobile-${DateTime.now().microsecondsSinceEpoch}-$_commandCounter';
}
