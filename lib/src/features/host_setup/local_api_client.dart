import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../generated/device_foundation_v1.dart';
import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/setup_trust.dart';
import 'activity_models.dart';
import 'companion_face_models.dart';
import 'controller_grant_models.dart';
import 'controller_session.dart';
import 'host_models.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';
import 'workspace_models.dart';
import 'workspace_runtime_models.dart';

class LocalApiRequestException implements Exception {
  const LocalApiRequestException(this.message, {this.statusCode, this.reason});

  final String message;
  final int? statusCode;

  /// What the Host said when it refused, when it said anything.
  ///
  /// A status code alone cannot separate "another Owner already holds this
  /// device" from "an authority behind the Host refused it", so a screen keyed
  /// on the code alone has to offer one guess for both. The Host knows which it
  /// was, and grades its answer before sending it; this is that answer.
  final String? reason;

  @override
  String toString() => reason == null ? message : '$message：$reason';
}

class LocalApiClient {
  LocalApiClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  static Uri parseBaseUri(String input) {
    final normalized = input.trim();
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException(
        '请输入 http:// 或 https:// 开头的 Eidolon Local API 地址',
      );
    }
    if (uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Local API 地址只能包含协议、主机和端口');
    }
    return uri.replace(path: '/', query: null, fragment: null);
  }

  static String createHostChallenge() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<HostOverview> fetchHost(String baseUrl) async {
    final baseUri = parseBaseUri(baseUrl);
    final endpoint = baseUri.resolve('/api/local/v1/host');
    final response = await _httpClient.get(endpoint,
        headers: const {'accept': 'application/json'}).timeout(timeout);
    if (response.statusCode != 200) {
      throw LocalApiRequestException(
        'Eidolon Local API 返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Local API 返回的 Host 数据不是 JSON object');
    }
    return HostOverview.fromJson(decoded);
  }

  Future<LocalControllerSession> authenticateController(
    String baseUrl, {
    required String expectedControllerId,
    required ControllerKeyBridge controllerKeys,
  }) async {
    final identity = await controllerKeys.getIdentity();
    if (identity.controllerId != expectedControllerId) {
      throw const SetupTrustException(
        '保存的 Host Controller 与本机 Keystore 身份不一致',
      );
    }
    final baseUri = parseBaseUri(baseUrl);
    final challengeResponse = await _httpClient
        .post(
          baseUri.resolve('/api/local/v1/auth/challenges'),
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'contract_version': '1',
            'controller_id': identity.controllerId,
          }),
        )
        .timeout(timeout);
    final challengeJson = _decodeResponse(
      challengeResponse,
      operation: 'Controller challenge',
    );
    final challenge = LocalControllerChallenge.fromJson(challengeJson);
    if (challenge.controllerId != identity.controllerId) {
      throw const SetupTrustException(
        'Local API challenge 指向了另一 Controller',
      );
    }
    final proof = challenge.toJson();
    final signature = await controllerKeys.signChallenge(proof);
    final sessionResponse = await _httpClient
        .post(
          baseUri.resolve('/api/local/v1/auth/sessions'),
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode({...proof, 'signature': signature}),
        )
        .timeout(timeout);
    final session = LocalControllerSession.fromJson(
      _decodeResponse(sessionResponse, operation: 'Controller session'),
    );
    if (session.controllerId != identity.controllerId ||
        session.resetEpoch != challenge.resetEpoch) {
      throw const SetupTrustException(
        'Local API session 与本次 Controller challenge 不匹配',
      );
    }
    return session;
  }

  Future<WorkspaceStatus> fetchWorkspace(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/setup/workspace'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return WorkspaceStatus.fromJson(
      _decodeResponse(response, operation: 'Workspace status'),
    );
  }

  Future<WorkspaceStatus> initializeWorkspace(
    String baseUrl, {
    required String accessToken,
    required String ownerDisplayName,
    required String companionDisplayName,
  }) async {
    final response = await _httpClient
        .put(
          parseBaseUri(baseUrl).resolve('/api/local/v1/setup/workspace'),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'owner_display_name': ownerDisplayName,
            'companion_display_name': companionDisplayName,
          }),
        )
        .timeout(timeout);
    return WorkspaceStatus.fromJson(
      _decodeResponse(response, operation: 'Workspace setup'),
    );
  }

  Future<WorkspaceRuntime> fetchWorkspaceRuntime(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/workspace/runtime'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return WorkspaceRuntime.fromJson(
      _decodeResponse(response, operation: 'Workspace runtime'),
    );
  }

  Future<MountedDeviceInventory> fetchMountedDevices(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/devices'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return MountedDeviceInventory.fromJson(
      _decodeResponse(response, operation: 'Device inventory'),
    );
  }

  Future<DeviceOnboardingTarget> fetchDeviceOnboardingTarget(
    String baseUrl, {
    required String accessToken,
  }) async {
    final origin = parseBaseUri(baseUrl);
    final response = await _httpClient
        .get(
          origin.resolve('/api/local/v1/device-onboarding/target'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    // The Hub named in this answer runs on the Host that just answered, so the
    // address this request reached is an address its Hub answers on too. The
    // Host names its Hub in mDNS, which this client cannot query.
    return DeviceOnboardingTarget.fromJson(
      _decodeResponse(response, operation: 'Device onboarding target'),
    ).reachedAt(origin.host);
  }

  /// The Enrollments this Owner has waiting, as the Host projects them.
  ///
  /// The Host is the only Admission surface this phone talks to. Hub owns the
  /// canonical Authority and the Host presents a short-lived, exactly-scoped
  /// credential on this Controller's behalf; the phone holding one that could
  /// approve a device would be a second place that decides.
  Future<EnrollmentProposalPageV1> fetchEnrollmentRecoveryPage(
    String baseUrl, {
    required String accessToken,
    required String ownerDomainId,
    AdmissionListCursorV1? after,
    int limit = 50,
  }) async {
    OwnerDomainIdV1.parse(ownerDomainId);
    if (limit < 1 || limit > 50) {
      throw const FormatException('Admission page limit is invalid');
    }
    final cursor = after?.json;
    if (cursor != null && cursor['owner_domain_id'] != ownerDomainId) {
      throw const FormatException('Admission cursor Owner Domain mismatch');
    }
    final response = await _httpClient
        .get(
          _deviceEnrollmentsUri(baseUrl).replace(
            queryParameters: <String, dynamic>{
              'states': const [
                'pending_review',
                'approved_awaiting_handoff',
                'grant_delivered',
                'grant_acknowledged',
              ],
              'limit': '$limit',
              if (cursor != null) ...{
                'after_sort_key': cursor['sort_key']! as String,
                'after_resource_id': cursor['resource_id']! as String,
              },
            },
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    final page = EnrollmentProposalPageV1.fromJson(
      _decodeResponse(response, operation: 'Enrollment recovery page'),
    );
    if (page.json['owner_domain_id'] != ownerDomainId) {
      throw const FormatException('Admission page Owner Domain mismatch');
    }
    return page;
  }

  Future<EnrollmentRecoveryProjectionV1> fetchEnrollmentRecovery(
    String baseUrl, {
    required String accessToken,
    required String enrollmentId,
  }) async {
    final response = await _httpClient
        .get(
          _deviceEnrollmentsUri(
            baseUrl,
            suffix: [_boundedId(enrollmentId, 'Enrollment ID')],
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return EnrollmentRecoveryProjectionV1.fromJson(
      _decodeResponse(response, operation: 'Enrollment recovery'),
    );
  }

  /// Submits the Owner's one explicit Decision to the Host's workflow.
  ///
  /// [requestId] is the idempotency key, not a Hub command ID: replaying it
  /// resumes the Host's durable intent instead of deciding a second time. The
  /// expected Owner identities are what the confirming screen showed, and the
  /// Host refuses the Decision if its own session no longer holds them.
  Future<AdmissionDecisionOutcome> decideEnrollment(
    String baseUrl, {
    required String accessToken,
    required String requestId,
    required String enrollmentId,
    required int expectedProposalRevision,
    required Map<String, dynamic> reviewedManifestRef,
    required String expectedOwnerDomainId,
    required String expectedBusinessOwnerId,
    String? targetSpaceId,
    String? initialCompanionId,
  }) async {
    final response = await _httpClient
        .put(
          _deviceEnrollmentsUri(
            baseUrl,
            suffix: [_boundedId(enrollmentId, 'Enrollment ID'), 'decision'],
          ),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'request_id': _boundedId(requestId, 'Decision request ID'),
            'expected_proposal_revision': expectedProposalRevision,
            'decision': 'approve',
            'reviewed_manifest_ref': reviewedManifestRef,
            'expected_owner_domain_id':
                OwnerDomainIdV1.parse(expectedOwnerDomainId).value,
            'expected_business_owner_id':
                _boundedId(expectedBusinessOwnerId, 'Owner ID'),
            'target_space_id': targetSpaceId,
            'initial_assignment_intent': initialCompanionId == null
                ? null
                : {'companion_id': initialCompanionId},
            'initial_capability_policy_refs': const <String>[],
          }),
        )
        .timeout(timeout);
    final outcome = AdmissionDecisionOutcome.fromJson(
      _decodeResponse(response, operation: 'Enrollment Decision'),
    );
    if (outcome.requestId != requestId) {
      throw const FormatException('主机应答了另一次批准请求');
    }
    return outcome;
  }

  Future<ClaimPageV1> fetchClaimPage(
    String baseUrl, {
    required String accessToken,
    required String ownerDomainId,
    AdmissionListCursorV1? after,
    int limit = 50,
  }) async {
    OwnerDomainIdV1.parse(ownerDomainId);
    if (limit < 1 || limit > 50) {
      throw const FormatException('Claim page limit is invalid');
    }
    final cursor = after?.json;
    if (cursor != null && cursor['owner_domain_id'] != ownerDomainId) {
      throw const FormatException('Claim cursor Owner Domain mismatch');
    }
    final response = await _httpClient
        .get(
          _localUri(baseUrl, const ['device-claims']).replace(
            queryParameters: <String, dynamic>{
              'states': const ['active', 'suspended', 'revoked'],
              'limit': '$limit',
              if (cursor != null) ...{
                'after_sort_key': cursor['sort_key']! as String,
                'after_resource_id': cursor['resource_id']! as String,
              },
            },
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    final page = ClaimPageV1.fromJson(
      _decodeResponse(response, operation: 'Claim page'),
    );
    if (page.json['owner_domain_id'] != ownerDomainId) {
      throw const FormatException('Claim page Owner Domain mismatch');
    }
    return page;
  }

  Future<DeviceRemovalProgress> removeDevice(
    String baseUrl, {
    required String accessToken,
    required String requestId,
    required String deviceId,
  }) async {
    final response = await _httpClient
        .post(
          _deviceRemovalUri(baseUrl, deviceId),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'request_id': _boundedId(requestId, 'request ID'),
          }),
        )
        .timeout(timeout);
    return DeviceRemovalProgress.fromJson(
      _decodeResponse(response, operation: 'Device removal'),
    );
  }

  /// Tell the Host what this person is called.
  ///
  /// No Owner is named: the session already says whose it is, and the Host
  /// refuses to be told otherwise.
  /// Whether this Eidolon has a face, and which one.
  ///
  /// Asked before the face itself, and cheap enough to ask on every refresh:
  /// the answer is a hash, so a screen learns its picture is stale without
  /// carrying a second picture over to compare.
  Future<CompanionFaceState> fetchCompanionFaceState(
    String baseUrl, {
    required String accessToken,
    required String companionId,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}'
            '/face-state',
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return CompanionFaceState.fromJson(
      _decodeResponse(response, operation: 'Companion face state'),
    );
  }

  /// The face itself, or null when this Eidolon has none.
  Future<Uint8List?> fetchCompanionFace(
    String baseUrl, {
    required String accessToken,
    required String companionId,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}/face',
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    if (response.statusCode == 204) return null;
    if (response.statusCode != 200) {
      throw LocalApiRequestException(
        '主机没有给出这张脸',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<CompanionFaceState> setCompanionFace(
    String baseUrl, {
    required String accessToken,
    required String companionId,
    required Uint8List face,
  }) async {
    final response = await _httpClient
        .put(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}/face',
          ),
          headers: {
            ..._authorizedHeaders(accessToken),
            'content-type': 'image/jpeg',
          },
          body: face,
        )
        .timeout(timeout);
    return CompanionFaceState.fromJson(
      _decodeResponse(response, operation: 'Companion face'),
    );
  }

  Future<CompanionFaceState> clearCompanionFace(
    String baseUrl, {
    required String accessToken,
    required String companionId,
  }) async {
    final response = await _httpClient
        .delete(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}/face',
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return CompanionFaceState.fromJson(
      _decodeResponse(response, operation: 'Companion face'),
    );
  }

  Future<String> renameOwner(
    String baseUrl, {
    required String accessToken,
    required String displayName,
  }) async {
    final response = await _httpClient
        .patch(
          parseBaseUri(baseUrl).resolve('/api/local/v1/owner'),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'display_name': displayName,
          }),
        )
        .timeout(timeout);
    final document = _decodeResponse(response, operation: 'Owner rename');
    final name = document['display_name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('主机没有返回新的名称');
    }
    return name;
  }

  Future<String> renameCompanion(
    String baseUrl, {
    required String accessToken,
    required String companionId,
    required String displayName,
  }) async {
    final response = await _httpClient
        .patch(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}',
          ),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'display_name': displayName,
          }),
        )
        .timeout(timeout);
    final document = _decodeResponse(response, operation: 'Companion rename');
    final name = document['display_name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('主机没有返回新的名称');
    }
    return name;
  }

  Future<List<ControllerGrant>> fetchControllers(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/controllers'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    final document = _decodeResponse(response, operation: 'Controller list');
    final controllers = document['controllers'];
    if (controllers is! List) {
      throw const FormatException('主机没有返回管理手机列表');
    }
    return controllers
        .map(
          (value) => ControllerGrant.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<ControllerInvitation> inviteController(
    String baseUrl, {
    required String accessToken,
    required Duration ttl,
  }) async {
    final response = await _httpClient
        .post(
          parseBaseUri(baseUrl)
              .resolve('/api/local/v1/controllers/invitations'),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({'ttl_seconds': ttl.inSeconds}),
        )
        .timeout(timeout);
    return ControllerInvitation.fromJson(
      _decodeResponse(response, operation: 'Controller invitation'),
    );
  }

  Future<void> revokeController(
    String baseUrl, {
    required String accessToken,
    required String controllerId,
  }) async {
    final response = await _httpClient
        .delete(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/controllers/${Uri.encodeComponent(controllerId)}',
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    _decodeResponse(response, operation: 'Controller revocation');
  }

  /// What has happened to this Owner's devices lately.
  ///
  /// No Owner is named: the session already says whose Host this is.
  Future<HostActivity> fetchActivity(
    String baseUrl, {
    required String accessToken,
    int limit = 50,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/activity').replace(
            queryParameters: {'limit': '$limit'},
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return HostActivity.fromJson(
      _decodeResponse(response, operation: 'Host activity'),
    );
  }

  /// How the machine is doing: disk, memory, load, temperature, uptime.
  Future<HostVitals> fetchHostVitals(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/host/vitals'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return HostVitals.fromJson(
      _decodeResponse(response, operation: 'Host vitals'),
    );
  }

  Future<HostServiceInventory> fetchHostServices(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve('/api/local/v1/host/services'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return HostServiceInventory.fromJson(
      _decodeResponse(response, operation: 'Host services'),
    );
  }

  /// Change one service, carrying the revision this phone actually saw.
  Future<HostServiceChange> changeHostService(
    String baseUrl, {
    required String accessToken,
    required String serviceId,
    required String operation,
    required int expectedRevision,
  }) async {
    if (!const {'restart', 'enable', 'disable'}.contains(operation)) {
      throw FormatException('不支持的服务操作：$operation');
    }
    final response = await _httpClient
        .post(
          _hostServiceUri(baseUrl, serviceId, operation),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({'expected_revision': expectedRevision}),
        )
        .timeout(timeout);
    return HostServiceChange.fromJson(
      _decodeResponse(response, operation: 'Host service change'),
    );
  }

  static Uri _hostServiceUri(
    String baseUrl,
    String serviceId,
    String operation,
  ) {
    final normalized = _boundedId(serviceId, 'service ID');
    return parseBaseUri(baseUrl).replace(
      pathSegments: [
        'api',
        'local',
        'v1',
        'host',
        'services',
        normalized,
        operation,
      ],
    );
  }

  static Uri _deviceRemovalUri(String baseUrl, String deviceId) {
    final normalized = _boundedId(deviceId, 'device ID');
    final base = parseBaseUri(baseUrl);
    return base.replace(
      pathSegments: ['api', 'local', 'v1', 'devices', normalized, 'removal'],
    );
  }

  static Uri _localUri(String baseUrl, List<String> suffix) =>
      parseBaseUri(baseUrl).replace(
        pathSegments: ['api', 'local', 'v1', ...suffix],
      );

  static Uri _deviceEnrollmentsUri(
    String baseUrl, {
    List<String> suffix = const [],
  }) =>
      _localUri(baseUrl, ['device-enrollments', ...suffix]);

  static String _boundedId(String value, String label) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw FormatException('$label 无效');
    }
    return normalized;
  }

  static Map<String, String> _authorizedHeaders(
    String accessToken, {
    bool json = false,
  }) {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw const LocalApiRequestException('Controller session token 为空');
    }
    return {
      'accept': 'application/json',
      'authorization': 'Bearer $token',
      if (json) 'content-type': 'application/json',
    };
  }

  static Map<String, dynamic> _decodeResponse(
    http.Response response, {
    required String operation,
  }) {
    if (response.statusCode != 200) {
      throw LocalApiRequestException(
        '$operation 返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        reason: _refusalReason(response),
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Local API $operation 不是 JSON object');
    }
    return decoded;
  }

  /// The Host's own account of a refusal, when it wrote one for the person.
  ///
  /// Dropping this is how a Host that knew exactly why it refused could only
  /// ever be shown as a status code. Only a tagged `{"reason": ...}` counts: a
  /// bare string detail is a diagnostic naming authorities and contracts, and a
  /// list is request validation naming fields — both are written for whoever
  /// reads the Host, and neither belongs on a screen. Taking those too is how
  /// showing the Host's words turns into leaking its internals.
  static String? _refusalReason(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      final detail = decoded['detail'];
      if (detail is! Map<String, dynamic>) return null;
      final reason = detail['reason'];
      if (reason is! String) return null;
      final trimmed = reason.trim();
      return trimmed.isEmpty || trimmed.length > 300 ? null : trimmed;
    } on FormatException {
      return null;
    }
  }

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}
