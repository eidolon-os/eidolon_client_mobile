import 'dart:async';
import 'dart:io';

import '../setup/host_registry.dart';
import 'local_api_discovery.dart';

/// Resolve a host name to addresses, or return nothing if it will not resolve.
typedef HostAddressResolver = Future<List<String>> Function(String name);

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
/// The `.local` names this phone has learned for a Host, if any.
///
/// The name probe used to carry a name compiled into the App —
/// `eidolon-pi5.local`, the name the first board's image happened to have. One
/// App binary serves every household, and before a Host is claimed the phone
/// does not know which Host it is about to meet, so a build-time name is right
/// for one installation and dead weight for the rest: by the time this was
/// found the board in service answered to `orangepi5-max.local` and the
/// compiled-in name matched no Host at all.
///
/// A name is a way to learn an address, so it has to be learned too. What a
/// Host once answered on is evidence about *that* Host; a new household with no
/// history simply has none to offer, and the probe stands down while the browse
/// and the subnet sweep — neither of which needs a name — carry it.
List<String> hostNamesRemembered(ManagedHost host) {
  final names = <String>{};
  final remembered = Uri.tryParse(host.lastKnownBaseUrl ?? '')?.host ?? '';
  final hostname = host.machineInfo?.hostname.trim() ?? '';
  for (final name in [remembered, hostname]) {
    if (name.isEmpty || InternetAddress.tryParse(name) != null) continue;
    // Bare machine names are learned from the authenticated Host monitor.
    names.add(name.contains('.') ? name : '$name.local');
  }
  return names.toList(growable: false);
}

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

/// Whatever this network turns up right now, by every probe there is.
///
/// Only the addresses are taken here. The survey knows more — which probe was
/// silent, which could not run, what answered on another contract — and that
/// belongs to the flow that has a person in front of it, not to relocating a
/// Host that is already claimed.
class AnnouncedAddressSource implements HostAddressSource {
  const AnnouncedAddressSource(this._discovery);

  final LocalApiDiscovery _discovery;

  @override
  HostAddressEvidence get evidence => HostAddressEvidence.announced;

  @override
  Future<List<LocalApiEndpoint>> locate(ManagedHost host) async =>
      (await _discovery.discover()).endpoints;
}

/// Where a Host might be, from every means available.
///
/// Locating is a process that can be run again, not a value obtained once at
/// connection time. That distinction is the fix: an address is the most
/// perishable thing the App holds — a Host changes networks, a lease is
/// renewed, the phone itself moves — so the answer to "where is it" has to be
/// obtainable again at any moment, from whichever means still works.
class HostLocator {
  const HostLocator(this.sources, {HostAddressResolver? resolve})
      : _resolve = resolve ?? _lookup;

  /// Ordered by how fresh the evidence a source offers is. Order decides what
  /// is tried first, never what is tried at all.
  factory HostLocator.standard(
    LocalApiDiscovery discovery, {
    Future<List<String>> Function(ManagedHost host)? readPublished,
    HostAddressResolver? resolve,
  }) =>
      HostLocator(
        [
          AnnouncedAddressSource(discovery),
          const RememberedAddressSource(),
          if (readPublished != null) PublishedAddressSource(readPublished),
        ],
        resolve: resolve,
      );

  final List<HostAddressSource> sources;
  final HostAddressResolver _resolve;

  static Future<List<String>> _lookup(String name) async {
    try {
      final addresses = await InternetAddress.lookup(
        name,
        type: InternetAddressType.IPv4,
      );
      return addresses
          .map((address) => address.address)
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  /// A candidate the transport can actually dial, or nothing.
  ///
  /// The invariant this enforces, in the one place every tier passes through:
  /// **a name is a way to learn an address, never a way to address a Host.**
  /// The request goes out through the Android pinned transport, which resolves
  /// with getaddrinfo and therefore cannot resolve a `.local` name at all — so
  /// a candidate addressed by name is a candidate that fails on every Android
  /// phone regardless of whether the Host is up.
  ///
  /// Needed here and not only at the source that produced such names, because
  /// one of them was already written down: a `.local` base URL that once
  /// connected is persisted as `lastKnownBaseUrl` and offered again on every
  /// reconnect. Fixing the source stops new ones; this reaches the ones
  /// already on people's phones.
  ///
  /// A name that will not resolve yields nothing rather than an error. It is
  /// one lead removed, which is precisely what this class is built to survive.
  Future<LocalApiEndpoint?> _dialable(LocalApiEndpoint endpoint) async {
    final uri = Uri.tryParse(endpoint.baseUrl);
    if (uri == null || uri.host.isEmpty) return null;
    if (InternetAddress.tryParse(uri.host) != null) return endpoint;
    final resolved = await _resolve(uri.host);
    if (resolved.isEmpty) return null;
    final address = resolved.first;
    return LocalApiEndpoint(
      instanceName: endpoint.instanceName,
      baseUrl: uri.replace(host: address).toString(),
      ipAddress: address,
      contractVersion: endpoint.contractVersion,
    );
  }

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
        for (final offered in await source.locate(host)) {
          final endpoint = await _dialable(offered);
          if (endpoint == null) continue;
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
