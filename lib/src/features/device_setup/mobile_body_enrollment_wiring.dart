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

import 'package:http/http.dart' as http;
import '../conversation/device_control_client.dart';
import '../conversation/mobile_conversation_provisioner.dart';
import 'device_setup_models.dart';
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
DeviceControlClientBuilder deviceControlClientBuilder({
  required http.Client Function(DeviceOnboardingTarget) transport,
}) =>
    (target) => DeviceControlClient(
          authority: deviceControlAuthorityFor(target),
          transport: transport(target),
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
