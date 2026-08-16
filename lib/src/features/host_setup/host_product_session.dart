import 'dart:async';

import 'package:flutter/services.dart';

import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_identity.dart';
import '../setup/host_registry.dart';
import '../setup/setup_models.dart';
import '../setup/setup_trust.dart';
import 'controller_session.dart';
import 'host_models.dart';
import 'local_api_client.dart';
import 'local_api_discovery.dart';
import 'pinned_http_client.dart';

typedef LocalApiClientFactory = LocalApiClient Function(String fingerprint);
typedef HostConnectionProgress = void Function(String message);
typedef LocalApiOperation<T> = Future<T> Function(
  LocalApiClient client,
  String baseUrl,
  String accessToken,
);

class HostControllerAuthorizationException implements Exception {
  const HostControllerAuthorizationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class HostProductConnection {
  const HostProductConnection({
    required this.endpoint,
    required this.overview,
    required this.controllerId,
    required this.ownerId,
    required this.sessionExpiresAt,
  });

  final LocalApiEndpoint endpoint;
  final HostOverview overview;
  final String controllerId;
  final String? ownerId;
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
  })  : _host = host,
        _transport = transport ?? PlatformBleCommissioningTransport(),
        _controllerKeys = controllerKeys ?? PlatformControllerKeyBridge(),
        _discovery = discovery ?? PlatformLocalApiDiscovery(),
        _clientFactory = clientFactory ?? _platformClientFactory;

  ManagedHost _host;
  final CommissioningTransport _transport;
  final ControllerKeyBridge _controllerKeys;
  final LocalApiDiscovery _discovery;
  final LocalApiClientFactory _clientFactory;

  LocalApiEndpoint? _endpoint;
  HostOverview? _overview;
  LocalControllerSession? _controllerSession;
  bool _closed = false;

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
      ownerId: session.ownerId,
      sessionExpiresAt: session.expiresAt,
    );
  }

  Future<ManagedHost> connect({HostConnectionProgress? onProgress}) async {
    _ensureOpen();
    _clearConnection();
    if (_host.tlsSpkiFingerprint == null) {
      onProgress?.call('正在从附近主机更新本地连接信任');
      _host = await _readTlsIdentityOverBle();
    }

    onProgress?.call('正在同一局域网中查找主机');
    // Where it answered last time is tried alongside whatever discovery finds.
    // Multicast does not reach every phone on every network — same Wi-Fi, same
    // subnet, ping fine, and nothing discovered — and a Host this phone has
    // already claimed should not become unreachable because one mechanism went
    // quiet. Nothing is trusted for being remembered: each candidate still has
    // to prove it is this Host before a word is said to it.
    final endpoints = await _reachableCandidates();
    Object? lastFailure;
    for (final endpoint in endpoints) {
      final client = _clientFactory(_host.tlsSpkiFingerprint!);
      try {
        final overview = await client.fetchHost(endpoint.baseUrl);
        _verifyHost(overview);
        final controllerSession = await _authenticate(
          client,
          endpoint,
          overview,
        );
        _endpoint = endpoint;
        _overview = overview;
        _controllerSession = controllerSession;
        if (_host.lastKnownBaseUrl != endpoint.baseUrl) {
          _host = _host.copyWith(lastKnownBaseUrl: endpoint.baseUrl);
        }
        return _host;
      } catch (error) {
        lastFailure = error;
      } finally {
        client.close();
      }
    }
    if (lastFailure != null) throw lastFailure;
    throw const LocalApiRequestException('局域网中没有兼容的 Eidolon 主机');
  }

  /// Every address worth trying for this Host, remembered one first.
  ///
  /// Discovery failing is not fatal while an address is remembered: it means
  /// this network did not carry the announcement, not that the Host is gone.
  Future<List<LocalApiEndpoint>> _reachableCandidates() async {
    final candidates = <String, LocalApiEndpoint>{};
    Object? discoveryFailure;
    try {
      for (final endpoint in await _discovery.discover()) {
        candidates[endpoint.baseUrl] = endpoint;
      }
    } catch (error) {
      discoveryFailure = error;
    }
    // Discovery goes first and stays authoritative: a Host that moved is found
    // at its new address, and the remembered one is stale by definition. Memory
    // is what remains when discovery answers with nothing at all.
    final remembered = _host.lastKnownBaseUrl;
    if (remembered != null) {
      candidates.putIfAbsent(
        remembered,
        () => LocalApiEndpoint(
          instanceName: 'remembered',
          baseUrl: remembered,
          ipAddress: Uri.parse(remembered).host,
          contractVersion: '1',
        ),
      );
    }
    if (candidates.isEmpty && discoveryFailure != null) throw discoveryFailure;
    return candidates.values.toList(growable: false);
  }

  /// Runs a typed Local API operation and performs one bounded re-authentication
  /// when the short-lived Controller session has expired.
  Future<T> execute<T>(LocalApiOperation<T> operation) async {
    _ensureOpen();
    final endpoint = _endpoint;
    final session = _controllerSession;
    if (endpoint == null || session == null) {
      throw const HostControllerAuthorizationException('请先安全连接主机');
    }
    try {
      return await _executeOnce(operation, endpoint, session);
    } on LocalApiRequestException catch (error) {
      if (error.statusCode != 401) rethrow;
    }

    await _reauthenticate();
    return _executeOnce(operation, _endpoint!, _controllerSession!);
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
            ? '主机已重置或不再授权这台管理设备。请让持有主机的人执行 Controller Reset，'
                  '然后像首次开箱一样重新连接；主机数据不会丢失。'
            : '管理会话已失效，且暂时无法重新认证。请重新连接主机。',
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
          '主机已重置或不再授权这台管理设备。请让持有主机的人执行 Controller Reset，'
          '然后像首次开箱一样重新连接；主机数据不会丢失。',
        );
      }
      rethrow;
    }
  }

  Future<ManagedHost> _readTlsIdentityOverBle() async {
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
        return _host.copyWith(
          tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
        );
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
}
