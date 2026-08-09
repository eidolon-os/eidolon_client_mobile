import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../device_management/mounted_device_models.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/setup_trust.dart';
import 'controller_session.dart';
import 'host_proof.dart';
import 'host_models.dart';
import 'workspace_models.dart';
import 'workspace_runtime_models.dart';

class LocalApiRequestException implements Exception {
  const LocalApiRequestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
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

  Future<HostProof> fetchHostProof(String baseUrl, String challenge) async {
    final baseUri = parseBaseUri(baseUrl);
    final endpoint = baseUri.resolve('/api/local/v1/host/proof');
    final response = await _httpClient
        .post(
          endpoint,
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'contract_version': '1',
            'challenge': challenge,
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw LocalApiRequestException(
        'Eidolon Local API Host proof 返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const SetupTrustException(
        'Local API 返回的 Host proof 不是 JSON object',
      );
    }
    return HostProof.fromJson(decoded);
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
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Local API $operation 不是 JSON object');
    }
    return decoded;
  }

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}
