import 'dart:async';

import 'package:flutter/services.dart';

import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_identity.dart';
import '../setup/host_registry.dart';
import '../setup/setup_models.dart';
import '../setup/setup_trust.dart';
import 'controller_session.dart';
import 'host_locator.dart';
import 'host_models.dart';
import '../../management/management_client.dart';
import 'local_api_candidate_sources.dart';
import 'local_api_client.dart';
import 'local_api_discovery.dart';
import 'pinned_http_client.dart';

/// A Host that answered at one of its addresses and proved it was itself.
///
/// Carries the client that reached it, still open. Authenticating over the
/// connection that just worked is both one fewer client and one fewer thing
/// that can differ between proving where the Host is and talking to it.
class _ReachedHost {
  const _ReachedHost(this.endpoint, this.overview, this.client);

  final LocalApiEndpoint endpoint;
  final HostOverview overview;
  final LocalApiClient client;
}

class HostLocationException extends LocalApiRequestException {
  HostLocationException(List<HostCandidateFailure> failures)
      : failures = List.unmodifiable(failures),
        super(_describe(failures));

  final List<HostCandidateFailure> failures;

  static String _describe(List<HostCandidateFailure> failures) {
    final fresh = failures
        .where((f) => f.candidate.evidence != HostAddressEvidence.remembered)
        .toList();
    final relevant = fresh.isNotEmpty ? fresh : failures;
    if (relevant.isEmpty) return '当前网络未发现主机地址，可检查网络后重新查找。';
    if (relevant.any((f) =>
        f.error is TimeoutException ||
        f.error is PinnedHttpException &&
            (f.error as PinnedHttpException).kind ==
                PinnedHttpFailureKind.timeout)) {
      return fresh.isNotEmpty
          ? '已发现局域网服务，但连接超时 · 重新查找'
          : '上次连接地址超时，当前网络未确认新地址 · 重新查找';
    }
    if (relevant.every((f) =>
        f.error is SetupTrustException ||
        f.error is PinnedHttpException &&
            (f.error as PinnedHttpException).kind ==
                PinnedHttpFailureKind.secureChannel)) {
      return '发现的服务未通过这台主机的身份校验 · 重新查找';
    }
    if (relevant.any((f) =>
        f.error is PinnedHttpException &&
        {PinnedHttpFailureKind.unreachable, PinnedHttpFailureKind.io}
            .contains((f.error as PinnedHttpException).kind))) {
      return '已获得地址，但当前网络连接失败 · 重新查找';
    }
    return '未能完成主机连接验证 · 重新查找';
  }
}

typedef LocalApiClientFactory = LocalApiClient Function(String fingerprint);

/// The management boundary gets its own factory for the same reason the client
/// is a separate class: it is generated from a shared contract rather than
/// hand-written here. Both factories produce clients over the *same* pinned
/// transport — a management call that skipped the pin would be a second, weaker
/// way into the same Host.
typedef ManagementClientFactory = ManagementClient Function(String fingerprint);
typedef HostConnectionProgress = void Function(String message);
typedef LocalApiOperation<T> = Future<T> Function(
  LocalApiClient client,
  String baseUrl,
  String accessToken,
);

typedef ManagementOperation<T> = Future<T> Function(
  ManagementClient client,
  Uri baseUri,
  String accessToken,
);

class HostControllerAuthorizationException implements Exception {
  const HostControllerAuthorizationException(
    this.message, {
    this.reclaimRequired = false,
  });

  final String message;

  /// Whether reconnecting could ever succeed.
  ///
  /// A session that merely lapsed comes back on the next connect. A Grant the
  /// Host has revoked does not: authenticating is exactly what fails, so the
  /// only way back is to be claimed again. Saying which of the two this is has
  /// to travel with the refusal, because by the time a screen has only a
  /// message it can offer nothing but a retry — and a retry here is a promise
  /// this Host cannot keep.
  final bool reclaimRequired;

