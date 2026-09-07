/// Where an Owner Domain's authorities actually live.
///
/// The signed descriptor is the answer, and nothing else is: a reachable
/// address is not an authority, and a Host that offered one would be naming
/// somebody else's Hub. So resolution reads the directory this app verified,
/// picks the entry for the authority it wants, and prefers the lowest priority
/// value the directory published.
///
/// One function, because the rule is one rule. It was inline in the conversation
/// provisioner, which was correct and unreachable; the moment a second caller
/// needed an endpoint the cheap move was to write the same four lines again,
/// and then two callers would disagree about what "first" means the day a
/// descriptor lists two entries at the same priority.
library;

import '../../generated/device_foundation_v1.dart';
import 'device_setup_models.dart';

/// The `admission` authority: where a device proposes itself.
const admissionAuthorityName = 'admission';

/// The `device-control` authority: where a Body pulls its configuration.
const deviceControlAuthorityName = 'device-control';

/// The endpoint [target] publishes for [authority], or null if it publishes none.
///
/// Null rather than a placeholder. A descriptor without the authority a caller
/// needs is a real condition — an Owner Domain that does not run it, or a
/// directory this app is too old to read — and it deserves a sentence naming
/// which authority is missing, not a request to an address that cannot answer.
Uri? ownerDomainAuthorityEndpoint(
  DeviceOnboardingTarget target, {
  required String authority,
}) {
  final matching = target.ownerDomainDescriptor.endpoints
      .where((endpoint) => endpoint.authority == authority)
      .toList(growable: false)
    // Lowest priority value first, as the directory means it. `sort` is stable
    // in Dart, so entries that tie keep the order the descriptor published —
    // which is the only tie-break the directory actually expresses.
    ..sort((left, right) => left.priority.compareTo(right.priority));
  return matching.isEmpty ? null : matching.first.uri;
}

/// Every endpoint published for [authority], in the order they should be tried.
///
/// Exposed alongside the single answer because a directory may list more than
/// one, and a caller that can fail over should be able to — without inventing
/// its own idea of the order.
List<AuthorityEndpointV1> ownerDomainAuthorityEndpoints(
  DeviceOnboardingTarget target, {
  required String authority,
}) {
  return target.ownerDomainDescriptor.endpoints
      .where((endpoint) => endpoint.authority == authority)
      .toList(growable: false)
    ..sort((left, right) => left.priority.compareTo(right.priority));
}
