import 'dart:async';

import 'package:http/http.dart' as http;

import '../host_setup/host_locator.dart';
import '../host_setup/local_api_candidate_sources.dart';
import '../host_setup/local_api_discovery.dart';
import '../host_setup/network_changes.dart';
import '../host_setup/pinned_http_client.dart';
import '../setup/host_registry.dart';
import 'device_setup_models.dart';

typedef OwnerTransportBuilder = http.Client Function(
    DeviceOnboardingTarget target, Map<String, String> addressHints);

class _Route {
  _Route(this.address, this.registryAddress, this.generation);
  final String address;
  final String? registryAddress;
  final int generation;
}

class _Lookup {
  _Lookup(this.registryAddress);
  final String? registryAddress;
  late Future<_Route> result;
  final clients = <http.Client>{};
  int readers = 0;
  bool cancelled = false;
}

/// Locations expire; Owner roots and signed authority names do not become IPs.
/// HostLocator supplies candidates. The existing Owner TLS verifier decides
/// which candidate may receive a Device request, without Controller login.
class OwnerAuthorityRoutes {
  OwnerAuthorityRoutes({
    HostRegistry? registry,
    NetworkChanges? networkChanges,
    LocalApiDiscovery? discovery,
    OwnerTransportBuilder? transport,
  })  : _registry = registry ?? PlatformHostRegistry(),
        _networkChanges = networkChanges ?? PlatformNetworkChanges(),
        _discovery = discovery,
        _transport = transport ??
            ((target, hints) => PlatformPinnedHttpClient.ownerDomain(
                ownerRootCertificate: target.ownerRootCertificate,
                addressHints: hints));

  final HostRegistry _registry;
  final NetworkChanges _networkChanges;
  final LocalApiDiscovery? _discovery;
  final OwnerTransportBuilder _transport;
  final _routes = <String, _Route>{};
  final _locating = <String, _Lookup>{};
  final _clients = <http.Client>{};
  StreamSubscription<void>? _subscription;
  int _generation = 0;
  bool _closed = false;

  http.Client client(DeviceOnboardingTarget target, String Function() hostId) =>
      _OwnerRoutedClient(this, target, hostId);

  void _check(int generation) {
    if (_closed || generation != _generation) {
      throw PinnedHttpException(
          kind: PinnedHttpFailureKind.cancelled,
          message: 'Owner service location changed');
    }
  }

  void _observeNetwork() {
    _subscription ??= _networkChanges.changes.listen((_) => invalidate());
  }

  void invalidate() {
    _generation++;
    _routes.clear();
    for (final lookup in _locating.values) {
      lookup.cancelled = true;
    }
    _locating.clear();
    for (final client in _clients.toList()) {
      _release(client);
    }
  }

  void _release(http.Client client) {
    if (_clients.remove(client)) client.close();
  }

  Future<_Route> _resolve(String hostId, DeviceOnboardingTarget target, Uri uri,
      Completer<void> cancelled) async {
    while (true) {
      final generation = _generation;
      try {
        return await _resolveOnce(hostId, target, uri, cancelled);
      } on PinnedHttpException catch (error) {
        if (error.kind != PinnedHttpFailureKind.cancelled ||
            _closed ||
            cancelled.isCompleted ||
            generation == _generation) {
          rethrow;
        }
        // Only location reads restart when the OS changes networks.
      }
    }
  }

  Future<_Route> _resolveOnce(String hostId, DeviceOnboardingTarget target,
      Uri uri, Completer<void> cancelled) async {
    _check(_generation);
    _observeNetwork();
    final generation = _generation;
    final host =
        (await _registry.load()).where((h) => h.hostId == hostId).firstOrNull;
    _check(generation);
    if (cancelled.isCompleted) {
      throw PinnedHttpException(
          kind: PinnedHttpFailureKind.cancelled,
          message: 'Owner request cancelled');
    }
    if (host == null) throw StateError('请从已保存的主机进入设备连接');
    final key = '$hostId|${target.ownerRootCertificate}|${uri.origin}';
    final cached = _routes[key];
    if (cached != null && cached.registryAddress == host.lastKnownBaseUrl) {
      return cached;
    }
    var lookup = _locating[key];
    if (lookup != null && lookup.registryAddress != host.lastKnownBaseUrl) {
      lookup.cancelled = true;
      for (final client in lookup.clients.toList()) {
        _release(client);
      }
      lookup = null;
    }
    if (lookup == null) {
      lookup = _Lookup(host.lastKnownBaseUrl);
      final pending = lookup;
      _locating[key] = pending;
      pending.result =
          _locate(host, target, uri, generation, pending).then((route) {
        _check(generation);
        if (!pending.cancelled) _routes[key] = route;
        return route;
      });
    }
    lookup.readers++;
    try {
      return await Future.any([
        lookup.result,
        cancelled.future.then<_Route>((_) => throw PinnedHttpException(
            kind: PinnedHttpFailureKind.cancelled,
            message: 'Owner request cancelled')),
      ]);
    } finally {
      lookup.readers--;
      if (lookup.readers == 0) {
        lookup.cancelled = true;
        for (final client in lookup.clients.toList()) {
          _release(client);
        }
        if (identical(_locating[key], lookup)) _locating.remove(key);
      }
    }
  }