  @override
  String toString() => message;
}

class HostProductConnection {
  const HostProductConnection({
    required this.endpoint,
    required this.overview,
    required this.controllerId,
    required this.sessionExpiresAt,
  });

  final LocalApiEndpoint endpoint;
  final HostOverview overview;
  final String controllerId;
  final DateTime sessionExpiresAt;
}

/// Owns the authenticated, Host-pinned Local API boundary for one saved Host.
///
/// The session deliberately exposes only a safe connection projection. Bearer
/// tokens stay inside this object and are supplied only to typed repositories.
class HostProductSession {
  HostProductSession({
    required ManagedHost host,
    CommissioningTransport? transport,
    ControllerKeyBridge? controllerKeys,
    LocalApiDiscovery? discovery,
    LocalApiClientFactory? clientFactory,
    ManagementClientFactory? managementClientFactory,
    HostLocator? locator,
    this.onHostConnected,
  })  : _host = host,
        _transport = transport ?? PlatformBleCommissioningTransport(),
        _controllerKeys = controllerKeys ?? PlatformControllerKeyBridge(),
        _clientFactory = clientFactory ?? _platformClientFactory,
        _managementClientFactory =
            managementClientFactory ?? _platformManagementClientFactory {
    // Built here rather than in the initializer list because the last resort
    // is this session's own BLE read: when nothing on the network answered,
    // the Host is asked directly where it is.
    _locator = locator ??
        HostLocator.standard(
          discovery ??
              platformLocalApiDiscovery(hostNames: hostNamesRemembered(host)),
          readPublished: (_) async => _allowBle
              ? (await _readEndpointOverBle()).localApiBaseUrls
              : const [],
        );
  }

  /// One publication point for explicit connects and automatic relocation.
  Future<void> Function(ManagedHost host)? onHostConnected;
  Future<ManagedHost>? _connecting;
  bool _allowBle = true;
  int _networkRevision = 0;

  ManagedHost _host;
  final CommissioningTransport _transport;
  final ControllerKeyBridge _controllerKeys;
  late final HostLocator _locator;
  final LocalApiClientFactory _clientFactory;
  final ManagementClientFactory _managementClientFactory;

  LocalApiEndpoint? _endpoint;
  HostOverview? _overview;
  LocalControllerSession? _controllerSession;
  bool _closed = false;
  final _closedSignal = Completer<void>();
  final _clientClosers = <void Function()>{};

  LocalApiClient _newLocalClient() {
    _ensureOpen();
    final client = _clientFactory(_host.tlsSpkiFingerprint!);
    _clientClosers.add(client.close);
    return client;
  }

  ManagementClient _newManagementClient() {
    _ensureOpen();
    final client = _managementClientFactory(_host.tlsSpkiFingerprint!);
    _clientClosers.add(client.close);
    return client;
  }

  void _release(void Function() close) {
    if (_clientClosers.remove(close)) close();
  }

  void _cancelRequests() {
    for (final close in _clientClosers.toList()) {
      _release(close);
    }
  }

  void _ensureRevision(int revision) {
    _ensureOpen();
    if (revision != _networkRevision) {
      throw PinnedHttpException(
          kind: PinnedHttpFailureKind.cancelled,
          message: 'Network changed during Host location');
    }
  }

  /// Whether where the Host was has stopped being something we may assume.
  ///
  /// Distinct from never having connected. Nothing about the Host changed —
  /// this phone moved — so the next operation looks again instead of either
  /// refusing or paying a timeout to discover what is already known.
  bool _locationStale = false;

  ManagedHost get host => _host;

  HostProductConnection? get connection {
    final endpoint = _endpoint;
    final overview = _overview;
    final session = _controllerSession;
    if (endpoint == null || overview == null || session == null) return null;
    return HostProductConnection(
      endpoint: endpoint,
      overview: overview,
      controllerId: session.controllerId,
      sessionExpiresAt: session.expiresAt,
    );
  }

