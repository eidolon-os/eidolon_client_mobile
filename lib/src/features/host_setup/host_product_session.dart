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

/// How long one address gets to itself before the next is tried alongside it.
///
/// RFC 8305's Connection Attempt Delay: 250 ms recommended, 100 ms minimum,
/// and never below 10 ms. Short enough that a wrong first address costs a
/// quarter second instead of a timeout; long enough that the common case —
/// the first address being right — makes exactly one connection.
const Duration _connectionAttemptDelay = Duration(milliseconds: 250);

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

/// What racing one tier of addresses established.
class _AddressRace {
  const _AddressRace({
    required this.winner,
    required this.failures,
  });

  final _ReachedHost? winner;
  final List<Object> failures;
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
          readPublished: (_) async =>
              (await _readEndpointOverBle()).localApiBaseUrls,
        );
  }

  /// One publication point for explicit connects and automatic relocation.
  Future<void> Function(ManagedHost host)? onHostConnected;
  Future<ManagedHost>? _connecting;
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

  Future<ManagedHost> connect({HostConnectionProgress? onProgress}) {
    _ensureOpen();
    return _connecting ??= _connectCurrentNetwork(onProgress).whenComplete(() {
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
      onProgress?.call('正在从附近主机更新本地连接信任');
      _host = await _readTlsIdentityOverBle();
    }

    onProgress?.call('正在同一局域网中查找主机');
    // Each means of learning where the Host is, cheapest first, and the next
    // one only when nothing in the last could be reached. Multicast does not
    // reach every phone on every network — same Wi-Fi, same subnet, ping fine,
    // and nothing discovered — so a Host this phone has already claimed asks
    // its way through the alternatives instead of stopping there. Nothing is
    // trusted for having been remembered or published: every candidate proves
    // it is this Host before a word is said to it.
    // Two kinds of failure, kept apart because only one of them explains an
    // outcome. A Host that answered and refused decided something; a candidate
    // that nothing answered at has decided nothing and is only a lead removed.
    //
    // They used to share one variable that every failure overwrote, so what
    // surfaced was whichever candidate happened to be tried last. On a phone
    // where the Local API answered fine at 192.168.3.206, the sentence shown
    // was `Unable to resolve host "eidolon-pi5.local"` — a candidate that had
    // nothing to do with why the connection did not happen. The person, and
    // the person reading the bug report, were handed an unrelated fact.
    Object? decidedFailure;
    Object? silentFailure;
    var silentCandidates = 0;
    await for (final tier in _locator.locate(_host)) {
      // Identity is checked independently for every candidate. Only the
      // verified target Host can accept or refuse controller authorization.
      final race = await _firstToAnswer(tier);
      for (final error in race.failures) {
        final silence =
            error is PinnedHttpException && _hostDidNotAnswer(error);
        if (silence) {
          silentFailure = error;
          silentCandidates += 1;
        } else {
          decidedFailure ??= error;
        }
      }
      final winner = race.winner;
      if (winner != null) {
        final endpoint = winner.endpoint;
        final client = winner.client;
        try {
          final controllerSession = await _authenticate(
            client,
            endpoint,
            winner.overview,
          );
          _ensureOpen();
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
          client.close();
        }
      }
      // A different device at a candidate address cannot decide that the
      // requested Host is absent. Keep the refusal for diagnostics, but try
      // the remaining sources under the same identity and TLS checks.
    }
    // The refusal that decided this, if anything decided it. Only when
    // nothing anywhere answered does silence become the answer.
    //
    // One silent candidate can speak for itself: `failureSentence` grades a
    // timeout apart from a network that has no route, and with a single
    // address tried that distinction is both specific and true. Several
    // silent candidates cannot. Whichever was tried last is an arbitrary pick
    // among equals, and quoting its address as the account of the failure
    // describes one address when the fact being reported is that none of them
    // answered. That fact is not a gap to fill with an example — it already
    // has its own sentence, written just below, and it is the honest one.
    final failure =
        decidedFailure ?? (silentCandidates == 1 ? silentFailure : null);
    if (failure != null) throw failure;
    throw const LocalApiRequestException(
      '局域网里没有任何设备应答这台主机的 Local API。'
      '已经试过 mDNS 服务浏览、主机名解析、本网段探测，以及上次连上的地址。'
      '请确认主机已开机、并和这台手机在同一个局域网。$controllerResetGuidance',
    );
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
    final client = _managementClientFactory(_host.tlsSpkiFingerprint!);
    try {
      return await operation(
        client,
        LocalApiClient.parseBaseUri(endpoint.baseUrl),
        session.accessToken,
      );
    } finally {
      client.close();
    }
  }

  /// Whether the Host was never reached, as opposed to having answered.
  ///
  /// Only the absence of an answer means the address may be wrong. A refusal,
  /// a broken pin, a malformed reply — those all came from something that was
  /// there, and re-locating would hide what it said.
  /// Which of a Host's own addresses answers first, tried the way RFC 8305
  /// says to try several addresses for one destination.
  ///
  /// A Host publishes every address it has, because only the phone knows which
  /// subnet it is on. Trying them in order made the *order* load-bearing: the
  /// board is on Wi-Fi and on a wired link at once, the wired address is listed
  /// first, and a phone on the Wi-Fi paid the full client timeout against an
  /// address only a laptop on that cable could reach before it ever tried the
  /// one that works.
  ///
  /// Nobody can sort that list correctly — not the Host, which does not know
  /// where the phone is, and not the phone, which does not know the Host's
  /// topology. So it is not sorted, it is raced: start the first, and start the
  /// next either when [_connectionAttemptDelay] is spent or as soon as one
  /// already running has settled, whichever comes first. Ordering degrades from
  /// "decides the outcome" to "decides who gets a 250 ms head start", which is
  /// what it deserves to decide.
  ///
  /// Only the read is raced. `fetchHost` is a GET and identical against every
  /// address of one Host, so several in flight cost nothing and change nothing;
  /// authenticating is not, and racing it would mint a session per address. So
  /// the race establishes *where*, and hands over the client that got there for
  /// the caller to authenticate on — once.
  Future<_AddressRace> _firstToAnswer(List<HostAddressCandidate> tier) async {
    final failures = <Object>[];
    _ReachedHost? winner;
    final pending = <Future<void>>[];
    // Completed by whichever attempt settles next, so a candidate that fails
    // quickly frees its slot immediately instead of making the next one sit
    // out a delay that exists for undecided attempts.
    Completer<void>? settled;
    // Completed by the first attempt to reach the Host. Separate from the slot
    // signal because it is never reset: once somebody has answered, waiting on
    // anything else is waiting for nothing.
    final decided = Completer<void>();

    void slotFreed() {
      final waiting = settled;
      settled = null;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    }

    Future<void> attempt(HostAddressCandidate candidate) async {
      final client = _clientFactory(_host.tlsSpkiFingerprint!);
      var handedOver = false;
      try {
        final overview = await client.fetchHost(candidate.endpoint.baseUrl);
        _verifyHost(overview);
        // A loser of the race is not a failure and is not recorded as one: two
        // addresses of one Host both answering is the normal case, not a fault.
        if (winner != null) return;
        winner = _ReachedHost(candidate.endpoint, overview, client);
        handedOver = true;
        if (!decided.isCompleted) decided.complete();
      } catch (error) {
        failures.add(error);
      } finally {
        if (!handedOver) client.close();
        slotFreed();
      }
    }

    for (var index = 0; index < tier.length; index += 1) {
      settled = Completer<void>();
      pending.add(attempt(tier[index]));
      if (index == tier.length - 1) break;
      await Future.any([
        settled!.future,
        Future<void>.delayed(_connectionAttemptDelay),
      ]);
      if (winner != null) break;
    }
    if (winner == null) {
      // Everything is started and nothing has come back yet. Whichever happens
      // first: somebody answers, or they have all failed. Waiting for them all
      // unconditionally is what makes one address that never answers cost its
      // full client timeout, which is the whole thing this replaces.
      //
      // When they have all failed, every candidate's own outcome is wanted — a
      // timeout and a no-route say different things to the person who has to
      // read the message.
      await Future.any([decided.future, Future.wait(pending)]);
    }
    return _AddressRace(winner: winner, failures: failures);
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
    final client = _clientFactory(_host.tlsSpkiFingerprint!);
    try {
      return await operation(client, endpoint.baseUrl, session.accessToken);
    } finally {
      client.close();
    }
  }

  Future<void> _reauthenticate() async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const HostControllerAuthorizationException('请重新连接主机');
    }
    final client = _clientFactory(_host.tlsSpkiFingerprint!);
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
      client.close();
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
    _clearConnection();
    await _transport.close();
  }

  static LocalApiClient _platformClientFactory(String fingerprint) =>
      LocalApiClient(
        httpClient: PlatformPinnedHttpClient(
          tlsSpkiFingerprint: fingerprint,
        ),
      );

  static ManagementClient _platformManagementClientFactory(
          String fingerprint) =>
      ManagementClient(
        httpClient: PlatformPinnedHttpClient(
          tlsSpkiFingerprint: fingerprint,
        ),
      );
}