  Future<_Route> _locate(ManagedHost host, DeviceOnboardingTarget target,
      Uri authority, int generation, _Lookup lookup) async {
    final discovery = _discovery ??
        platformLocalApiDiscovery(
            hostNames: {...hostNamesRemembered(host), authority.host});
    final locator = HostLocator([
      // The shared registry is the only durable address observation. Old
      // last_reached_address values in Owner directories are never consumed.
      const RememberedAddressSource(),
      AnnouncedAddressSource(discovery),
      PublishedAddressSource((_) async => [authority.origin]),
    ]);
    Object? failure;
    void check() {
      _check(generation);
      if (lookup.cancelled) {
        throw PinnedHttpException(
            kind: PinnedHttpFailureKind.cancelled,
            message: 'Owner location cancelled');
      }
    }

    await for (final tier in locator.locate(host)) {
      check();
      final race = await raceHostAddresses<String>(tier, (candidate) {
        final address = candidate.endpoint.ipAddress;
        final client = _transport(target, {authority.host: address});
        _clients.add(client);
        lookup.clients.add(client);
        final result = () async {
          try {
            // Only a body-free public probe is raced. Even a 404 proves the
            // signed origin via Owner root + hostname TLS verification.
            await client
                .head(Uri.parse('${authority.origin}/'))
                .timeout(const Duration(seconds: 8));
            check();
            return address;
          } finally {
            lookup.clients.remove(client);
            _release(client);
          }
        }();
        return HostAddressAttempt(result, () => _release(client));
      });
      check();
      if (race.winner != null) {
        return _Route(race.winner!, host.lastKnownBaseUrl, generation);
      }
      for (final rejected in race.failures) {
        failure = rejected.error;
      }
    }
    if (failure != null) throw failure;
    throw PinnedHttpException(
        kind: PinnedHttpFailureKind.unreachable,
        message: '当前网络无法定位此 Owner 的设备服务',
        uri: authority);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    invalidate();
    await _subscription?.cancel();
    await _networkChanges.close();
  }
}

/// One request-time route for directory renewal, Admission and Device Control.
/// The original URL, body, signature and trust root are never rewritten.
class _OwnerRoutedClient extends http.BaseClient {
  _OwnerRoutedClient(this.routes, this.target, this.hostId);
  final OwnerAuthorityRoutes routes;
  final DeviceOnboardingTarget target;
  final String Function() hostId;
  final _active = <http.Client>{};
  final _requests = <Completer<void>>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cancelled = Completer<void>();
    _requests.add(cancelled);
    try {
      return await _send(request, cancelled)
          .timeout(const Duration(seconds: 20), onTimeout: () {
        throw PinnedHttpException(
            kind: PinnedHttpFailureKind.timeout,
            message: 'Owner service request timed out',
            uri: request.url);
      });
    } finally {
      _requests.remove(cancelled);
      if (!cancelled.isCompleted) cancelled.complete();
    }
  }

  Future<http.StreamedResponse> _send(
      http.BaseRequest request, Completer<void> cancelled) async {
    if (_closed || cancelled.isCompleted) {
      throw http.ClientException('Owner request cancelled', request.url);
    }
    final allowed = [
      Uri.parse(target.ownerDomainDescriptor.descriptorUri),
      ...target.ownerDomainDescriptor.endpoints.map((e) => e.uri)
    ];
    if (request.url.scheme != 'https' ||
        !allowed.any((uri) => uri.origin == request.url.origin)) {
      throw PinnedHttpException(
          kind: PinnedHttpFailureKind.invalidRequest,
          message:
              'Owner request must use an authority from the signed directory',
          uri: request.url);
    }
    routes._observeNetwork();
    final selectedHost = hostId();
    final local = request.url.host.endsWith('.local');
    final route = local
        ? await routes._resolve(selectedHost, target, request.url, cancelled)
        : null;
    if (_closed || cancelled.isCompleted) {
      throw http.ClientException('Owner request cancelled', request.url);
    }
    final generation = route?.generation ?? routes._generation;
    routes._check(generation);
    if (hostId() != selectedHost) {
      throw PinnedHttpException(
          kind: PinnedHttpFailureKind.cancelled,
          message: 'Selected Host changed',
          uri: request.url);
    }
    final client = routes._transport(
        target, route == null ? const {} : {request.url.host: route.address});
    _active.add(client);
    routes._clients.add(client);
    unawaited(cancelled.future.then((_) => routes._release(client)));
    try {
      // Send the Device act exactly once. Only discovery probes can race.
      final response = await client.send(request);
      final bytes = await response.stream.toBytes();
      routes._check(generation);
      if (_closed || cancelled.isCompleted || hostId() != selectedHost) {
        throw PinnedHttpException(
            kind: PinnedHttpFailureKind.cancelled,
            message: 'Selected Host changed',
            uri: request.url);
      }
      return http.StreamedResponse(Stream.value(bytes), response.statusCode,
          headers: response.headers,
          reasonPhrase: response.reasonPhrase,
          request: request,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection);
    } on Object {
      if (route != null) {
        routes._routes.removeWhere((_, value) => identical(value, route));
      }
      rethrow;
    } finally {
      _active.remove(client);
      routes._release(client);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    for (final client in _active.toList()) {
      routes._release(client);
    }
    _active.clear();
    super.close();
  }
}
