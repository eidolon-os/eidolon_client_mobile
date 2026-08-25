import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../host_setup/local_api_candidate_sources.dart';
import '../host_setup/local_api_client.dart';
import '../host_setup/local_api_discovery.dart';
import '../host_setup/pinned_http_client.dart';
import 'controller_key_bridge.dart';
import 'host_identity.dart';
import 'host_registry.dart';
import 'setup_trust.dart';
import 'setup_models.dart';

typedef DevelopmentEndpointFetcher = Future<String> Function(String baseUrl);
typedef DevelopmentPinnedClientFactory = http.Client Function(
    String tlsSpkiFingerprint);

class DevelopmentLanHost {
  const DevelopmentLanHost({required this.candidate, required this.endpoint});

  /// The lead this Host was found by. Kept for the record and for what to tell
  /// a person; it had no part in admitting it.
  final LocalApiCandidate candidate;
  final CommissioningEndpoint endpoint;

  LocalApiEndpoint get localApi => candidate.endpoint;

  String get displayName => defaultHostDisplayName(endpoint.hostId);
}

/// Why the gate turned a candidate away.
enum DevelopmentLanRefusal {
  /// It answered and could not prove it is a Host. A refusal, and a security
  /// event: an address on the LAN answered where a Host should be.
  unverified,

  /// It proved it is a Host, and has no open development Setup session.
  noSetupSession,

  /// It never answered at all. Says nothing about anything.
  silent,
}

class DevelopmentLanRejection {
  const DevelopmentLanRejection({
    required this.candidate,
    required this.refusal,
    required this.reason,
  });

  final LocalApiCandidate candidate;
  final DevelopmentLanRefusal refusal;
  final String reason;
}

/// One pass of looking: what every probe saw, and what the gate did with it.
///
/// Returned instead of a bare list because "no Host to claim" is at least four
/// different situations with four different next steps, and a list can only
/// say "empty". Which one it was is the whole of what the person needs.
class DevelopmentLanDiscovery {
  const DevelopmentLanDiscovery({
    required this.hosts,
    required this.survey,
    required this.rejections,
  });

  final List<DevelopmentLanHost> hosts;
  final LocalApiSurvey survey;
  final List<DevelopmentLanRejection> rejections;

  Iterable<DevelopmentLanRejection> _refused(DevelopmentLanRefusal refusal) =>
      rejections.where((rejection) => rejection.refusal == refusal);

