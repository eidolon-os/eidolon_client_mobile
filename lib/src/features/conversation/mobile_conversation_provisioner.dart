import '../../generated/device_foundation_v1.dart';
import '../../models/hub_models.dart';
import '../../models/conversation_mode.dart';
import '../device_setup/mobile_body_manifest.dart';
import '../../protocol/canonical_json.dart';
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

/// Standard Device provisioning. A held Claim uses Device Control directly;
/// Controller recovery reads are only needed to find unfinished admission or
/// recover a missing local reference. Neither path makes management decisions.
final class MobileConversationProvisioner
    implements RecoverableConversationProvisioner {
  MobileConversationProvisioner({
    required DeviceOnboardingTargetLoader loadTarget,
    required DeviceAdmissionPort admission,
    MobileBodyClaimStore? claims,
    DeviceControlClientBuilder? buildDeviceControl,
    PlatformBridge? platform,
    String? Function()? currentEnrollmentId,
    Future<bool> Function()? resumeAcknowledgement,
  })  : _loadTarget = loadTarget,
        _admission = admission,
        _claims = claims,
        _buildDeviceControl = buildDeviceControl,
        _platform = platform ?? const PlatformBridge(),
        _currentEnrollmentId = currentEnrollmentId,
        _resumeAcknowledgement = resumeAcknowledgement;

  final DeviceOnboardingTargetLoader _loadTarget;
  final DeviceAdmissionPort _admission;

  /// The Claim this phone holds, if it has been remembered.
  ///
  /// Normal configuration pulls use the reference saved from the acknowledged
  /// Grant. Explicit recovery can locate it in an Admission projection, but
  /// must prove the operational key through Device Control before saving it.
  final MobileBodyClaimStore? _claims;

  /// Builds the Device Control client for one reading of the directory.
  ///
  /// A function of the target for the same reason the Admission one is: the
  /// authority's address and the trust anchor that reaches it are two facts
  /// from the same signed descriptor.
  final DeviceControlClientBuilder? _buildDeviceControl;

  final PlatformBridge _platform;
  final String? Function()? _currentEnrollmentId;
  final Future<bool> Function()? _resumeAcknowledgement;

  DeviceOnboardingTarget? _lastTarget;

  /// Recover only a registration already approved and acknowledged at the
  /// selected, verified Authority. A management projection locates a public
  /// reference; it cannot authorize a session. Device Control still checks
  /// the operational key and returns the current Claim before we save anything.
  /// In particular, never rewrite the Owner field of a cached foreign ref.
  @override
  Future<void> recoverClaim() async {
    final store = _claims;
    final build = _buildDeviceControl;
    if (store == null || build == null) {
      throw const ConversationRecoveryUnavailable('当前连接不支持恢复设备记录');
    }
    final target = await _loadTarget();
    final identity = await _platform.getDeviceIdentity();
    final held = await store.loadFor(identity.operationalPublicKey);
    if (held?.ackPending == true || _currentEnrollmentId?.call() != null) {
      throw const ConversationRecoveryUnavailable('请先完成正在进行的设备登记');
    }
    final matches = await _matchingEnrollments(identity.deviceInstanceId);
    EnrollmentRecoveryProjectionV1? recovered;
    for (final candidate in matches) {
      final stage = candidate.validateForOwner(target.ownerDomainId,
          ownerDomainGeneration:
              target.ownerDomainDescriptor.ownerDomainGeneration);
      if (stage == AdmissionProjectionStage.claimActive &&
          candidate.proposal.json['state'] == 'grant_acknowledged' &&
          candidate.grantDelivery?.json['acknowledged_at'] != null &&
          candidate.approvalDecision != null) {
        recovered = candidate;
        break;
      }
    }
    if (recovered == null) {
      throw const ConversationRecoveryUnavailable('此主机没有可恢复的已完成登记。请返回选择原主机，'
          '或在设备管理中核对本机归属；原记录已保留。');
    }
    final reference =
        Map<String, Object?>.from(recovered.claim!.json['device_ref']! as Map);
    final configuration = await build(target).pullConfiguration(
        deviceRef: reference,
        operationalPublicKey: identity.operationalPublicKey,
        sign: _platform.signDeviceCanonicalDocument);
    if (!configuration.claimStands) {
      throw const ConversationRecoveryUnavailable('此主机上的登记已撤销，无法恢复。原记录已保留。');
    }
    if (configuration.deviceRef['owner_domain_generation'] !=
        target.ownerDomainDescriptor.ownerDomainGeneration) {
      throw const ConversationRecoveryUnavailable('主机归属代际在核验期间发生变化，请重新检查');
    }
    // Do not overwrite a concurrent admission/ACK or an identity replacement.
    final now = await _platform.getDeviceIdentity();
    final latest = await store.loadFor(now.operationalPublicKey);
    if (now.deviceInstanceId != identity.deviceInstanceId ||
        canonicalJsonEncode(latest?.toJson()) !=
            canonicalJsonEncode(held?.toJson())) {
      throw const ConversationRecoveryUnavailable('本机登记在核验期间发生变化，请重新检查');
    }
    final delivery = recovered.grantDelivery!.json;
    await store.save(MobileBodyClaimRecord(
        deviceRef: configuration.deviceRef,
        grantId: delivery['grant_id']! as String,
        ownerDomainId: target.ownerDomainId,
        deviceInstanceId: identity.deviceInstanceId,
        acknowledgedAt: DateTime.parse(delivery['acknowledged_at']! as String),
        enrollmentId: recovered.proposal.json['enrollment_id']! as String));
  }

  Future<List<EnrollmentRecoveryProjectionV1>> _matchingEnrollments(
      String deviceInstanceId) async {
    AdmissionListCursorV1? cursor;
    final matches = <EnrollmentRecoveryProjectionV1>[];
    do {
      final page = await _admission.listRecovery(after: cursor);
      matches.addAll(page.projections.where((p) =>
          p.proposal.json['device_instance_candidate_id'] == deviceInstanceId));
      cursor = page.nextCursor;
    } while (cursor != null);
    matches.sort((a, b) => (b.proposal.json['created_at'] as String? ?? '')
        .compareTo(a.proposal.json['created_at'] as String? ?? ''));
    return matches;
  }

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
  Future<HubConfig> provision(
      {String sessionIntent = '', ConversationMode? mode}) async {
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
    final held = await _claims?.loadFor(identity.operationalPublicKey);
    if (held != null && held.ownerDomainId != target.ownerDomainId) {
      return _empty(HubConfigStatus.waitingBinding, identity.fingerprint, null,
          MobileBodyStanding.claimActiveWithoutChannel,
          refusal: ChannelRefusal.ownerMismatch);
    }
    if (held?.ackPending == true) {
      if (_resumeAcknowledgement == null) {
        return _empty(HubConfigStatus.waitingBinding, identity.fingerprint,
            null, MobileBodyStanding.claimActiveWithoutChannel,
            refusal: ChannelRefusal.localClaimMissing);
      }
      await _resumeAcknowledgement();
    }
    final enrollmentId = _currentEnrollmentId?.call();
    // A claimed device asks Device Control directly. Controller availability
    // and the Owner's historical approval queue are not device authorization.
    if (held != null && enrollmentId == null) {
      return _configuration(target, identity, null, mode: mode);
    }
    EnrollmentRecoveryProjectionV1? found;
    if (enrollmentId != null) {
      found = await _admission.recover(enrollmentId: enrollmentId);
      if (found.proposal.json['device_instance_candidate_id'] !=
          deviceInstanceId) {
        throw const FormatException('Enrollment names another device');
      }
    } else {
      final matches = await _matchingEnrollments(deviceInstanceId);
      // No active local operation: prefer an unfinished enrollment over a
      // completed historical one, then the newest proposal in that group.
      matches.sort((a, b) {
        bool pending(EnrollmentRecoveryProjectionV1 p) => {
              'pending_review',
              'approved_awaiting_handoff',
              'grant_delivered'
            }.contains(p.proposal.json['state']);
        if (pending(a) != pending(b)) return pending(a) ? -1 : 1;
        return (b.proposal.json['created_at'] as String? ?? '')
            .compareTo(a.proposal.json['created_at'] as String? ?? '');
      });
      found = matches.firstOrNull;
    }

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
          mode: mode,
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
    MobileBodyEnrollmentRef? enrollment, {
    ConversationMode? mode,
  }) async {
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
      return _empty(HubConfigStatus.waitingBinding, identity.fingerprint,
          enrollment, MobileBodyStanding.claimActiveWithoutChannel,
          refusal: ChannelRefusal.localClaimMissing);
    }
    DeviceConfiguration configuration;
    try {
      final control = build(target);
      configuration = await control.pullConfiguration(
        deviceRef: claim.deviceRef,
        operationalPublicKey: identity.operationalPublicKey,
        sign: _platform.signDeviceCanonicalDocument,
      );
      if (mode != null && configuration.claimStands) {
        final accepted = configuration.manifest;
        if (accepted == null) {
          throw const FormatException('主机未提供已接受的设备声明，请更新主机后重试');
        }
        final desired = mobileBodyManifestRef(
            title: defaultMobileBodyTitle,
            mode: mode,
            revision: accepted.revision + 1);
        if (accepted.manifestId != desired['manifest_id'] ||
            accepted.digest != desired['digest']) {
          await control.assertManifest(
              deviceRef: configuration.deviceRef,
              manifest: desired,
              operationalPublicKey: identity.operationalPublicKey,
              sign: _platform.signDeviceCanonicalDocument);
          configuration = await control.pullConfiguration(
              deviceRef: configuration.deviceRef,
              operationalPublicKey: identity.operationalPublicKey,
              sign: _platform.signDeviceCanonicalDocument);
          if (configuration.manifest?.digest != desired['digest'] ||
              configuration.manifest?.revision != desired['revision']) {
            throw const FormatException('设备声明在准备期间发生变化，请重试');
          }
        }
      }
    } on DeviceControlRefusal catch (refusal) {
      // The Host said why. Throwing that away and reporting 「还没有通道」 is
      // what made the screen tell a person the two cases were
      // indistinguishable, while the distinguishing tag sat in this exception.
      // Unknown refusals remain refusals; they never become a pending channel.
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
        refusal: refusal.invalidResponse
            ? ChannelRefusal.invalidResponse
            : refusal.status == 403
                ? ChannelRefusal.proofRejected
                : refusal.retryable
                    ? ChannelRefusal.hostUnanswered
                    : ChannelRefusal.forDetail(refusal.detail),
        diagnostic: refusal.toString(),
      );
    } on Exception catch (error) {
      // Nothing was decided: the request did not complete, or came back
      // unreadable. Saying 「已经问过主机了」 here was false.
      return _empty(
        HubConfigStatus.waitingBinding,
        identity.fingerprint,
        enrollment,
        MobileBodyStanding.claimActiveWithoutChannel,
        refusal: ChannelRefusal.hostUnanswered,
        diagnostic: error.toString(),
      );
    }
    // The Authority answered with the ref it holds, which is not necessarily
    // the one this ask carried: it finds the Claim by identity, so a ref that
    // fell behind — the Owner re-added an already-claimed device, and Admission
    // upserted the Claim at the next `claim_generation` — is corrected in the
    // answer instead of refused. Reading the correction and not keeping it is
    // what left a recovered phone permanently behind: the channel arrived, the
    // conversation worked, and the stored ref stayed stale for every later
    // surface that is still matched on the exact generation — a Manifest
    // assertion, and the erase ACK that is a device's durable evidence it
    // dropped what it held under one specific Claim.
    //
    // A correction to one fact. The Grant this Claim was opened with, the key
    // it belongs to and the moment it was acknowledged all happened, and none
    // of them moved — so they are copied rather than reissued, and the record's
    // identity cannot be changed by this write even if the answer tried to.
    // That it cannot is also checked where the answer is read, in
    // `DeviceControlClient`: only the generations may move.
    if (!_sameDeviceRef(configuration.deviceRef, claim.deviceRef)) {
      await store.save(
        MobileBodyClaimRecord(
          deviceRef: configuration.deviceRef,
          grantId: claim.grantId,
          ownerDomainId: claim.ownerDomainId,
          deviceInstanceId: claim.deviceInstanceId,
          acknowledgedAt: claim.acknowledgedAt,
          enrollmentId: claim.enrollmentId,
        ),
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
      expiresAt:
          expiresAt is String ? DateTime.tryParse(expiresAt)?.toUtc() : null,
    );
  }

  HubConfig _empty(
    HubConfigStatus status,
    String fingerprint,
    MobileBodyEnrollmentRef? enrollment,
    MobileBodyStanding standing, {
    ChannelRefusal? refusal,
    String diagnostic = '',
  }) =>
      HubConfig(
        status: status,
        channelRefusal: refusal,
        diagnostic: diagnostic,
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

/// Whether two `DeviceRef`s say the same thing.
///
/// Member by member rather than through the canonicaliser, which is the other
/// obvious way to compare two of these: a ref read back from the store can
/// hold a number `canonicalJsonEncode` refuses to render, and that would throw
/// here — on the recovery path, after the Host had already answered.
bool _sameDeviceRef(Map<String, Object?> answered, Map<String, Object?> held) =>
    answered.length == held.length &&
    answered.keys.every((member) => answered[member] == held[member]);

/// Builds the Device Control client for one reading of the directory.
typedef DeviceControlClientBuilder = DeviceControlClient Function(
  DeviceOnboardingTarget target,
);