  Future<ManagedHost> connect(
      {HostConnectionProgress? onProgress, bool allowBle = true}) {
    _ensureOpen();
    if (_connecting != null) return _connecting!;
    _allowBle = allowBle;
    return _connecting = Future.any<ManagedHost>([
      _connectCurrentNetwork(onProgress),
      _closedSignal.future.then<ManagedHost>(
          (_) => throw StateError('Host product session is closed')),
    ]).whenComplete(() {
      _connecting = null;
    });
  }

  Future<ManagedHost> _connectCurrentNetwork(
      HostConnectionProgress? progress) async {
    while (true) {
      final revision = _networkRevision;
      final observedAt = DateTime.now().toUtc();
      try {
        final host = await _connectOnce(onProgress: progress);
        _ensureOpen();
        if (revision != _networkRevision) continue;
        _locationStale = false;
        _host = host.copyWith(lastConnectedAt: observedAt);
        await onHostConnected?.call(_host);
        if (revision != _networkRevision) continue;
        return _host;
      } catch (_) {
        _ensureOpen();
        if (revision != _networkRevision) continue;
        rethrow;
      }
    }
  }

  Future<ManagedHost> _connectOnce({HostConnectionProgress? onProgress}) async {
    _ensureOpen();
    _clearConnection();
    if (_host.tlsSpkiFingerprint == null) {
      if (!_allowBle) throw LocalApiRequestException('需要靠近主机，点击连接以确认主机身份');
      onProgress?.call('正在从附近主机更新本地连接信任');
      final trusted = await _readTlsIdentityOverBle();
      _ensureOpen();
      _host = trusted;
    }

    onProgress?.call('正在连接主机');
    final revision = _networkRevision;
    final failures = <HostCandidateFailure>[];
    // Known addresses and discovery feed the same read-only race. Only after
    // every network candidate failed do we repeat transient probes once or
    // consult the existing BLE fallback. Authentication is never raced.
    Future<HostAddressRace<_ReachedHost>> probe(
      List<HostAddressCandidate> candidates, {
      Stream<List<HostAddressCandidate>>? incoming,
    }) async {
      var result = await _firstToAnswer(candidates, incoming: incoming);
      _ensureRevision(revision);
      failures.addAll(result.failures);
      if (result.winner != null) return result;
      final retryable = [
        for (final failure in result.failures)
          if (failure.error is TimeoutException ||
              failure.error is PinnedHttpException &&
                  _hostDidNotAnswer(failure.error as PinnedHttpException))
            failure.candidate,
      ];
      if (retryable.isNotEmpty) {
        onProgress?.call('连接暂时未完成，正在重试');
        _ensureRevision(revision);
        result = await _firstToAnswer(retryable);
        _ensureRevision(revision);
        failures.addAll(result.failures);
      }
      return result;
    }

    Object? sourceFailure;
    var race = const HostAddressRace<_ReachedHost>(null, []);
    try {
      race = await probe(const [], incoming: _locator.locateNetwork(_host));
    } catch (error) {
      _ensureRevision(revision);
      sourceFailure = error;
    }
    if (race.winner == null && _allowBle) {
      onProgress?.call('正在重新定位主机地址');
      try {
        await for (final tier in _locator.locatePublished(_host)) {
          _ensureRevision(revision);
          // Already checked network addresses do not acquire a second budget
          // merely because BLE publishes them too.
          final fresh = tier
              .where((candidate) => !failures.any((failure) =>
                  failure.candidate.endpoint.baseUrl ==
                  candidate.endpoint.baseUrl))
              .toList();
          race = await probe(fresh);
          if (race.winner != null) break;
        }
      } catch (error) {
        _ensureRevision(revision);
        sourceFailure ??= error;
      }
    }
    final winner = race.winner;
    if (winner != null) {
      final endpoint = winner.endpoint;
      final client = winner.client;
      try {
        onProgress?.call('正在验证管理授权');
        final controllerSession = await _authenticate(
          client,
          endpoint,
          winner.overview,
        );
        _ensureRevision(revision);
        _endpoint = endpoint;
        _overview = winner.overview;
        _controllerSession = controllerSession;
        if (_host.lastKnownBaseUrl != endpoint.baseUrl) {
          _host = _host.copyWith(lastKnownBaseUrl: endpoint.baseUrl);
        }
        return _host;
      } catch (_) {
        // The Host answered and then refused, which decides this attempt.
        // Trying the same Host again at another of its own addresses would
        // ask it the same question and get the same answer.
        rethrow;
      } finally {
        _release(client.close);
      }
    }
    if (failures.isEmpty && sourceFailure != null) throw sourceFailure;
    throw HostLocationException(failures);
  }

