import 'dart:async';

import '../setup/host_registry.dart';
import 'local_api_discovery.dart';

/// How a candidate address came to be known.
///
/// Kept because it says how fresh the evidence is, and because a person asking
/// why their Host cannot be reached deserves to know what was tried.
enum HostAddressEvidence {
  /// The Host answered an announcement just now.
  announced,

  /// The Host published this while the phone stood next to it.
  published,

  /// The Host answered here last time.
  remembered,
}

class HostAddressCandidate {
  const HostAddressCandidate({
    required this.endpoint,
    required this.evidence,
  });

  final LocalApiEndpoint endpoint;
  final HostAddressEvidence evidence;
}

/// One way of learning where a Host is.
///
/// Every source may return nothing, and none is required. A source that finds
/// nothing has removed one lead, not failed the search — which is the whole
/// point: multicast going quiet on one network must not make a claimed Host
/// unreachable.
abstract interface class HostAddressSource {
  HostAddressEvidence get evidence;

  Future<List<LocalApiEndpoint>> locate(ManagedHost host);
}

/// Where this Host answered last time.
class RememberedAddressSource implements HostAddressSource {
  const RememberedAddressSource();

  @override
  HostAddressEvidence get evidence => HostAddressEvidence.remembered;

  @override
  Future<List<LocalApiEndpoint>> locate(ManagedHost host) async {
    final remembered = host.lastKnownBaseUrl;
    if (remembered == null) return const [];
    final uri = Uri.tryParse(remembered);
    if (uri == null || uri.host.isEmpty) return const [];
    return [
      LocalApiEndpoint(
        instanceName: 'remembered',
        baseUrl: remembered,
        ipAddress: uri.host,
        contractVersion: '1',
      ),
    ];
  }
}

/// Whoever answers the announcement on this network.
class AnnouncedAddressSource implements HostAddressSource {
  const AnnouncedAddressSource(this._discovery);

  final LocalApiDiscovery _discovery;

  @override
  HostAddressEvidence get evidence => HostAddressEvidence.announced;

  @override
  Future<List<LocalApiEndpoint>> locate(ManagedHost host) =>
      _discovery.discover();
}

/// Where a Host might be, from every means available.
///
/// Locating is a process that can be run again, not a value obtained once at
/// connection time. That distinction is the fix: an address is the most
/// perishable thing the App holds — a Host changes networks, a lease is
/// renewed, the phone itself moves — so the answer to "where is it" has to be
/// obtainable again at any moment, from whichever means still works.
class HostLocator {
  const HostLocator(this.sources);

  /// Ordered by how fresh the evidence a source offers is. Order decides what
  /// is tried first, never what is tried at all.
  factory HostLocator.standard(LocalApiDiscovery discovery) => HostLocator([
        AnnouncedAddressSource(discovery),
        const RememberedAddressSource(),
      ]);

  final List<HostAddressSource> sources;

  /// Every address worth trying, best evidence first, without duplicates.
  ///
  /// A source that throws is a lead that did not pan out. Only when nothing at
  /// all was learned does the first failure travel on, so the person is told
  /// what actually went wrong rather than a summary of silence.
  Future<List<HostAddressCandidate>> locate(ManagedHost host) async {
    final candidates = <String, HostAddressCandidate>{};
    Object? firstFailure;
    for (final source in sources) {
      try {
        for (final endpoint in await source.locate(host)) {
          candidates.putIfAbsent(
            endpoint.baseUrl,
            () => HostAddressCandidate(
              endpoint: endpoint,
              evidence: source.evidence,
            ),
          );
        }
      } catch (error) {
        firstFailure ??= error;
      }
    }
    if (candidates.isEmpty && firstFailure != null) throw firstFailure;
    return candidates.values.toList(growable: false);
  }
}
