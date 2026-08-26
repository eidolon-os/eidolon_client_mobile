import '../../generated/device_foundation_v1.dart';
import '../../models/hub_models.dart';
import '../../platform/platform_bridge.dart';
import '../device_setup/admission_projection.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import 'conversation_provisioner.dart';

typedef DeviceOnboardingTargetLoader = Future<DeviceOnboardingTarget>
    Function();

/// Reads Mobile's Admission state without treating approval as ClaimActive.
///
/// Channel delivery is deliberately not reconstructed from Admission. Until a
/// canonical Channel projection is available this returns waitingBinding after
/// ClaimActive instead of reviving the removed synchronous handoff DTO.
final class MobileConversationProvisioner implements ConversationProvisioner {
  MobileConversationProvisioner({
    required DeviceOnboardingTargetLoader loadTarget,
    required DeviceAdmissionPort admission,
    PlatformBridge? platform,
  })  : _loadTarget = loadTarget,
        _admission = admission,
        _platform = platform ?? const PlatformBridge();

  final DeviceOnboardingTargetLoader _loadTarget;
  final DeviceAdmissionPort _admission;
  final PlatformBridge _platform;

  DeviceOnboardingTarget? _lastTarget;

  @override
  String get serviceName => _lastTarget?.ownerDomainId ?? 'Eidolon Hub';

  @override
  Uri get serviceUri {
    final target = _lastTarget;
    if (target == null) return Uri.parse('https://eidolon.invalid/');
    final endpoints = target.ownerDomainDescriptor.endpoints
        .where((item) => item.authority == 'admission')
        .toList(growable: false)
      ..sort((left, right) => left.priority.compareTo(right.priority));
    return endpoints.isEmpty
        ? Uri.parse('https://eidolon.invalid/')
        : endpoints.first.uri;
  }

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async {
    final target = await _loadTarget();
    _lastTarget = target;
    final identity = await _platform.getDeviceIdentity();
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
            identity.deviceId) {
          found = projection;
          break;
        }
      }
      cursor = found == null ? page.nextCursor : null;
    } while (cursor != null);

    if (found == null) {
      return _empty(HubConfigStatus.pendingApproval, identity.fingerprint);
    }
    return switch (found.validateForOwner(
      target.ownerDomainId,
      ownerDomainGeneration: target.ownerDomainDescriptor.ownerDomainGeneration,
    )) {
      AdmissionProjectionStage.pendingReview =>
        _empty(HubConfigStatus.pendingApproval, identity.fingerprint),
      AdmissionProjectionStage.approvedAwaitingHandoff ||
      AdmissionProjectionStage.grantDelivered ||
      AdmissionProjectionStage.claimActive =>
        _empty(HubConfigStatus.waitingBinding, identity.fingerprint),
      AdmissionProjectionStage.claimRevoked =>
        _empty(HubConfigStatus.revoked, identity.fingerprint),
      AdmissionProjectionStage.rejected ||
      AdmissionProjectionStage.expired ||
      AdmissionProjectionStage.canceled =>
        _empty(HubConfigStatus.unregistered, identity.fingerprint),
    };
  }

  HubConfig _empty(HubConfigStatus status, String fingerprint) => HubConfig(
        status: status,
        session: const RoomConfig(
          serverUrl: '',
          token: '',
          identity: '',
          roomName: '',
        ),
        deviceFingerprint: fingerprint,
      );
}
