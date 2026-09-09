/// Assembling this phone's Enrollment from the parts the app already holds.
///
/// One place, because the assembly has a rule in it that is easy to get wrong
/// by hand: **the Authority's address and the trust anchor that reaches it come
/// from the same signed descriptor, read once.** The endpoint says where this
/// Owner Domain's Admission lives and the Owner root says who is allowed to
/// answer there; taken from two readings they can disagree, and the
/// disagreement presents as a TLS failure rather than as what it is.
///
/// Nothing here decides anything. The two acts a person takes are decided in
/// `mobile_body_enrollment_session.dart`, and the protocol is in
/// `mobile_body_enrollment.dart`.
library;

import '../host_setup/host_product_controller.dart';
import '../host_setup/pinned_http_client.dart';
import '../conversation/device_control_client.dart';
import '../conversation/mobile_conversation_provisioner.dart';
import 'admission_authority_client.dart';
import 'device_setup_models.dart';
import 'host_controller_device_admission.dart';
import 'mobile_body_claim_store.dart';
import 'mobile_body_enrollment.dart';
import 'mobile_body_enrollment_session.dart';
import 'owner_domain_endpoints.dart';

/// Raised when the directory names no endpoint for an authority this app needs.
///
/// Its own failure, not a network one. An Owner Domain that publishes no
/// endpoint for an authority is a real condition — a directory this build is
/// too old to read, or a deployment that does not run it — and reporting it as
/// unreachable would send someone to check their Wi-Fi.
///
/// Carries which authority, because there are two and they fail for different
/// reasons: no `admission` means this phone cannot propose itself, and no
/// `device-control` means a Body already claimed cannot ask for its channel.
class MissingOwnerDomainAuthority implements Exception {
  const MissingOwnerDomainAuthority({
    required this.ownerDomainId,
    required this.authority,
  });

  final String ownerDomainId;
  final String authority;

  @override
  String toString() =>
      'Owner Domain $ownerDomainId publishes no $authority authority';
}

/// The Enrollment session for the Host this Controller is connected to.
///
/// Returns null when the Controller has no Owner Domain yet. That is not an
/// error: a phone cannot propose itself to an Owner Domain that does not exist,
/// and a null session draws no control rather than a failing one.
MobileBodyEnrollmentSession buildMobileBodyEnrollment(
  HostProductController controller, {
  MobileBodyClaimStore? claims,
}) {
  final store = claims ?? PlatformMobileBodyClaimStore();
  return MobileBodyEnrollmentSession(
    loadTarget: controller.fetchDeviceOnboardingTarget,
    buildAdmission: (target) => MobileBodyAdmission(
      // The Controller half: the one thing here only an Owner may do is have
      // the Host sign this device's standing.
      issueVoucher:
          HostControllerDeviceAdmission(controller).issueCommissioningVoucher,
      authority: AdmissionAuthorityClient(
        authority: admissionAuthorityFor(target),
        // Pinned to the Owner Domain's own root, not to the Host's TLS leaf.
        // The Host is where the Controller session lives; the Authority is a
        // different party, and reaching it on the Host's pin would be trusting
        // the Host to speak for Hub.
        transport: PlatformPinnedHttpClient.ownerDomain(
          ownerRootCertificate: target.ownerRootCertificate,
          addressHints: target.addressHints,
        ),
      ),
      claims: store,
    ),
  );
}

/// Where this Owner Domain says its Admission authority answers.
///
/// Throws rather than returning a placeholder: every caller here is about to
/// send a proposal, and an address nobody publishes is not somewhere to try.
Uri admissionAuthorityFor(DeviceOnboardingTarget target) {
  return _requiredAuthority(target, admissionAuthorityName);
}

/// Builds the Device Control client for one reading of the directory.
///
/// Same rule as the Admission one, and for the same reason: the authority's
/// address and the trust anchor that reaches it are two facts from one signed
/// descriptor, and taken from separate readings they can disagree.
DeviceControlClientBuilder deviceControlClientBuilder() =>
    (target) => DeviceControlClient(
          authority: deviceControlAuthorityFor(target),
          transport: PlatformPinnedHttpClient.ownerDomain(
            ownerRootCertificate: target.ownerRootCertificate,
            addressHints: target.addressHints,
          ),
        );

/// Where this Owner Domain says its Device Control authority answers.
Uri deviceControlAuthorityFor(DeviceOnboardingTarget target) {
  return _requiredAuthority(target, deviceControlAuthorityName);
}

Uri _requiredAuthority(DeviceOnboardingTarget target, String authority) {
  final endpoint = ownerDomainAuthorityEndpoint(target, authority: authority);
  if (endpoint == null) {
    throw MissingOwnerDomainAuthority(
      ownerDomainId: target.ownerDomainId,
      authority: authority,
    );
  }
  return endpoint;
}
