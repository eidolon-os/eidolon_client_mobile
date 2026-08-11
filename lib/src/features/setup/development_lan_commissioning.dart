import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../host_setup/local_api_client.dart';
import '../host_setup/local_api_discovery.dart';
import '../host_setup/pinned_http_client.dart';
import 'controller_key_bridge.dart';
import 'host_identity.dart';
import 'host_registry.dart';
import 'setup_models.dart';

typedef DevelopmentEndpointFetcher = Future<String> Function(String baseUrl);
typedef DevelopmentPinnedClientFactory = http.Client Function(
    String tlsSpkiFingerprint);

class DevelopmentLanHost {
  const DevelopmentLanHost({required this.localApi, required this.endpoint});

  final LocalApiEndpoint localApi;
  final CommissioningEndpoint endpoint;

  String get displayName => defaultHostDisplayName(endpoint.hostId);
}

/// Development-only commissioning for an already-networked Host.
///
/// The first bounded GET is controlled TOFU, matching the existing development
/// BLE flow: its result is accepted only after the Host Ed25519 signature is
/// verified. Every mutation then uses the signed SPKI pin. Production builds
/// and production Hosts both reject this path.
class DevelopmentLanCommissioning {
  DevelopmentLanCommissioning({
    LocalApiDiscovery? discovery,
    ControllerKeyBridge? controllerKeys,
    DevelopmentEndpointFetcher? endpointFetcher,
    DevelopmentPinnedClientFactory? pinnedClientFactory,
    DateTime Function()? clock,
  })  : _discovery = discovery ?? PlatformLocalApiDiscovery(),
        _controllerKeys = controllerKeys ?? PlatformControllerKeyBridge(),
        _endpointFetcher =
            endpointFetcher ?? _fetchSignedEndpointForDevelopment,
        _pinnedClientFactory = pinnedClientFactory ??
            ((fingerprint) =>
                PlatformPinnedHttpClient(tlsSpkiFingerprint: fingerprint)),
        _clock = clock ?? DateTime.now;

  final LocalApiDiscovery _discovery;
  final ControllerKeyBridge _controllerKeys;
  final DevelopmentEndpointFetcher _endpointFetcher;
  final DevelopmentPinnedClientFactory _pinnedClientFactory;
  final DateTime Function() _clock;

  Future<List<DevelopmentLanHost>> discover() async {
    _requireDebugBuild();
    final candidates = await _discovery.discover();
    final hosts = <DevelopmentLanHost>[];
    final seen = <String>{};
    for (final localApi in candidates) {
      try {
        final raw = await _endpointFetcher(localApi.baseUrl);
        final endpoint = await CommissioningEndpoint.parseAndVerifyDiscovered(
          raw,
        );
        final setup = endpoint.developmentSetup;
        if (setup == null || !setup.expiresAt.isAfter(_clock().toUtc())) {
          continue;
        }
        if (seen.add(endpoint.hostId)) {
          hosts.add(DevelopmentLanHost(localApi: localApi, endpoint: endpoint));
        }
      } catch (_) {
        // A Local API is only a candidate until its signed development
        // endpoint verifies. Production, stale and unrelated services remain
        // invisible to this debug-only flow.
      }
    }
    return hosts;
  }

  Future<ManagedHost> claim(
    DevelopmentLanHost host, {
    required String setupCode,
    required String controllerName,
  }) async {
    _requireDebugBuild();
    if (!setupCodePattern.hasMatch(setupCode)) {
      throw const CommissioningRequestException(
        'invalid_setup_code',
        '请输入 $setupCodeDigits 位 Setup 码',
      );
    }
    final normalizedName = controllerName.trim();
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw const CommissioningRequestException(
        'invalid_controller_name',
        '管理手机名称必须包含 1 到 80 个字符',
      );
    }
    final setup = host.endpoint.developmentSetup;
    if (setup == null || !setup.expiresAt.isAfter(_clock().toUtc())) {
      throw const CommissioningRequestException(
        'setup_code_expired',
        '开发 Setup 会话已过期，请在 Host 上重新生成',
      );
    }
    final controller = await _controllerKeys.getIdentity();
    final client = _pinnedClientFactory(host.endpoint.tlsSpkiFingerprint);
    try {
      final base = LocalApiClient.parseBaseUri(host.localApi.baseUrl);
      final response = await client
          .put(
            base.resolve('/api/local/v1/development/commissioning/claim'),
            headers: const {
              'accept': 'application/json',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'contract_version': '1',
              'commissioning_id': setup.commissioningId,
              'setup_code': setupCode,
              'controller': {
                'controller_id': controller.controllerId,
                'public_key': controller.publicKey,
                'display_name': normalizedName,
                'platform': 'android',
              },
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        final code = switch (response.statusCode) {
          401 => 'commissioning_denied',
          404 => 'development_lan_unavailable',
          409 => 'already_claimed',
          _ => 'lan_claim_failed',
        };
        throw CommissioningRequestException(
          code,
          '开发 Host 认领失败（HTTP ${response.statusCode}）',
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['contract_version'] != '1' ||
          decoded['operation'] != 'local.development-lan-commissioning-claim' ||
          decoded['host_id'] != host.endpoint.hostId ||
          decoded['controller'] is! Map ||
          (decoded['controller'] as Map)['controller_id'] !=
              controller.controllerId ||
          decoded['state'] is! Map ||
          (decoded['state'] as Map)['claim_state'] != 'claimed' ||
          (decoded['state'] as Map)['network_state'] != 'connected') {
        throw const CommissioningRequestException(
          'invalid_response',
          '开发 Host 没有返回有效的认领结果',
        );
      }
      return ManagedHost(
        hostId: host.endpoint.hostId,
        hostPublicKey: host.endpoint.hostPublicKey,
        hostFingerprint: host.endpoint.hostPublicKeyFingerprint,
        bleServiceUuid: host.endpoint.bleServiceUuid,
        controllerId: controller.controllerId,
        displayName: host.displayName,
        claimedAt: _clock().toUtc(),
        tlsSpkiFingerprint: host.endpoint.tlsSpkiFingerprint,
      );
    } finally {
      client.close();
    }
  }

  static void _requireDebugBuild() {
    if (!kDebugMode) {
      throw const CommissioningRequestException(
        'development_only',
        '局域网开发认领只在 Debug App 中开放',
      );
    }
  }
}

Future<String> _fetchSignedEndpointForDevelopment(String baseUrl) async {
  DevelopmentLanCommissioning._requireDebugBuild();
  final base = LocalApiClient.parseBaseUri(baseUrl);
  final endpoint = base.resolve(
    '/api/local/v1/development/commissioning/endpoint',
  );
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 3);
  client.badCertificateCallback = (_, __, ___) => true;
  try {
    final request =
        await client.getUrl(endpoint).timeout(const Duration(seconds: 3));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'development endpoint returned ${response.statusCode}',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 64 * 1024) {
        throw const FormatException('development endpoint is too large');
      }
    }
    return utf8.decode(bytes);
  } finally {
    client.close(force: true);
  }
}
