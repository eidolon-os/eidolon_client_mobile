import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../generated/management_v1.dart';

/// What the Host said when it would not answer.
///
/// Kept apart from the status code because the code alone cannot separate "this
/// Host has not been given an Owner yet" from "the authority behind it is
/// down", and a screen keyed on the code has to offer one guess for both.
class ManagementRequestException implements Exception {
  const ManagementRequestException(this.message, {this.statusCode, this.reason});

  final String message;
  final int? statusCode;
  final String? reason;

  /// True when this Host has no Owner yet, so there is nothing to list.
  ///
  /// Deliberately not folded into "empty roster": a person with no Eidolons and
  /// a Host that was never provisioned need different screens, and only one of
  /// them should be offered a create button.
  bool get hostHasNoOwner => statusCode == 409;

  @override
  String toString() => reason == null ? message : '$message：$reason';
}

/// The Owner management surface, and the only thing in this app that speaks it.
///
/// Separate from [LocalApiClient] on purpose. That client is a hand-written
/// accumulation over `/api/local/v1`, grown a method at a time; this boundary is
/// generated from one document that both management clients share, so the types
/// here are never hand-maintained and cannot quietly diverge from the Host or
/// from the Web client. Adding a management call means regenerating, not
/// writing a DTO.
///
/// It never names an Owner. There is no parameter for one, because the Owner is
/// whoever the Controller session belongs to.
class ManagementClient {
  ManagementClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  Future<ManagementContextView> fetchContext(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _get(
      baseUri.resolve(ManagementV1.contextPath),
      accessToken: accessToken,
      what: '读取这台 Host 的管理上下文',
    );
    return ManagementContextView.fromJson(body);
  }

  /// One page of this Owner's Eidolons.
  ///
  /// [cursor] is a value a previous page handed back. It is stored and returned
  /// as-is; reading it would make the Host's page boundary part of this app.
  Future<CompanionRosterView> fetchRoster(
    Uri baseUri, {
    required String accessToken,
    String? cursor,
  }) async {
    var endpoint = baseUri.resolve(ManagementV1.companionsPath);
    if (cursor != null) {
      endpoint = endpoint.replace(queryParameters: {'cursor': cursor});
    }
    final body = await _get(
      endpoint,
      accessToken: accessToken,
      what: '读取这个 Owner 的 Eidolon 列表',
    );
    return CompanionRosterView.fromJson(body);
  }

  /// One Eidolon, opened.
  ///
  /// A Companion that is not this Owner's answers 404, and that is the whole
  /// answer: asking about someone else's id must not tell you it exists.
  Future<CompanionDetailView> fetchCompanion(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
  }) async {
    final body = await _get(
      // The generated helper builds and encodes the path, so nothing here
      // concatenates an id into a URL.
      baseUri.resolve(ManagementV1.companionsByCompanionIdPath(companionId)),
      accessToken: accessToken,
      what: '读取这个 Eidolon',
    );
    return CompanionDetailView.fromJson(body);
  }

  Future<Map<String, dynamic>> _get(
    Uri endpoint, {
    required String accessToken,
    required String what,
  }) async {
    final http.Response response;
    try {
      response = await _httpClient
          .get(endpoint, headers: {'Authorization': 'Bearer $accessToken'})
          .timeout(timeout);
    } on TimeoutException {
      throw ManagementRequestException('$what超时');
    } catch (error) {
      throw ManagementRequestException('$what失败：$error');
    }
    if (response.statusCode != 200) {
      throw ManagementRequestException(
        '$what被拒绝',
        statusCode: response.statusCode,
        reason: _reason(_text(response)),
      );
    }
    final decoded = jsonDecode(_text(response));
    if (decoded is! Map<String, dynamic>) {
      throw ManagementRequestException('$what返回了非契约响应');
    }
    return decoded;
  }

  /// Decoded as UTF-8 unconditionally, not according to the response header.
  ///
  /// JSON is UTF-8 by definition (RFC 8259). `Response.body` instead derives an
  /// encoding from the header and falls back to latin-1 when it cannot, which
  /// would turn an Eidolon named 小忆 into mojibake — silently, because latin-1
  /// decoding never fails. Reading the bytes is one line and removes the
  /// question, which is also what the older Local API client does.
  static String _text(http.Response response) => utf8.decode(response.bodyBytes);

  /// The Host's own words, when it gave any.
  static String? _reason(String body) {
    if (body.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}

/// Whether the Host can do a thing at all — not whether this Controller may.
///
/// A name absent from the map is one this app has heard of and the Host has
/// not: a version skew, and the app is the newer half. A name present and false
/// is a feature this Host cannot do yet. Both mean "do not show the button",
/// and collapsing them would make an old Host look like a new one with
/// everything switched off.
bool hostCan(ManagementContextView context, String capability) =>
    context.capabilities[capability] == true;
