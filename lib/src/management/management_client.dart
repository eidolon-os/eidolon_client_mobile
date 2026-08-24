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
  const ManagementRequestException(this.message,
      {this.statusCode, this.reason});

  final String message;
  final int? statusCode;
  final String? reason;

  /// True when someone else changed this first and this app's view is stale.
  ///
  /// The one refusal a client must answer by re-reading rather than retrying:
  /// retrying a stale write would mean whichever phone is more persistent wins,
  /// which is not what the person at either phone asked for.
  bool get someoneElseChangedIt => statusCode == 409;

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

  /// Make one of this Owner's Eidolons the one that answers by default.
  ///
  /// [expectedRevision] is the Owner revision this app last read — from
  /// `/context`. It is what stops this phone and another one both winning: the
  /// second gets a 409 and has to look again, rather than silently overwriting
  /// a change the person made elsewhere.
  ///
  /// Safe to repeat. The Host states an end rather than a step, so a lost
  /// response is answered by asking again, which is the normal case on a phone.
  Future<CompanionDetailOutcome> setDefaultCompanion(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required int expectedRevision,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(ManagementV1.ownerDefaultCompanionPath),
      accessToken: accessToken,
      what: '设为默认',
      body: {
        'companion_id': companionId,
        'expected_revision': expectedRevision,
      },
    );
    final view = DefaultCompanionView.fromJson(body);
    return CompanionDetailOutcome(
      defaultCompanionId: view.defaultCompanionId,
    );
  }

  /// Add another Eidolon for this Owner.
  ///
  /// [operationId] is this app's, and it must be **the same value on a retry**.
  /// Every identifier the Host derives comes from it, so asking twice with one
  /// id yields one Eidolon; asking twice with two ids yields two. That is the
  /// difference between a lost response costing nothing and costing a duplicate
  /// the person then has to find and remove.
  Future<CreatedCompanion> createCompanion(
    Uri baseUri, {
    required String accessToken,
    required String operationId,
    required String displayName,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(ManagementV1.companionsPath),
      accessToken: accessToken,
      what: '新建 Eidolon',
      body: {'operation_id': operationId, 'display_name': displayName},
    );
    final view = CompanionCreatedView.fromJson(body);
    return CreatedCompanion(
      companionId: view.companionId,
      displayName: view.displayName ?? '',
      created: view.created,
      memoryReady: view.memoryReady,
    );
  }

  /// What this Owner's Eidolons remember, by category.
  ///
  /// [companionId] names an *audience*, not a scope: the memory belongs to the
  /// Owner and every one of their Eidolons reads it. Naming one adds what the
  /// Owner told that one in particular; naming none asks for the shared layer,
  /// which is the safe direction when this app does not know which to ask for.
  Future<MemoryLibraryView> fetchMemoryLibrary(
    Uri baseUri, {
    required String accessToken,
    String? companionId,
  }) async {
    var endpoint = baseUri.resolve(ManagementV1.memoryLibraryPath);
    if (companionId != null) {
      endpoint = endpoint.replace(queryParameters: {'companion_id': companionId});
    }
    final body = await _get(
      endpoint,
      accessToken: accessToken,
      what: '读取记忆库',
    );
    return MemoryLibraryView.fromJson(body);
  }

  /// What it wrote down since [since].
  ///
  /// [since] is this app's to compute, not the Host's: a day depends on where
  /// the person is standing and the Host does not know that. Sent with its
  /// offset so the Host compares instants rather than guessing a timezone.
  Future<MemoryDayView> fetchMemoryEntries(
    Uri baseUri, {
    required String accessToken,
    required DateTime since,
    int? limit,
    String? companionId,
  }) async {
    final body = await _get(
      baseUri.resolve(ManagementV1.memoryEntriesPath).replace(
        queryParameters: {
          // Local time with its offset, not UTC: "today" is the person's day,
          // and the offset is what lets the Host place the instant without
          // knowing where they are.
          'since': since.toIso8601String(),
          if (limit != null) 'limit': '$limit',
          if (companionId != null) 'companion_id': companionId,
        },
      ),
      accessToken: accessToken,
      what: '读取今天记下的',
    );
    return MemoryDayView.fromJson(body);
  }

  /// What forgetting this would remove. Nothing changes.
  ///
  /// Two steps because a topic is not a set. The Host resolves the words once,
  /// shows what it found, and binds *that* into a token; the confirm acts on the
  /// token. Between the two the words could match something else, and acting on
  /// that would remove what the person never saw.
  Future<ForgetProposalView> previewForget(
    Uri baseUri, {
    required String accessToken,
    required String target,
    String? action,
  }) async {
    final body = await _send(
      'POST',
      baseUri.resolve(ManagementV1.memoryForgetPreviewPath),
      accessToken: accessToken,
      what: '查看会忘掉什么',
      body: {'target': target, if (action != null) 'action': action},
    );
    return ForgetProposalView.fromJson(body);
  }

  /// Forget exactly what a preview showed.
  ///
  /// [confirmationToken] is passed back unread. This app cannot interpret it and
  /// must not try to build one: it is what ties the decision to the entries the
  /// person actually looked at.
  Future<ForgetResultView> confirmForget(
    Uri baseUri, {
    required String accessToken,
    required String confirmationToken,
  }) async {
    final body = await _send(
      'POST',
      baseUri.resolve(ManagementV1.memoryForgetConfirmPath),
      accessToken: accessToken,
      what: '忘掉它',
      body: {'confirmation_token': confirmationToken},
    );
    return ForgetResultView.fromJson(body);
  }

  Future<Map<String, dynamic>> _get(
    Uri endpoint, {
    required String accessToken,
    required String what,
  }) =>
      _send('GET', endpoint, accessToken: accessToken, what: what);

  /// One place that talks to the Host, whatever the verb.
  ///
  /// Reads and writes differ only in method and body, deliberately: "how a
  /// refusal is reported" must not come to mean two different things.
  Future<Map<String, dynamic>> _send(
    String method,
    Uri endpoint, {
    required String accessToken,
    required String what,
    Map<String, dynamic>? body,
  }) async {
    final http.Response response;
    try {
      final request = http.Request(method, endpoint)
        ..headers['Authorization'] = 'Bearer $accessToken';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(body);
      }
      response = await http.Response.fromStream(
        await _httpClient.send(request),
      ).timeout(timeout);
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
  static String _text(http.Response response) =>
      utf8.decode(response.bodyBytes);

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

/// An Eidolon that now exists, and what is still coming up behind it.
class CreatedCompanion {
  const CreatedCompanion({
    required this.companionId,
    required this.displayName,
    required this.created,
    required this.memoryReady,
  });

  final String companionId;
  final String displayName;

  /// False when the Host found this operation already carried out. The Eidolon
  /// is there either way; saying "created" twice for one intent would be
  /// telling the person something that did not happen.
  final bool created;

  /// False means its memory is not running yet — not that anything failed. The
  /// Host converges on its own, so the honest word is "still starting".
  final bool memoryReady;
}

/// Where the Owner's pointer ended up, as the Host read it back.
///
/// Its own type rather than a bare String? so a caller cannot mistake "the Host
/// says there is no default" for "the call did not answer".
class CompanionDetailOutcome {
  const CompanionDetailOutcome({required this.defaultCompanionId});

  final String? defaultCompanionId;
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