  /// Runs a typed Local API operation, recovering once from either of the two
  /// things that go stale on their own: the session, and the address.
  ///
  /// A Host that answered and refused has decided something, and that travels
  /// straight back. A Host that did not answer at all has decided nothing —
  /// it moved, or this phone did — so the address is found again and the
  /// operation is retried, which is the whole of "the network changed" as far
  /// as the person is concerned.
  Future<T> execute<T>(LocalApiOperation<T> operation) async {
    _ensureOpen();
    if (_locationStale) await _relocate();
    final endpoint = _endpoint;
    final session = _controllerSession;
    if (endpoint == null || session == null) {
      throw const HostControllerAuthorizationException('请先安全连接主机');
    }
    try {
      return await _executeOnce(operation, endpoint, session);
    } on LocalApiRequestException catch (error) {
      if (error.statusCode != 401) rethrow;
      await _reauthenticate();
      return _executeOnce(operation, _endpoint!, _controllerSession!);
    } on PinnedHttpException catch (error) {
      if (!_hostDidNotAnswer(error)) rethrow;
      await _relocate();
      return _executeOnce(operation, _endpoint!, _controllerSession!);
    }
  }

  /// The same conversation, over the management contract.
  ///
  /// Deliberately the same recovery as [execute]: an expired session is
  /// re-authenticated in place and a Host that moved is looked for again,
  /// because which contract a call happens to use is not something the person
  /// holding the phone should have to know about.
  Future<T> executeManagement<T>(ManagementOperation<T> operation) async {
    _ensureOpen();
    if (_locationStale) await _relocate();
    final endpoint = _endpoint;
    final session = _controllerSession;
    if (endpoint == null || session == null) {
      throw const HostControllerAuthorizationException('请先安全连接主机');
    }
    try {
      return await _managementOnce(operation, endpoint, session);
    } on ManagementRequestException catch (error) {
      if (error.statusCode != 401) rethrow;
      await _reauthenticate();
      return _managementOnce(operation, _endpoint!, _controllerSession!);
    } on PinnedHttpException catch (error) {
      if (!_hostDidNotAnswer(error)) rethrow;
      await _relocate();
      return _managementOnce(operation, _endpoint!, _controllerSession!);
    }
  }

  Future<T> _managementOnce<T>(
    ManagementOperation<T> operation,
    LocalApiEndpoint endpoint,
    LocalControllerSession session,
  ) async {
    final client = _newManagementClient();
    try {
      return await operation(
        client,
        LocalApiClient.parseBaseUri(endpoint.baseUrl),
        session.accessToken,
      );
    } finally {
      _release(client.close);
    }
  }

