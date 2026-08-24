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

  /// 让所有设备重新登录 — end every runtime session this Owner has.
  ///
  /// For a phone that went missing. Every device has to get a new session before
  /// it can talk to an Eidolon again, and they do that on their own — the Host
  /// records an instant and refuses anything issued before it, so this is
  /// recoverable rather than a lockout.
  ///
  /// It does **not** remove any phone's access to *managing* this Host: that is a
  /// Controller grant, revoked from the devices screen.
  Future<RevokedSessionsView> revokeRuntimeSessions(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'POST',
      baseUri.resolve(ManagementV1.ownerActionsRevokeRuntimeSessionsPath),
      accessToken: accessToken,
      what: '让所有设备重新登录',
    );
    return RevokedSessionsView.fromJson(body);
  }

  /// When this Eidolon and I talked.
  ///
  /// Not what was said: the Host keeps words per turn and these rows carry
  /// none, so this is a list of occasions rather than a transcript.
  Future<ConversationPageView> fetchConversations(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    int? limit,
    String? cursor,
  }) async {
    final body = await _get(
      _withQuery(
        baseUri.resolve(
          ManagementV1.companionsByCompanionIdConversationsPath(companionId),
        ),
        {
          if (limit != null) 'limit': '$limit',
          // Opaque both ways: whatever the Host handed back, sent back
          // unread.
          if (cursor != null) 'cursor': cursor,
        },
      ),
      accessToken: accessToken,
      what: '读取对话记录',
    );
    return ConversationPageView.fromJson(body);
  }

  /// What was said that time.
  ///
  /// A page at a time, newest turn first, so [cursor] walks back through the
  /// conversation. Only what I said and what it said: what tools it called to
  /// get there is how the answer was reached, and the Host does not send it.
  Future<TranscriptView> fetchTranscript(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required String conversationId,
    int? limit,
    String? cursor,
  }) async {
    final body = await _get(
      _withQuery(
        baseUri.resolve(
          ManagementV1.companionsByCompanionIdConversationsByConversationIdTurnsPath(
            companionId,
            conversationId,
          ),
        ),
        {
          if (limit != null) 'limit': '$limit',
          if (cursor != null) 'cursor': cursor,
        },
      ),
      accessToken: accessToken,
      what: '读取那次对话',
    );
    return TranscriptView.fromJson(body);
  }

  /// What I asked it to do, and how far it has got.
  Future<TaskPageView> fetchTasks(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    int? limit,
    String? status,
    String? cursor,
  }) async {
    final body = await _get(
      _withQuery(
        baseUri.resolve(
          ManagementV1.companionsByCompanionIdTasksPath(companionId),
        ),
        {
          if (limit != null) 'limit': '$limit',
          if (status != null) 'status': status,
          if (cursor != null) 'cursor': cursor,
        },
      ),
      accessToken: accessToken,
      what: '读取任务',
    );
    return TaskPageView.fromJson(body);
  }

  /// 别做了 — stop a task.
  ///
  /// What comes back is what the Host says the task became. The states belong
  /// to the runtime that runs it, so this may answer that the thing had already
  /// finished while the page was open — which is a refusal, not a failure of
  /// this app.
  Future<TaskView> cancelTask(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required String taskId,
  }) =>
      _taskAction(
        baseUri.resolve(
          ManagementV1.companionsByCompanionIdTasksByTaskIdCancelPath(
            companionId,
            taskId,
          ),
        ),
        accessToken: accessToken,
        what: '取消任务',
      );

  /// 再试一次 — ask for it again. The Host decides whether it can.
  Future<TaskView> retryTask(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required String taskId,
  }) =>
      _taskAction(
        baseUri.resolve(
          ManagementV1.companionsByCompanionIdTasksByTaskIdRetryPath(
            companionId,
            taskId,
          ),
        ),
        accessToken: accessToken,
        what: '重试任务',
      );

  Future<TaskView> _taskAction(
    Uri endpoint, {
    required String accessToken,
    required String what,
  }) async {
    final body = await _send('POST', endpoint, accessToken: accessToken, what: what);
    return TaskView.fromJson(body);
  }

  /// A URL with only the parameters that were actually named.
  ///
  /// Not `replace(queryParameters: …)` with nulls in it: an empty `limit=` is
  /// not a number and an empty `cursor=` is not a position, and a Host is right
  /// to refuse both.
  Uri _withQuery(Uri endpoint, Map<String, String> query) =>
      query.isEmpty ? endpoint : endpoint.replace(queryParameters: query);

  /// What this Eidolon has been.
  ///
  /// A record rather than a settings screen, and no proposal queue: a Companion
  /// considering a change has not changed, and being handed that would turn
  /// living with an Eidolon into appraising it.
  Future<PersonaHistoryView> fetchPersonaHistory(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
  }) async {
    final body = await _get(
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdPersonaHistoryPath(companionId),
      ),
      accessToken: accessToken,
      what: '读取人格变化',
    );
    return PersonaHistoryView.fromJson(body);
  }

  /// Make it the way it was then, and answer with where that leaves it.
  ///
  /// A `PUT` naming the chapter it should be, so the same request twice leaves
  /// the same Eidolon — asking for the chapter it already is succeeds rather than
  /// conflicting. Going back appends to the record instead of rewinding it.
  Future<PersonaHistoryView> restorePersona(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required String chapterId,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdPersonaRestorationsPath(companionId),
      ),
      accessToken: accessToken,
      what: '回到那时候',
      body: {'chapter_id': chapterId},
    );
    return PersonaHistoryView.fromJson(body);
  }

  /// 你还记得…吗 — what it remembers about something.
  ///
  /// The question a person arrives with, and the first memory read this app ever
  /// had: it used to be a hand-written call to `/api/local/v1/recollections`,
  /// which is now deleted. What comes back is a sentence and, when the Host knows
  /// it, when it was laid down — the wings, rooms and scores memory carries are
  /// how it found something rather than what it remembers.
  Future<RecollectionsView> fetchRecollections(
    Uri baseUri, {
    required String accessToken,
    required String query,
    int limit = 10,
    String? companionId,
  }) async {
    final body = await _get(
      baseUri.resolve(ManagementV1.memoryRecollectionsPath).replace(
        queryParameters: {
          'q': query,
          'limit': '$limit',
          if (companionId != null) 'companion_id': companionId,
        },
      ),
      accessToken: accessToken,
      what: '问它记得什么',
    );
    return RecollectionsView.fromJson(body);
  }

  /// A copy of everything my Eidolon remembers that I can see.
  ///
  /// The one read here that shortens nothing. The library rolls up and the day
  /// list pages, because those are pages someone scrolls; this is a file they
  /// keep, and a preview in it would be data loss dressed as a working read.
  ///
  /// [companionId] selects an audience exactly as the library does, for the
  /// same reason: a copy must not be able to see what recall cannot.
  Future<MemoryCopyView> fetchMemoryCopy(
    Uri baseUri, {
    required String accessToken,
    String? companionId,
  }) async {
    final endpoint = baseUri.resolve(ManagementV1.memoryExportPath);
    final body = await _get(
      companionId == null
          ? endpoint
          : endpoint.replace(queryParameters: {'companion_id': companionId}),
      accessToken: accessToken,
      what: '导出记忆',
    );
    return MemoryCopyView.fromJson(body);
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

  /// 只让它记得 — keep this memory between me and one of my Eidolons.
  ///
  /// One call, not two. Forgetting needs a preview because words have to be
  /// resolved into a set; here I am looking at the memory when I name it. And
  /// nothing becomes unrecallable: the Eidolon I gave it to still remembers it,
  /// and sending this again with [companionId] null gives it back to all of them.
  ///
  /// A `PUT`, so a retry after a connection I never saw the answer to changes
  /// nothing twice.
  Future<MemoryAudienceView> assignMemoryAudience(
    Uri baseUri, {
    required String accessToken,
    required String entryId,
    String? companionId,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(
        ManagementV1.memoryEntriesByEntryIdAudiencePath(entryId),
      ),
      accessToken: accessToken,
      what: '设置这条记忆的归属',
      // An empty string rather than a word for "everyone": the Host decides what
      // an audience is, and absence is how this app says all of them.
      body: {'companion_id': companionId ?? ''},
    );
    return MemoryAudienceView.fromJson(body);
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
