import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../device_management/mounted_device_models.dart';
import '../device_setup/device_setup_models.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/setup_trust.dart';
import 'controller_grant_models.dart';
import 'controller_session.dart';
import 'host_models.dart';
import 'host_service_models.dart';
import 'persona_history_models.dart';
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
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl)
              .resolve('/api/local/v1/device-onboarding/target'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return DeviceOnboardingTarget.fromJson(
      _decodeResponse(response, operation: 'Device onboarding target'),
    );
  }

  Future<List<PendingDeviceEnrollment>> fetchPendingDeviceEnrollments(
    String baseUrl, {
    required String accessToken,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl)
              .resolve('/api/local/v1/device-enrollments/pending'),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return PendingDeviceEnrollmentPage.fromJson(
      _decodeResponse(response, operation: 'Pending Device enrollments'),
    ).devices;
  }

  Future<DeviceAdmissionProgress> approveDeviceEnrollment(
    String baseUrl, {
    required String accessToken,
    required String requestId,
    required String deviceId,
    String? companionId,
  }) async {
    final response = await _httpClient
        .post(
          _deviceApprovalUri(baseUrl, deviceId),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'request_id': _boundedId(requestId, 'request ID'),
            if (companionId != null) 'companion_id': companionId,
          }),
        )
        .timeout(timeout);
    return DeviceAdmissionProgress.fromJson(
      _decodeResponse(response, operation: 'Device admission'),
    );
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

  Future<PersonaHistory> fetchPersonaHistory(
    String baseUrl, {
    required String accessToken,
    required String companionId,
  }) async {
    final response = await _httpClient
        .get(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}/persona',
          ),
          headers: _authorizedHeaders(accessToken),
        )
        .timeout(timeout);
    return PersonaHistory.fromJson(
      _decodeResponse(response, operation: 'Persona history'),
    );
  }

  Future<PersonaHistory> restorePersona(
    String baseUrl, {
    required String accessToken,
    required String companionId,
    required String chapterId,
  }) async {
    final response = await _httpClient
        .post(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/companions/${Uri.encodeComponent(companionId)}'
            '/persona-restorations',
          ),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'chapter_id': chapterId,
          }),
        )
        .timeout(timeout);
    return PersonaHistory.fromJson(
      _decodeResponse(response, operation: 'Persona restoration'),
    );
  }

  Future<MountedDevice> renameDevice(
    String baseUrl, {
    required String accessToken,
    required String deviceId,
    required String displayName,
  }) async {
    final response = await _httpClient
        .patch(
          parseBaseUri(baseUrl).resolve(
            '/api/local/v1/devices/${Uri.encodeComponent(deviceId)}',
          ),
          headers: _authorizedHeaders(accessToken, json: true),
          body: jsonEncode({
            'contract_version': '1',
            'display_name': displayName,
          }),
        )
        .timeout(timeout);
    return MountedDevice.fromJson(
      _decodeResponse(response, operation: 'Device rename'),
    );
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
          parseBaseUri(baseUrl).resolve('/api/local/v1/controllers/invitations'),
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

  static Uri _deviceApprovalUri(String baseUrl, String deviceId) {
    final normalized = _boundedId(deviceId, 'device ID');
    final base = parseBaseUri(baseUrl);
    return base.replace(
      pathSegments: [
        'api',
        'local',
        'v1',
        'device-enrollments',
        normalized,
        'approval',
      ],
    );
  }

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