  Future<HostAddressRace<_ReachedHost>> _firstToAnswer(
    List<HostAddressCandidate> tier, {
    Stream<List<HostAddressCandidate>>? incoming,
  }) async {
    final revision = _networkRevision;
    final cancelled = Completer<void>();
    void cancel() {
      if (!cancelled.isCompleted) cancelled.complete();
    }

    _clientClosers.add(cancel);
    try {
      return await raceHostAddresses(tier, (candidate) {
        _ensureRevision(revision);
        final client = _newLocalClient();
        final result =
            client.fetchHost(candidate.endpoint.baseUrl).then((overview) {
          _ensureRevision(revision);
          _verifyHost(overview);
          return _ReachedHost(candidate.endpoint, overview, client);
        });
        return HostAddressAttempt(result, () => _release(client.close));
      }, incoming: incoming, cancelled: cancelled.future);
    } finally {
      _release(cancel);
    }
  }

  static bool _hostDidNotAnswer(PinnedHttpException error) =>
      switch (error.kind) {
        PinnedHttpFailureKind.unreachable ||
        PinnedHttpFailureKind.timeout ||
        PinnedHttpFailureKind.io =>
          true,
        _ => false,
      };

  /// Find this Host again and re-establish the conversation, in place.
  ///
  /// Nothing above this layer learns that it happened: repositories never held
  /// an address, and the operation they asked for is simply carried out.
  Future<void> _relocate() async {
    _locationStale = true;
    await connect();
  }

  /// Forget where the Host was, without touching who it is.
  ///
  /// Called when this phone's own connectivity changed: the address may still
  /// be correct, but nothing about it can be assumed any more, and paying one
  /// timeout to discover that is worse than looking again.
  void invalidateLocation() {
    _networkRevision += 1;
    _cancelRequests();
    if (_endpoint == null && !_locationStale) return;
    _endpoint = null;
    _overview = null;
    _controllerSession = null;
    // Marked rather than merely cleared. Cleared alone is indistinguishable
    // from never having connected, and the next operation would refuse with
    // "请先安全连接主机" — turning a saving into a wall.
    _locationStale = true;
  }

  Future<T> _executeOnce<T>(
    LocalApiOperation<T> operation,
    LocalApiEndpoint endpoint,
    LocalControllerSession session,
  ) async {
    final client = _newLocalClient();
    try {
      return await operation(client, endpoint.baseUrl, session.accessToken);
    } finally {
      _release(client.close);
    }
  }