  /// Why there is nothing to claim, said in a way that can be acted on.
  ///
  /// Ordered by how much is actually known, not by severity. A Host that
  /// verified and has no Setup session is a fact about a specific machine; an
  /// impostor answering somewhere on the LAN, while the real Host verified, is
  /// not the thing to put in front of the person.
  CommissioningRequestException? get failure {
    if (hosts.isNotEmpty) return null;
    final withoutSession = _refused(DevelopmentLanRefusal.noSetupSession);
    if (withoutSession.isNotEmpty) {
      return CommissioningRequestException(
        'setup_session_missing',
        '已经验证了 ${withoutSession.length} 台 Host 的身份，但它们都没有开放的开发 Setup 会话'
            '（${withoutSession.first.reason}）。'
            '请在 Host 上重新生成 $setupCodeDigits 位 Setup 码，然后再查找一次。',
      );
    }
    final unverified = _refused(DevelopmentLanRefusal.unverified);
    if (unverified.isNotEmpty) {
      final refused = unverified.first;
      return CommissioningRequestException(
        'host_identity_unverified',
        '有设备在 Local API 端口上应答，但没能通过 Host 签名验证，已被拒绝接入：'
            '${refused.candidate.endpoint.baseUrl}（${refused.reason}）。'
            '发现只产生候选，验证才是权威，所以这台设备不会被当成你的 Host。'
            '请确认手机连的是自己的局域网；如果这确实是你的 Host，'
            '说明它的身份已经和这台手机记住的不一样了。$controllerResetGuidance',
      );
    }
    if (survey.incompatible.isNotEmpty) {
      final answer = survey.incompatible.first;
      return CommissioningRequestException(
        'local_api_incompatible',
        'Host 就在局域网里，但它的 Local API 契约版本是 ${answer.contractVersion}，'
            '这台 App 只会说 1：${answer.baseUrl}。'
            '这不是找不到 Host，而是版本对不上——请把 App 和 Host 更新到同一个版本。',
      );
    }
    final silent = _refused(DevelopmentLanRefusal.silent).length;
    return CommissioningRequestException(
      'host_not_found',
      '局域网里没有任何设备应答 Eidolon Local API。'
          '已尝试：${survey.describeAttempts()}。'
          '${silent > 0 ? '其中 $silent 个候选地址没有回答 Host 身份查询。' : ''}'
          '请确认 Host 已开机、和这台手机在同一个局域网。$controllerResetGuidance',
    );
  }
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
  })  : _discovery = discovery ?? platformLocalApiDiscovery(),
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

  Future<DevelopmentLanDiscovery> discover() async {
    _requireDebugBuild();
    final survey = await _discovery.discover();
    final hosts = <DevelopmentLanHost>[];
    final rejections = <DevelopmentLanRejection>[];
    final seen = <String>{};
    for (final candidate in survey.candidates) {
      final admission = await _admit(candidate);
      final host = admission.host;
      if (host == null) {
        rejections.add(admission.rejection!);
        continue;
      }
      // The same Host reached two ways is one Host. Keeping the first keeps the
      // cheapest evidence and leaves the second lead unused rather than
      // presenting one machine twice.
      if (seen.add(host.endpoint.hostId)) hosts.add(host);
    }
    return DevelopmentLanDiscovery(
      hosts: hosts,
      survey: survey,
      rejections: rejections,
    );
  }

  /// The single gate every candidate passes through.
  ///
  /// This is the security boundary of the whole flow, and it is deliberately
  /// the *only* thing that decides. A candidate's origin is not consulted here
  /// and must never be: an announcement, a resolved name and a swept address
  /// are all equally unproven, and the moment one of them could shorten this
  /// path, discovery would have become trust. What proves a Host is its own
  /// Ed25519-signed descriptor and the SPKI pin that descriptor names —
  /// which is also why sweeping addresses costs nothing in safety: whatever
  /// answers on that port still has to produce a signature it cannot forge.
  Future<({DevelopmentLanHost? host, DevelopmentLanRejection? rejection})>
      _admit(LocalApiCandidate candidate) async {
    DevelopmentLanRejection refuse(
      DevelopmentLanRefusal refusal,
      String reason,
    ) =>
        DevelopmentLanRejection(
          candidate: candidate,
          refusal: refusal,
          reason: reason,
        );

    try {
      final raw = await _endpointFetcher(candidate.endpoint.baseUrl);
      final endpoint = await CommissioningEndpoint.parseAndVerifyDiscovered(
        raw,
      );
      final setup = endpoint.developmentSetup;
      if (setup == null) {
        return (
          host: null,
          rejection: refuse(
            DevelopmentLanRefusal.noSetupSession,
            '没有开放的开发 Setup 会话',
          ),
        );
      }
      if (!setup.expiresAt.isAfter(_clock().toUtc())) {
        return (
          host: null,
          rejection: refuse(
            DevelopmentLanRefusal.noSetupSession,
            '开发 Setup 会话已过期',
          ),
        );
      }
      return (
        host: DevelopmentLanHost(candidate: candidate, endpoint: endpoint),
        rejection: null,
      );
    } on SetupTrustException catch (error) {
      return (
        host: null,
        rejection: refuse(DevelopmentLanRefusal.unverified, error.message),
      );
    } on FormatException catch (error) {
      return (
        host: null,
        rejection: refuse(
          DevelopmentLanRefusal.unverified,
          error.message.toString(),
        ),
      );
    } catch (error) {
      // Nothing answered, or the answer never arrived. That is silence about
      // one address, not a verdict on anything — and it is kept apart from a
      // refusal so the person is not told a security story about a timeout.
      return (
        host: null,
        rejection: refuse(DevelopmentLanRefusal.silent, '$error'),
      );
    }
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
        // 401 is the Host refusing this phone, which is the one failure here
        // that a person cannot fix from the phone at all — so it is the one
        // that has to name the way back in.
        if (response.statusCode == 401) {
          throw const CommissioningRequestException(
            'commissioning_denied',
            'Host 拒绝了这台手机（HTTP 401）。Setup 码可能已经用过、过期或输错了，'
                '请在 Host 上重新生成一个再试。$controllerResetGuidance',
          );
        }
        final code = switch (response.statusCode) {
          404 => 'development_lan_unavailable',
          409 => 'operation_conflict',
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
