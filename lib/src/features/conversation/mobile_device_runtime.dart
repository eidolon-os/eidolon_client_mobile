import '../../platform/platform_bridge.dart';
import '../device_setup/admission_authority_client.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/mobile_body_claim_store.dart';
import '../device_setup/mobile_body_enrollment.dart';
import '../device_setup/mobile_body_enrollment_session.dart';
import '../device_setup/mobile_body_enrollment_wiring.dart';
import '../host_setup/pinned_http_client.dart';
import 'conversation_flow.dart';
import 'device_owner_directory.dart';
import 'mobile_conversation_provisioner.dart';

class MobileDeviceOwnerConflict implements Exception {
  const MobileDeviceOwnerConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

/// App-owned enrollment scope, not a Widget or Controller login session.
/// V1 permits one Owner Domain for this virtual Device.
class MobileDeviceRuntime {
  MobileDeviceRuntime(
      {DeviceOwnerDirectory? directory,
      MobileBodyClaimStore? claims,
      PlatformBridge platform = const PlatformBridge()})
      : directory = directory ?? DeviceOwnerDirectory(),
        claims = claims ?? PlatformMobileBodyClaimStore(),
        _platform = platform;
  final DeviceOwnerDirectory directory;
  final MobileBodyClaimStore claims;
  final PlatformBridge _platform;
  _DeviceScope? _scope;

  Future<ConversationFlow> open(
      {required String hostId,
      required String hostName,
      required Future<DeviceOnboardingTarget> Function() bootstrap,
      required ConversationManagement management}) async {
    final target = await directory.open(hostId: hostId, bootstrap: bootstrap);
    final identity = await _platform.getDeviceIdentity();
    final held = await claims.loadFor(identity.operationalPublicKey);
    if (held != null && held.ownerDomainId != target.ownerDomainId) {
      throw const MobileDeviceOwnerConflict(
          '本机属于另一位 Owner，请返回并选择原主机。若要更换归属，需要先完成标准设备转移。');
    }
    var scope = _scope;
    if (scope != null &&
        scope.ownerDomainId != target.ownerDomainId &&
        scope.enrollment.hasInFlightOperation) {
      throw const MobileDeviceOwnerConflict(
          '本机仍有另一位 Owner 的登记待处理，请返回原主机完成或撤回。');
    }
    if (scope == null || scope.ownerDomainId != target.ownerDomainId) {
      scope = _DeviceScope(target.ownerDomainId, management);
      _scope = scope;
      final current = scope;
      current.enrollment = MobileBodyEnrollmentSession(
          loadTarget: () => directory.load(current.ownerDomainId),
          claims: claims,
          rebindAdmission: (admission, t) => admission.useAuthority(
              AdmissionAuthorityClient(
                  authority: admissionAuthorityFor(t),
                  transport: PlatformPinnedHttpClient.ownerDomain(
                      ownerRootCertificate: t.ownerRootCertificate))),
          platform: _platform,
          buildAdmission: (t) => MobileBodyAdmission(
              issueVoucher: ({required operationalSpkiSha256}) =>
                  current.management.admission.issueCommissioningVoucher(
                      operationalSpkiSha256: operationalSpkiSha256),
              authority: AdmissionAuthorityClient(
                  authority: admissionAuthorityFor(t),
                  transport: PlatformPinnedHttpClient.ownerDomain(
                      ownerRootCertificate: t.ownerRootCertificate)),
              claims: claims,
              platform: _platform));
    } else {
      scope.management = management;
    }
    final current = scope;
    return ConversationFlow(
        hostName: hostName,
        ownerDomainId: target.ownerDomainId,
        loadTarget: () => directory.load(current.ownerDomainId),
        enrollment: current.enrollment,
        management: management,
        platform: _platform,
        provisioner: MobileConversationProvisioner(
            loadTarget: () => directory.load(current.ownerDomainId),
            admission: management.admission,
            claims: claims,
            currentEnrollmentId: () => current.enrollment.pending?.enrollmentId,
            resumeAcknowledgement: current.enrollment.resumeAcknowledgement,
            buildDeviceControl: deviceControlClientBuilder(),
            platform: _platform));
  }
}

class _DeviceScope {
  _DeviceScope(this.ownerDomainId, this.management);
  final String ownerDomainId;
  ConversationManagement management;
  late final MobileBodyEnrollmentSession enrollment;
}
