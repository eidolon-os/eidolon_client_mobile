import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../setup/setup_trust.dart';
import 'host_proof.dart';
import 'host_models.dart';

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

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}
