import '../../platform/platform_bridge.dart';
import '../device_setup/admission_authority_client.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/mobile_body_claim_store.dart';
import '../device_setup/mobile_body_enrollment.dart';
import '../device_setup/mobile_body_enrollment_session.dart';
import '../device_setup/mobile_body_enrollment_wiring.dart';
import '../host_setup/pinned_http_client.dart';
import 'conversation_flow.dart';
import 'mobile_device_contexts.dart';
import 'device_owner_directory.dart';
import 'mobile_conversation_provisioner.dart';

/// App-owned enrollment scope, not a Widget or Controller login session.
/// Each virtual Device belongs to one Owner Domain; the App can host several.
class MobileDeviceRuntime {
  MobileDeviceRuntime(
      {DeviceOwnerDirectory? directory,
      MobileBodyClaimStore? claims,
      PlatformBridge platform = const PlatformBridge(),
      MobileDeviceContexts? contexts})
      : directory = directory ?? DeviceOwnerDirectory(),
        _contexts = contexts ??
            MobileDeviceContexts(platform: platform, legacyClaims: claims);
  final DeviceOwnerDirectory directory;
  final MobileDeviceContexts _contexts;
  final Map<String, _DeviceScope> _scopes = {};
  Future<void> _opening = Future<void>.value();
  ConversationFlow? _active;
  int _openRevision = 0;

  Future<ConversationFlow> open(
      {required String hostId,
      required String hostName,
      required Future<DeviceOnboardingTarget> Function() bootstrap,
      required ConversationManagement management}) async {
    final revision = ++_openRevision;
    final target = await directory.open(hostId: hostId, bootstrap: bootstrap);
    // Serialize activation, including old RTC teardown. Device enrollment
    // sessions survive navigation in their own Owner scope.
    final opening = _opening.then((_) async {
      if (revision != _openRevision) {
        throw StateError('Host selection was superseded');
      }
      await _active?.close();
      if (revision != _openRevision) {
        throw StateError('Host selection was superseded');
      }
      _active = null;
      var scope = _scopes[target.ownerDomainId];
      if (scope == null) {
        final context = await _contexts.open(target.ownerDomainId);
        scope = _DeviceScope(target.ownerDomainId, management, context);
        _scopes[target.ownerDomainId] = scope;
        final current = scope;
        current.enrollment = MobileBodyEnrollmentSession(
            loadTarget: () => directory.load(current.ownerDomainId),
            claims: context.claims,
            rebindAdmission: (admission, t) => admission.useAuthority(
                AdmissionAuthorityClient(
                    authority: admissionAuthorityFor(t),
                    transport: PlatformPinnedHttpClient.ownerDomain(
                        ownerRootCertificate: t.ownerRootCertificate,
                        addressHints: t.addressHints))),
            platform: context.platform,
            buildAdmission: (t) => MobileBodyAdmission(
                issueVoucher: ({required operationalSpkiSha256}) =>
                    current.management.admission.issueCommissioningVoucher(
                        operationalSpkiSha256: operationalSpkiSha256),
                authority: AdmissionAuthorityClient(
                    authority: admissionAuthorityFor(t),
                    transport: PlatformPinnedHttpClient.ownerDomain(
                        ownerRootCertificate: t.ownerRootCertificate,
                        addressHints: t.addressHints)),
                claims: context.claims,
                platform: context.platform));
      } else {
        scope.management = management;
      }
      final current = scope;
      return _active = ConversationFlow(
          hostName: hostName,
          ownerDomainId: target.ownerDomainId,
          loadTarget: () => directory.load(current.ownerDomainId),
          enrollment: current.enrollment,
          management: management,
          platform: current.context.platform,
          provisioner: MobileConversationProvisioner(
              loadTarget: () => directory.load(current.ownerDomainId),
              admission: management.admission,
              claims: current.context.claims,
              currentEnrollmentId: () =>
                  current.enrollment.pending?.enrollmentId,
              resumeAcknowledgement: current.enrollment.resumeAcknowledgement,
              buildDeviceControl: deviceControlClientBuilder(),
              platform: current.context.platform));
    });
    _opening = opening.then<void>((_) {}, onError: (_, __) {});
    return opening;
  }
}

class _DeviceScope {
  _DeviceScope(this.ownerDomainId, this.management, this.context);
  final MobileDeviceContext context;
  final String ownerDomainId;
  ConversationManagement management;
  late final MobileBodyEnrollmentSession enrollment;
}
