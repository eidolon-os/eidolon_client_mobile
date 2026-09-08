import '../../generated/device_foundation_v1.dart';
import '../../models/hub_models.dart';
import '../../platform/platform_bridge.dart';
import '../device_setup/admission_projection.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/mobile_body_claim_store.dart';
import 'device_control_client.dart';
import '../device_setup/owner_domain_endpoints.dart';
import 'conversation_provisioner.dart';
import 'mobile_body_standing.dart';
import 'channel_refusal.dart';

typedef DeviceOnboardingTargetLoader = Future<DeviceOnboardingTarget>
    Function();

/// Reads Mobile's Admission state without treating approval as ClaimActive.
///
/// Channel delivery is deliberately not reconstructed from Admission. Until a
/// canonical Channel projection is available this returns waitingBinding after
/// ClaimActive instead of reviving the removed synchronous handoff DTO.
///
/// What this reads is the whole Owner Domain's recovery list, and what it
/// answers is one question about one device: where does *this* phone stand.
/// Every stage is reported as itself — including the stage that is not a stage,
/// [MobileBodyStanding.notEnrolled], which is where this phone has actually
/// been the whole time. It only reads: proposing an Enrollment is the device's
/// own act, performed by `device_setup/mobile_body_enrollment.dart` since
/// 2026-09-06, and never by this projection. So `notEnrolled` here means the
/// proposal has not been made — an act waiting on a person, not a claim in
/// progress.
final class MobileConversationProvisioner implements ConversationProvisioner {
  MobileConversationProvisioner({
    required DeviceOnboardingTargetLoader loadTarget,
    required DeviceAdmissionPort admission,
    MobileBodyClaimStore? claims,
    DeviceControlClientBuilder? buildDeviceControl,
    PlatformBridge? platform,
  })  : _loadTarget = loadTarget,
        _admission = admission,
        _claims = claims,
        _buildDeviceControl = buildDeviceControl,
        _platform = platform ?? const PlatformBridge();

  final DeviceOnboardingTargetLoader _loadTarget;
  final DeviceAdmissionPort _admission;

  /// The Claim this phone holds, if it has been remembered.
  ///
  /// Needed because the `DeviceRef` a configuration pull is addressed to lives
  /// in the Grant this device opened, and nowhere in the Admission projection
  /// this class reads. Null wiring means the channel is never asked for, which
  /// leaves `claimActiveWithoutChannel` — still true, just older.
  final MobileBodyClaimStore? _claims;

  /// Builds the Device Control client for one reading of the directory.
  ///
  /// A function of the target for the same reason the Admission one is: the
  /// authority's address and the trust anchor that reaches it are two facts
  /// from the same signed descriptor.
  final DeviceControlClientBuilder? _buildDeviceControl;

  final PlatformBridge _platform;

  DeviceOnboardingTarget? _lastTarget;

  @override
  String get serviceName => _lastTarget?.ownerDomainId ?? 'Eidolon Hub';

  @override
  Uri get serviceUri {
    final target = _lastTarget;
    if (target == null) return Uri.parse('https://eidolon.invalid/');
    return ownerDomainAuthorityEndpoint(
          target,
          authority: admissionAuthorityName,
        ) ??
        Uri.parse('https://eidolon.invalid/');
  }

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async {
    final target = await _loadTarget();
    _lastTarget = target;
    final identity = await _platform.getDeviceIdentity();
    // This device's identity in the Owner Domain is derived from its own
    // operational key. It used to compare an ANDROID_ID-derived
    // `mobile-android-<hash>` against a field Hub only ever writes as
    // `device-instance-<sha256(spki)>` — a comparison that was false by
    // construction, so this phone could not have recognised its own record
    // even once one existed.
    final deviceInstanceId = identity.deviceInstanceId;
    AdmissionListCursorV1? cursor;
    EnrollmentRecoveryProjectionV1? found;
    do {
      final page = await _admission.listRecovery(after: cursor);
      for (final projection in page.projections) {
        // Find ours, then validate ours. Validating every projection on the
        // way past made this device's conversation depend on the health of
        // every other device in the Owner Domain: one unrelated record with a
        // generation the phone disagreed with threw FormatException and took
        // down a flow that had nothing to do with it. The record that is found
        // is validated below, which is the one that has to be sound.
        if (projection.proposal.json['device_instance_candidate_id'] ==
            deviceInstanceId) {
          found = projection;
          break;
        }
      }
      cursor = found == null ? page.nextCursor : null;
    } while (cursor != null);

    if (found == null) {
      return _empty(
        HubConfigStatus.unregistered,
        identity.fingerprint,
        // No proposal exists, so there is nothing to name — and naming an
        // empty one would let a screen offer to withdraw it.
        null,
        MobileBodyStanding.notEnrolled,
      );
    }
    final enrollment = _enrollmentRef(found);
    return switch (found.validateForOwner(
      target.ownerDomainId,
      ownerDomainGeneration: target.ownerDomainDescriptor.ownerDomainGeneration,
    )) {
      AdmissionProjectionStage.pendingReview => _empty(
          HubConfigStatus.pendingApproval,
          identity.fingerprint,
          enrollment,
          MobileBodyStanding.pendingReview,
        ),
      AdmissionProjectionStage.approvedAwaitingHandoff => _empty(
          HubConfigStatus.waitingBinding,
          identity.fingerprint,
          enrollment,
          MobileBodyStanding.approvedAwaitingHandoff,
        ),
      AdmissionProjectionStage.grantDelivered => _empty(
          HubConfigStatus.waitingBinding,
          identity.fingerprint,
          enrollment,
          MobileBodyStanding.grantDelivered,
        ),
      // Claimed, and still without a Channel. Reported apart from the two
      // stages above on purpose: those are a few seconds of work this phone is
      // doing, this one is where the current version stops. Saying all three
      // with 「正在关联 Companion」 used progress to cover an unimplemented edge.
      // Claimed. Whether there is a Channel is the Authority's to say, and
      // this is the one edge that asks — a device that inferred it from a
      // local record would keep talking after a revocation.
      AdmissionProjectionStage.claimActive => await _configuration(
          target,
          identity,
          enrollment,
        ),
      AdmissionProjectionStage.claimRevoked => _empty(
          HubConfigStatus.revoked,
          identity.fingerprint,
          enrollment,
          MobileBodyStanding.claimRevoked,
        ),
      AdmissionProjectionStage.rejected ||
      AdmissionProjectionStage.expired ||
      AdmissionProjectionStage.canceled =>
        _empty(
          HubConfigStatus.unregistered,
          identity.fingerprint,
          enrollment,
          MobileBodyStanding.admissionEnded,
        ),
    };
  }

