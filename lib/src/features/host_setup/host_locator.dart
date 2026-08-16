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

/// What the Host itself said, while a phone stood next to it.
///
/// Last of all, and deliberately: reading it needs permission, a scan and a
/// connection, and it only pays off when everything cheaper found nothing —
/// which is exactly the case it exists for, a phone that has never connected
/// on a network that does not carry announcements.
class PublishedAddressSource implements HostAddressSource {
  const PublishedAddressSource(this._read);

  /// Reads this Host's signed endpoint over BLE. Whatever it returns has
  /// already proved it is this Host; the addresses are the part being used
  /// here, and each still has to answer and prove itself again.
  final Future<List<String>> Function(ManagedHost host) _read;

  @override
  HostAddressEvidence get evidence => HostAddressEvidence.published;

  @override
  Future<List<LocalApiEndpoint>> locate(ManagedHost host) async {
    final published = await _read(host);
    return published
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where((uri) => uri.scheme == 'https' && uri.host.isNotEmpty)
        .map(
          (uri) => LocalApiEndpoint(
            instanceName: 'published',
            baseUrl: uri.toString(),
            ipAddress: uri.host,
            contractVersion: '1',
          ),
        )
        .toList(growable: false);
  }
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
  factory HostLocator.standard(
    LocalApiDiscovery discovery, {
    Future<List<String>> Function(ManagedHost host)? readPublished,
  }) =>
      HostLocator([
        AnnouncedAddressSource(discovery),
        const RememberedAddressSource(),
        if (readPublished != null) PublishedAddressSource(readPublished),
      ]);

  final List<HostAddressSource> sources;

  /// Ask each means in turn, and stop asking as soon as one has something.
  ///
  /// Yielded a source at a time on purpose. Reading the Host's own statement
  /// costs a permission prompt, a scan and a connection; paying that when an
  /// announcement already answered would make every connection slower for the
  /// sake of a case that did not arise. The caller comes back for the next
  /// source only when nothing in this one could be reached — so a later source
  /// is never skipped, only deferred.
  Stream<List<HostAddressCandidate>> locate(ManagedHost host) async* {
    final seen = <String>{};
    Object? firstFailure;
    var offered = false;
    for (final source in sources) {
      final tier = <HostAddressCandidate>[];
      try {
        for (final endpoint in await source.locate(host)) {
          if (seen.add(endpoint.baseUrl)) {
            tier.add(
              HostAddressCandidate(
                endpoint: endpoint,
                evidence: source.evidence,
              ),
            );
          }
        }
      } catch (error) {
        firstFailure ??= error;
        continue;
      }
      if (tier.isEmpty) continue;
      offered = true;
      yield tier;
    }
    // Nothing anywhere had anything to offer, so the person is told what
    // actually went wrong rather than a summary of silence.
    if (!offered && firstFailure != null) throw firstFailure;
  }
}