  Future<void> _reauthenticate() async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const HostControllerAuthorizationException('请重新连接主机');
    }
    final client = _newLocalClient();
    try {
      final overview = await client.fetchHost(endpoint.baseUrl);
      _verifyHost(overview);
      final session = await _authenticate(client, endpoint, overview);
      _overview = overview;
      _controllerSession = session;
    } on HostControllerAuthorizationException {
      _clearConnection();
      rethrow;
    } on LocalApiRequestException catch (error) {
      _clearConnection();
      throw HostControllerAuthorizationException(
        error.statusCode == 401 ||
                error.statusCode == 403 ||
                error.statusCode == 404 ||
                error.statusCode == 409
            ? '主机已重置或不再授权这台管理设备。$controllerResetGuidance'
            : '管理会话已失效，且暂时无法重新认证。请重新连接主机。',
        reclaimRequired: error.statusCode == 401 ||
            error.statusCode == 403 ||
            error.statusCode == 404 ||
            error.statusCode == 409,
      );
    } on SetupTrustException catch (error) {
      _clearConnection();
      throw HostControllerAuthorizationException(error.message);
    } on PinnedHttpException {
      _clearConnection();
      throw const HostControllerAuthorizationException(
        '管理会话已失效，且当前网络无法完成重新认证。请重新连接主机。',
      );
    } on FormatException {
      _clearConnection();
      throw const HostControllerAuthorizationException(
        '管理会话已失效，主机返回的重新认证数据不兼容。',
      );
    } finally {
      _release(client.close);
    }
  }

  Future<LocalControllerSession> _authenticate(
    LocalApiClient client,
    LocalApiEndpoint endpoint,
    HostOverview overview,
  ) async {
    try {
      final session = await client.authenticateController(
        endpoint.baseUrl,
        expectedControllerId: _host.controllerId,
        controllerKeys: _controllerKeys,
      );
      if (session.resetEpoch != overview.state.resetEpoch) {
        throw const HostControllerAuthorizationException(
          '主机状态与管理授权的 Reset epoch 不一致，已拒绝建立会话。',
        );
      }
      return session;
    } on LocalApiRequestException catch (error) {
      if (error.statusCode == 401 ||
          error.statusCode == 403 ||
          error.statusCode == 404 ||
          error.statusCode == 409) {
        throw const HostControllerAuthorizationException(
          '主机已重置或不再授权这台管理设备。$controllerResetGuidance',
          reclaimRequired: true,
        );
      }
      rethrow;
    }
  }

  Future<ManagedHost> _readTlsIdentityOverBle() async {
    final endpoint = await _readEndpointOverBle();
    return _host.copyWith(tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint);
  }

  /// Read this Host's own signed statement about itself, from beside it.
  Future<CommissioningEndpoint> _readEndpointOverBle() async {
    if (!await _transport.requestPermission()) {
      throw const CommissioningRequestException(
        'permission_denied',
        '需要“附近设备”权限来确认已保存主机的本地连接身份。',
      );
    }
    final marker = hostMarker(_host.hostId);
    final nearby = await _transport.scan(serviceUuid: _host.bleServiceUuid);
    final candidates = nearby.toList()
      ..sort((left, right) {
        final leftMatches = left.hostMarker.toLowerCase() == marker;
        final rightMatches = right.hostMarker.toLowerCase() == marker;
        if (leftMatches != rightMatches) return leftMatches ? -1 : 1;
        return right.rssi.compareTo(left.rssi);
      });
    for (final candidate in candidates) {
      try {
        final rawEndpoint = await _transport.open(
          address: candidate.address,
          serviceUuid: _host.bleServiceUuid,
        );
        final endpoint = await CommissioningEndpoint.parseAndVerifyHost(
          rawEndpoint,
          hostId: _host.hostId,
          hostPublicKey: _host.hostPublicKey,
          bleServiceUuid: _host.bleServiceUuid,
        );
        return endpoint;
      } on SetupTrustException {
        // Nearby Hosts are candidates until their signed identity matches.
      } on FormatException {
        // Malformed advertisements remain isolated from saved Host state.
      } on CommissioningRequestException {
        // Continue past stale or unreachable BLE advertisements.
      } on PlatformException {
        // Continue past stale platform scan results.
      } finally {
        await _transport.close();
      }
    }
    throw const CommissioningRequestException(
      'host_not_found',
      '没有在附近找到这台已保存的主机，无法安全更新本地连接身份。',
    );
  }

  void _verifyHost(HostOverview overview) {
    final descriptor = overview.descriptor;
    if (descriptor.hostId != _host.hostId ||
        descriptor.hostPublicKey != _host.hostPublicKey ||
        descriptor.hostPublicKeyFingerprint != _host.hostFingerprint ||
        descriptor.bleServiceUuid != _host.bleServiceUuid) {
      throw const SetupTrustException(
        '局域网服务返回了另一台 Host 的身份，已拒绝连接',
      );
    }
  }

  void _clearConnection() {
    _endpoint = null;
    _overview = null;
    _controllerSession = null;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Host product session is closed');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    _cancelRequests();
    _clearConnection();
    await _transport.close();
  }

  static LocalApiClient _platformClientFactory(String fingerprint) =>
      LocalApiClient(
        ownsHttpClient: true,
        httpClient: PlatformPinnedHttpClient(
          tlsSpkiFingerprint: fingerprint,
        ),
      );

  static ManagementClient _platformManagementClientFactory(
          String fingerprint) =>
      ManagementClient(
        ownsHttpClient: true,
        httpClient: PlatformPinnedHttpClient(
          tlsSpkiFingerprint: fingerprint,
        ),
      );
}