  /// Ask the Authority what this claimed Body's configuration is.
  ///
  /// Three answers, and they are three different sentences:
  ///
  /// * revoked — the Claim is gone, and this edge is where a device finds out;
  /// * a channel — this phone can talk;
  /// * no channel — still true, still the Host's to close, and still not
  ///   something to retry into.
  ///
  /// A refusal is reported as no channel rather than raised. The screen already
  /// has a standing to show and a sentence for it, and turning a Device Control
  /// fault into a failed conversation start would replace a true sentence with
  /// a technical one.
  Future<HubConfig> _configuration(
    DeviceOnboardingTarget target,
    DeviceIdentity identity,
    MobileBodyEnrollmentRef? enrollment,
  ) async {
    final store = _claims;
    final build = _buildDeviceControl;
    if (store == null || build == null) {
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
      );
    }
    // Scoped to this key: a record left by a previous installation names a
    // device this phone can no longer sign for.
    final claim = await store.loadFor(identity.operationalPublicKey);
    if (claim == null) {
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
      );
    }
    final DeviceConfiguration configuration;
    try {
      configuration = await build(target).pullConfiguration(
        deviceRef: claim.deviceRef,
        operationalPublicKey: identity.operationalPublicKey,
        sign: _platform.signDeviceCanonicalDocument,
      );
    } on DeviceControlRefusal catch (refusal) {
      // The Host said why. Throwing that away and reporting 「还没有通道」 is
      // what made the screen tell a person the two cases were
      // indistinguishable, while the distinguishing tag sat in this exception.
      // An unrecognised tag maps to null, and the sentence then says only that
      // the Host refused — not which remedy to reach for.
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
        refusal: ChannelRefusal.forDetail(refusal.detail),
      );
    } on Exception {
      // Nothing was decided: the request did not complete, or came back
      // unreadable. Saying 「已经问过主机了」 here was false.
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
        refusal: ChannelRefusal.hostUnanswered,
      );
    }
    if (!configuration.claimStands) {
      // The Authority says this Body is no longer one. The local record is of
      // no further use and keeping it would let the next launch present a
      // revoked identity.
      await store.clear();
      return _empty(
        HubConfigStatus.revoked,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimRevoked,
      );
    }
    final session = configuration.session;
    if (session == null) {
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
      );
    }
    return HubConfig(
      status: HubConfigStatus.active,
      session: session,
      deviceFingerprint: identity.fingerprint,
      bodyEnrollment: enrollment,
    );
  }

  /// The proposal's id, revision and expiry, read out of the projection.
  ///
  /// Returns null rather than a partly-filled reference when the id is not
  /// readable: an id is what a withdrawal is addressed to, and a screen holding
  /// half of one would offer an act it cannot perform.
  static MobileBodyEnrollmentRef? _enrollmentRef(
    EnrollmentRecoveryProjectionV1 projection,
  ) {
    final proposal = projection.proposal.json;
    final enrollmentId = proposal['enrollment_id'];
    final revision = proposal['proposal_revision'];
    if (enrollmentId is! String || enrollmentId.isEmpty || revision is! int) {
      return null;
    }
    final expiresAt = proposal['expires_at'];
    return MobileBodyEnrollmentRef(
      enrollmentId: enrollmentId,
      proposalRevision: revision,
      // A time this build cannot parse is left absent rather than guessed. The
      // screen says less; it does not say something else.
      expiresAt: expiresAt is String ? DateTime.tryParse(expiresAt)?.toUtc() : null,
    );
  }

  HubConfig _empty(
    HubConfigStatus status,
    String fingerprint,
    MobileBodyEnrollmentRef? enrollment,
    MobileBodyStanding standing, {
    ChannelRefusal? refusal,
  }) =>
      HubConfig(
        status: status,
        channelRefusal: refusal,
        session: const RoomConfig(
          serverUrl: '',
          token: '',
          identity: '',
          roomName: '',
        ),
        deviceFingerprint: fingerprint,
        bodyStanding: standing,
        bodyEnrollment: enrollment,
      );
}

/// Builds the Device Control client for one reading of the directory.
typedef DeviceControlClientBuilder = DeviceControlClient Function(
  DeviceOnboardingTarget target,
);
