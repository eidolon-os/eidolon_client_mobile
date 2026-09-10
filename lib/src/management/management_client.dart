import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../generated/management_v1.dart';

String _iso8601WithOffset(DateTime value) {
  if (value.isUtc) return value.toIso8601String();
  final offsetMinutes = value.timeZoneOffset.inMinutes;
  final absoluteMinutes = offsetMinutes.abs();
  final hours = (absoluteMinutes ~/ 60).toString().padLeft(2, '0');
  final minutes = (absoluteMinutes % 60).toString().padLeft(2, '0');
  final sign = offsetMinutes < 0 ? '-' : '+';
  return '${value.toIso8601String()}$sign$hours:$minutes';
}

/// What the Host said when it would not answer, in the words it said it in.
///
/// The Host now answers every refusal on this surface with one envelope — see
/// `Refusal` in the generated contract — so this type carries it rather than
/// re-deriving meaning from a status. It used to do the latter, and the result is
/// worth remembering: "this Host has no Owner yet" and "someone else changed
/// this first" are both 409, so the two predicates that were supposed to tell
/// them apart were the same expression, and a lost race on the roster rendered
/// 「这台主机还没有主人」.
///
/// Screens do not read [kind] directly. [refusalText] turns a refusal into a
/// sentence and [canRetry] decides whether to offer one, both in one place —
/// because ten screens each wording a refusal is how 被拒绝 with nothing after
/// it became the app's answer to everything.
class ManagementRequestException implements Exception {
  const ManagementRequestException(
    this.message, {
    this.statusCode,
    this.refusal,
  });

  final String message;
  final int? statusCode;

  /// The refusal the Host gave, in one field.
  ///
  /// Null means nothing was refused: a timeout, a dropped socket, a body this
  /// client could not read at all. A real distinction, and the only one — a Host
  /// too old to publish the envelope still produces one here, derived from its
  /// status, so no caller has to ask "which of the two sentences do I have".
  /// Two places holding the Host's words is the shape of the bug this whole
  /// change removes; it does not get to move into the client.
  final Refusal? refusal;

  /// The Host's own sentence, when it gave one.
  ///
  /// Shown only as a fallback: for a refusal this app understands, its own
  /// wording is better than a relayed one, which is usually operator English.
  String? get reason {
    final relayed = refusal?.reason;
    return relayed == null || relayed.isEmpty ? null : relayed;
  }

  /// Which refusal this is, or null when the answer carried none.
  String? get kind => refusal?.kind;

  /// The Host's own word for what happened in the domain, when it gave one.
  ///
  /// Two of these are questions rather than errors — "this is the Eidolon that
  /// answers you, who should answer instead?" — and a screen can only ask them
  /// if it is told that is what came back.
  String? get code => refusal?.code;

  /// True when someone else changed this first and this app's view is stale.
  ///
  /// The one refusal a client must answer by re-reading rather than retrying:
  /// retrying a stale write would mean whichever phone is more persistent wins,
  /// which is not what the person at either phone asked for.
  ///
  /// Keyed on the kind, not on 409. The Host distinguishes a conflict from a
  /// Host that was never set up; this app must not re-merge them.
  bool get someoneElseChangedIt => kind == 'conflict';

  /// True when this Host has no Owner yet, so there is nothing to list.
  ///
  /// Deliberately not folded into "empty roster": a person with no Eidolons and
  /// a Host that was never provisioned need different screens, and only one of
  /// them should be offered a create button.
  bool get hostHasNoOwner => code == 'host_not_provisioned';

  /// True when this Host was never configured for what was asked.
  ///
  /// The refusal that had no name here until it cost two weeks: a Host missing
  /// an authority credential answered 503, the app called it 被拒绝, and offered
  /// 再试一次 — a button that could never work, on a fault no retry can reach.
  bool get hostIsNotConfigured => kind == 'not_configured';

  /// True when the part of the Host that answers this is not running.
  bool get hostPartIsDown => kind == 'not_running';

  /// True when this device's management authorisation is no longer accepted.
  bool get authorisationRejected => kind == 'denied';

  @override
  String toString() {
    final detail = reason;
    return detail == null ? message : '$message：$detail';
  }
}

/// What to tell a person about a refusal, decided once for every screen.
///
/// [subject] is what the screen was asking for — 「它记住的」,「对话记录」—
/// supplied by the caller because the Host deliberately does not say which of
/// its internal services refused: a screen already knows what it asked for, and
/// naming the authority would put the Host's service graph in a public contract.
///
/// Falls through to the Host's own sentence for a kind this app has not heard
/// of. That is the version-skew case and it must degrade, not fail: a newer Host
/// with a new kind should still be readable on an older phone.
String refusalText(Object error, {required String subject}) {
  if (error is! ManagementRequestException) return '$error';
  if (error.hostHasNoOwner) return '这台主机还没有主人，先完成设置';
  switch (error.kind) {
    case 'not_configured':
      // The refusal that had no sentence at all until it cost two weeks. Says
      // where to go, because nothing on this phone can fix it.
      return '这台主机还没配好$subject，要先在主机上补齐配置';
    case 'not_running':
      return '$subject现在没有响应，可能还没启动';
    case 'denied':
      return '这台手机的管理授权已经失效，请重新连接主机';
    case 'not_found':
      // Also the answer for "not yours", deliberately: saying more would turn
      // any screen keyed on an id into a way to test identifiers.
      return '这台主机上没有$subject';
    case 'conflict':
      return '有人先改过了，这里看到的已经不是最新的';
    case 'invalid':
      return '主机没有接受这次请求';
    case 'upstream':
      return '主机在处理$subject时出错了';
  }
  return '$error';
}

/// The Host's own words about its own fault, when they add something.
///
/// Shown beside [refusalText] rather than instead of it, and only for the three
/// refusals that point at the Host rather than at what the person just did.
/// The composed sentence says what this means and what to do; this says which
/// part broke — "data authority is down", "revocation_kv not configured on
/// agent" — and whoever owns the Host is usually the person holding the phone.
///
/// Withheld for the rest on purpose. A relayed sentence next to 「有人先改过了」
/// or 「主机没有接受这次请求」 adds no information a person can use, and reads as
/// the app leaking its own plumbing.
String? refusalDetail(Object error) {
  if (error is! ManagementRequestException) return null;
  const pointsAtTheHost = {'not_configured', 'not_running', 'upstream'};
  if (!pointsAtTheHost.contains(error.kind)) return null;
  return error.reason;
}

/// Whether offering 再试一次 is honest for this refusal.
///
/// A retry button on a Host that was never configured is a promise the product
/// cannot keep, and it was the one this app showed for exactly that case. The
/// Host says whether waiting could change the answer; this asks it rather than
/// guessing from a status.
bool canRetry(Object error) {
  if (error is! ManagementRequestException) return true;
  final refusal = error.refusal;
  if (refusal == null) return true;
  return refusal.retryable ?? false;
}

/// A face this app holds, and which one it is.
///
/// The digest travels with the bytes so the next read can say "still this one"
/// and send nothing. `bytes == null` means the Eidolon has no picture — an
/// ordinary state, distinct from not having asked.
class CompanionFacePicture {
  const CompanionFacePicture({required this.bytes, this.sha256});

  const CompanionFacePicture.none() : bytes = null, sha256 = null;

  final Uint8List? bytes;
  final String? sha256;

  bool get hasFace => bytes != null;
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
    bool? ownsHttpClient,
    this.timeout = const Duration(seconds: 8),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = ownsHttpClient ?? httpClient == null;

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

  /// What this Host observed of the Owner's runtime, lane by lane.
  ///
  /// Returned raw. This is the one management payload the app parses itself:
  /// its authority is the SDK contract at
  /// `eidolon_sdk/contracts/mission_control/v1/mission-control-snapshot.schema.json`,
  /// the Host produces it against that schema and `cockpit_wire.dart` reads it
  /// against the same goldens — so a generated view type here would be a third
  /// description of one shape, and the one most likely to be quietly wrong.
  Future<Map<String, Object?>> fetchMissionControlSnapshot(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _get(
      baseUri.resolve(ManagementV1.missionControlSnapshotPath),
      accessToken: accessToken,
      what: '读取这台 Host 的运行投影',
    );
    return body;
  }

  /// One page of what has happened here, newest first.
  ///
  /// Raw for the same reason the snapshot is: the rows are the SDK contract's
  /// activity shape, and `cockpit_wire.dart` already reads that shape against
  /// the same goldens.
  ///
  /// [cursor] is a value a previous page handed back as `next_cursor`, stored
  /// and returned untouched. Reading it would make the Host's page boundary
  /// part of this app — it is a timestamp today and does not have to stay one.
  Future<Map<String, Object?>> fetchActivityHistory(
    Uri baseUri, {
    required String accessToken,
    String? cursor,
  }) async {
    final path = ManagementV1.missionControlActivitiesPath;
    final uri = baseUri.resolve(
      cursor == null || cursor.isEmpty
          ? path
          : '$path?cursor=${Uri.encodeQueryComponent(cursor)}',
    );
    return _get(uri, accessToken: accessToken, what: '读取这里发生过的事');
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
    return CompanionDetailOutcome(defaultCompanionId: view.defaultCompanionId);
  }

  /// What has been done to this Owner's things lately.
  ///
  /// [cursor] is a position the Host handed out; this app stores it and sends it
  /// back, and never builds one. Running out of them means "no further back
  /// from here", which is not the same as nothing having happened.
  Future<ActivityView> fetchActivity(
    Uri baseUri, {
    required String accessToken,
    int? limit,
    String? cursor,
  }) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    };
    final body = await _send(
      'GET',
      baseUri
          .resolve(ManagementV1.activityPath)
          .replace(queryParameters: query.isEmpty ? null : query),
      accessToken: accessToken,
      what: '读取主机动态',
    );
    return ActivityView.fromJson(body);
  }

  /// How the machine holding this Eidolon is doing.
  ///
  /// Already phrased and already judged by the Host — this app does no
  /// arithmetic on bytes and applies no thresholds of its own, because the same
  /// decision made in two places drifts.
  Future<HostMonitorWire> fetchHostMonitor(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.hostMonitorPath),
      accessToken: accessToken,
      what: '读取主机监控',
    );
    final snapshot = HostMonitorWire.fromJson(body);
    if (DateTime.tryParse(snapshot.observedAt) == null) {
      throw const FormatException('监控快照时间不可读');
    }
    return snapshot;
  }

  Future<HostVitalsView> fetchHostVitals(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.hostVitalsPath),
      accessToken: accessToken,
      what: '读取主机状态',
    );
    return HostVitalsView.fromJson(body);
  }

  /// What is running on the machine, and what is meant to be.
  Future<HostServiceInventoryView> fetchHostServices(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.hostServicesPath),
      accessToken: accessToken,
      what: '读取主机服务',
    );
    return HostServiceInventoryView.fromJson(body);
  }

  /// Restart it, turn it on, turn it off.
  ///
  /// [expectedRevision] is the one this screen was showing. Two phones looking
  /// at the same failing service must not both act on a picture one of them has
  /// already changed.
  Future<HostServiceMutationView> changeHostService(
    Uri baseUri, {
    required String accessToken,
    required String serviceId,
    required String operation,
    required int expectedRevision,
  }) async {
    final body = await _send(
      'POST',
      baseUri.resolve(
        ManagementV1.hostServicesByServiceIdByOperationPath(
          serviceId,
          operation,
        ),
      ),
      accessToken: accessToken,
      what: '操作主机服务',
      body: {'expected_revision': expectedRevision},
    );
    return HostServiceMutationView.fromJson(body);
  }

  /// What is mine, right now.
  ///
  /// One read when a screen opens: who I am, who answers when I named nobody,
  /// what is waiting, and which parts the Host could not read. Composed on that
  /// side because the answer needs five sources, and a phone composing it badly
  /// is four round trips and a screen drawn in pieces.
  Future<HomeView> fetchHome(Uri baseUri, {required String accessToken}) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.homePath),
      accessToken: accessToken,
      what: '读取这台主机的概览',
    );
    return HomeView.fromJson(body);
  }

  /// Every device that is mine.
  ///
  /// Composed and phrased by the Host — it is the side that can see both the
  /// Claim and the mount — so this app switches on a state rather than deriving
  /// one from two authorities it would have to reason about together.
  Future<DevicesView> fetchDevices(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.devicesPath),
      accessToken: accessToken,
      what: '读取我的设备',
    );
    return DevicesView.fromJson(body);
  }

  /// Say which Eidolon answers through one device, or that none does.
  ///
  /// [expectedRevision] is what the screen was showing, and [requestId] must be
  /// the same value on a retry — two phones pointing one device at different
  /// Eidolons must not take turns without noticing.
  Future<DeviceView> setDeviceCompanion(
    Uri baseUri, {
    required String accessToken,
    required String deviceId,
    required String? companionId,
    required int expectedRevision,
    required String requestId,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(ManagementV1.devicesByDeviceIdCompanionPath(deviceId)),
      accessToken: accessToken,
      what: '设置由谁应答',
      body: {
        'companion_id': companionId,
        'expected_revision': expectedRevision,
        'request_id': requestId,
      },
    );
    return DeviceView.fromJson(body);
  }

  /// Take a device off this Host.
  ///
  /// The answer says which facts are settled rather than a percentage: three
  /// authorities converge on their own schedule, and "unfinished" is the
  /// ordinary middle state.
  Future<DeviceRemovalView> removeDevice(
    Uri baseUri, {
    required String accessToken,
    required String deviceId,
    required String requestId,
  }) async {
    final body = await _send(
      'POST',
      baseUri.resolve(ManagementV1.devicesByDeviceIdRemovalPath(deviceId)),
      accessToken: accessToken,
      what: '移除设备',
      body: {'request_id': requestId},
    );
    return DeviceRemovalView.fromJson(body);
  }

  /// Which phones may manage this Host.
  ///
  /// Answered to a phone that already may. Each row says whether it is the
  /// phone asking, computed by the Host from the session — so this app never
  /// has to work out which row is itself, and cannot get it wrong.
  Future<ControllersView> fetchControllers(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.controllersPath),
      accessToken: accessToken,
      what: '读取管理这台主机的手机',
    );
    return ControllersView.fromJson(body);
  }

  /// Open a window in which one more phone may claim this Host.
  ///
  /// The answer is a one-time code and the moment it stops working. Both are
  /// shown together, because a code without its deadline is how someone reads
  /// it out five minutes too late and concludes the Host is broken.
  Future<ControllerInvitationView> inviteController(
    Uri baseUri, {
    required String accessToken,
    required Duration ttl,
  }) async {
    final body = await _send(
      'POST',
      baseUri.resolve(ManagementV1.controllersInvitationsPath),
      accessToken: accessToken,
      what: '邀请另一台手机',
      body: {'ttl_seconds': ttl.inSeconds},
    );
    return ControllerInvitationView.fromJson(body);
  }

  /// Withdraw a phone's authority over this Host.
  ///
  /// A phone may withdraw its own. What it cannot do is leave the Host with
  /// nobody, and that refusal is the Host's — this app does not pre-judge it.
  Future<ControllerView> revokeController(
    Uri baseUri, {
    required String accessToken,
    required String controllerId,
  }) async {
    final body = await _send(
      'DELETE',
      baseUri.resolve(ManagementV1.controllersByControllerIdPath(controllerId)),
      accessToken: accessToken,
      what: '收回这台手机的管理权',
    );
    return ControllerView.fromJson(body);
  }

  /// Whether this Eidolon has a face, and which one.
  ///
  /// Cheap enough to ask on every refresh: the answer is a hash, so a screen
  /// learns its picture is stale without carrying a second picture over to
  /// compare.
  Future<CompanionFaceView> fetchCompanionFaceState(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdFaceStatePath(companionId),
      ),
      accessToken: accessToken,
      what: '读取这张脸的状态',
    );
    return CompanionFaceView.fromJson(body);
  }

  /// The face itself, and which one it is.
  ///
  /// [held] is what this app already has. The Host answers 304 and no bytes
  /// when it still matches, so reopening a screen costs nothing — which matters
  /// here and nowhere else on this surface, because this is the one answer
  /// measured in megabytes and the link is a house's wifi.
  ///
  /// One call rather than "ask the hash, then ask for the picture": the answer
  /// carries which face it is, so there is nothing left to look up.
  Future<CompanionFacePicture> fetchCompanionFace(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    CompanionFacePicture? held,
  }) async {
    final endpoint = baseUri.resolve(
      ManagementV1.companionsByCompanionIdFacePath(companionId),
    );
    final http.Response response;
    try {
      final request = http.Request('GET', endpoint)
        ..headers['Authorization'] = 'Bearer $accessToken';
      if (held?.sha256 != null) {
        request.headers['If-None-Match'] = '"sha256:${held!.sha256}"';
      }
      response = await http.Response.fromStream(
        await _httpClient.send(request),
      ).timeout(timeout);
    } on TimeoutException {
      throw ManagementRequestException('读取这张脸超时');
    } catch (error) {
      throw ManagementRequestException('读取这张脸失败：$error');
    }
    if (response.statusCode == 304 && held != null) return held;
    // No face is a state, not a failure: an Eidolon nobody has given a picture
    // to is an ordinary thing to be.
    if (response.statusCode == 204) return const CompanionFacePicture.none();
    if (response.statusCode != 200) {
      throw ManagementRequestException(
        '主机没有给出这张脸',
        statusCode: response.statusCode,
      );
    }
    return CompanionFacePicture(
      bytes: response.bodyBytes,
      sha256: _etagDigest(response.headers['etag']),
    );
  }

  /// The digest inside an ETag, when the Host wrote one in the shape we know.
  static String? _etagDigest(String? etag) {
    if (etag == null) return null;
    final value = etag.trim().replaceAll('"', '');
    const prefix = 'sha256:';
    return value.startsWith(prefix) ? value.substring(prefix.length) : null;
  }

  /// Give this Eidolon a face. The photograph is the body of the request.
  ///
  /// What may be sent — a JPEG, and not an unbounded one — is the Host's answer
  /// and is not re-checked here; a second copy of that rule would drift from the
  /// one that actually stores the file.
  Future<CompanionFaceView> setCompanionFace(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required Uint8List face,
  }) async {
    final endpoint = baseUri.resolve(
      ManagementV1.companionsByCompanionIdFacePath(companionId),
    );
    final http.Response response;
    try {
      final request = http.Request('PUT', endpoint)
        ..headers['Authorization'] = 'Bearer $accessToken'
        ..headers['Content-Type'] = 'image/jpeg'
        ..bodyBytes = face;
      response = await http.Response.fromStream(
        await _httpClient.send(request),
      ).timeout(timeout);
    } on TimeoutException {
      throw ManagementRequestException('换脸超时');
    } catch (error) {
      throw ManagementRequestException('换脸失败：$error');
    }
    if (response.statusCode != 200) {
      final body = _text(response);
      throw ManagementRequestException(
        '换脸被拒绝',
        statusCode: response.statusCode,
        refusal:
            _refusal(body) ?? _refusalFromStatus(response.statusCode, body),
      );
    }
    return CompanionFaceView.fromJson(
      jsonDecode(_text(response)) as Map<String, dynamic>,
    );
  }

  /// Take the face away and leave the Eidolon.
  Future<CompanionFaceView> clearCompanionFace(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
  }) async {
    final body = await _send(
      'DELETE',
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdFacePath(companionId),
      ),
      accessToken: accessToken,
      what: '收起这张脸',
    );
    return CompanionFaceView.fromJson(body);
  }

  /// Call this Eidolon something else.
  ///
  /// The name is the person's word for it: nothing here suggests one, tidies
  /// one, or refuses one for being unusual — only a blank name is refused, and
  /// the Host refuses that too.
  ///
  /// The answer carries the Companion's new revision, because renaming writes
  /// it. A screen holding the old one would fail its next compare-and-set for a
  /// reason it could not see.
  Future<CompanionNameView> renameCompanion(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required String displayName,
  }) async {
    final body = await _send(
      'PATCH',
      baseUri.resolve(ManagementV1.companionsByCompanionIdPath(companionId)),
      accessToken: accessToken,
      what: '改名',
      body: {'display_name': displayName},
    );
    return CompanionNameView.fromJson(body);
  }

  /// Change what I am called.
  ///
  /// Nothing in the request says who: the session already did.
  Future<OwnerNameView> renameOwner(
    Uri baseUri, {
    required String accessToken,
    required String displayName,
  }) async {
    final body = await _send(
      'PATCH',
      baseUri.resolve(ManagementV1.ownerPath),
      accessToken: accessToken,
      what: '改名',
      body: {'display_name': displayName},
    );
    return OwnerNameView.fromJson(body);
  }

  /// Put one of this Owner's Eidolons away, or bring it back.
  ///
  /// A `PUT` naming the state it should end in, so asking twice is safe and
  /// asking for the state it is already in succeeds — which is what a phone
  /// does after a lost response, and what a second tap on a stale screen is.
  ///
  /// Putting away stops new conversations from reaching it and keeps everything
  /// it remembers; nothing is deleted. If this is the Eidolon that answers when
  /// nobody was named, the Host refuses with `default_replacement_required`
  /// rather than choosing a successor — [replacementCompanionId] is how the
  /// person answers that question.
  ///
  /// Bringing one back does not make it the default again. That is a separate
  /// thing they decided.
  Future<CompanionLifecycleView> setCompanionLifecycle(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required String lifecycleState,
    String? replacementCompanionId,
    int? expectedRevision,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdLifecyclePath(companionId),
      ),
      accessToken: accessToken,
      what: lifecycleState == 'archived' ? '收起来' : '让它回来',
      body: {
        'lifecycle_state': lifecycleState,
        if (replacementCompanionId != null)
          'replacement_companion_id': replacementCompanionId,
        if (expectedRevision != null) 'expected_revision': expectedRevision,
      },
    );
    return CompanionLifecycleView.fromJson(body);
  }

  /// Add another Eidolon for this Owner.
  ///
  /// [operationId] is this app's, and it must be **the same value on a retry**.
  /// Every identifier the Host derives comes from it, so asking twice with one
  /// id yields one Eidolon; asking twice with two ids yields two. That is the
  /// difference between a lost response costing nothing and costing a duplicate
  /// the person then has to find and remove.
  /// Who an Eidolon would be if the create form came back untouched.
  ///
  /// Read from the Host rather than kept here as constants. The value of it is
  /// that it is what the Host would actually write, so a copy on this side would
  /// show a personality this Host might not use — and the person would have
  /// edited a description of something else.
  Future<PersonaAuthoring> personaAuthoringTemplate(
    Uri baseUri, {
    required String accessToken,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(ManagementV1.personaAuthoringTemplatePath),
      accessToken: accessToken,
      what: '读取人格起点',
    );
    return PersonaAuthoring.fromJson(body);
  }

  /// Who this Eidolon is now, in the words somebody wrote.
  ///
  /// The read the edit screen opens on. Editing has to start from who it
  /// currently is, or saving would replace everything the person did not
  /// retype with whatever the form happened to be showing.
  Future<PersonaAuthoring> fetchPersona(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
  }) async {
    final body = await _send(
      'GET',
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdPersonaPath(companionId),
      ),
      accessToken: accessToken,
      what: '读取它是谁',
    );
    return PersonaAuthoring.fromJson(body);
  }

  /// Say who this Eidolon is now. Appends a chapter; never edits one.
  Future<PersonaAuthoring> setPersona(
    Uri baseUri, {
    required String accessToken,
    required String companionId,
    required PersonaAuthoring persona,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(
        ManagementV1.companionsByCompanionIdPersonaPath(companionId),
      ),
      accessToken: accessToken,
      what: '改它是谁',
      body: persona.toJson(),
    );
    return PersonaAuthoring.fromJson(body);
  }

  Future<CreatedCompanion> createCompanion(
    Uri baseUri, {
    required String accessToken,
    required String operationId,
    required String displayName,
    PersonaAuthoring? persona,
  }) async {
    final body = await _send(
      'PUT',
      baseUri.resolve(ManagementV1.companionsPath),
      accessToken: accessToken,
      what: '新建 Eidolon',
      body: {
        'operation_id': operationId,
        'display_name': displayName,
        // Omitted rather than null when nobody wrote anything: the Host
        // fingerprints the request, so sending a blank persona would turn a
        // retry after a lost answer into a conflict instead of a replay.
        if (persona != null) 'persona': persona.toJson(),
      },
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
  /// The physical Realm belongs to the Owner; [companionId] selects the logical
  /// audience inside it. Naming one reads that Companion's private memory plus
  /// the automatically derived Owner facts. Naming none reads only that derived
  /// shared layer and never guesses a Companion.
  Future<MemoryLibraryView> fetchMemoryLibrary(
    Uri baseUri, {
    required String accessToken,
    String? companionId,
  }) async {
    var endpoint = baseUri.resolve(ManagementV1.memoryLibraryPath);
    if (companionId != null) {
      endpoint = endpoint.replace(
        queryParameters: {'companion_id': companionId},
      );
    }
    final body = await _get(endpoint, accessToken: accessToken, what: '读取记忆库');
    return MemoryLibraryView.fromJson(body);
  }

  Future<MemoryGraphView> fetchMemoryGraph(
    Uri baseUri, {
    required String accessToken,
    String? companionId,
  }) async {
    var endpoint = baseUri.resolve(ManagementV1.memoryGraphPath);
    if (companionId != null) {
      endpoint = endpoint.replace(
        queryParameters: {'companion_id': companionId},
      );
    }
    final body = await _get(
      endpoint,
      accessToken: accessToken,
      what: '读取记忆关系图',
    );
    return MemoryGraphView.fromJson(body);
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
      baseUri
          .resolve(ManagementV1.memoryEntriesPath)
          .replace(
            queryParameters: {
              // Local time with its offset, not UTC: "today" is the person's day,
              // and the offset is what lets the Host place the instant without
              // knowing where they are.
              'since': _iso8601WithOffset(since),
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
  }) => _taskAction(
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
  }) => _taskAction(
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
    final body = await _send(
      'POST',
      endpoint,
      accessToken: accessToken,
      what: what,
    );
    return TaskView.fromJson(body);
  }

  /// A URL with only the parameters that were actually named.
  ///
  /// Not `replace(queryParameters: …)` with nulls in it: an empty `limit=` is
  /// not a number and an empty `cursor=` is not a position, and a Host is right
  /// to refuse both.
  Uri _withQuery(Uri endpoint, Map<String, String> query) =>
      query.isEmpty ? endpoint : endpoint.replace(queryParameters: query);

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
      baseUri
          .resolve(ManagementV1.memoryRecollectionsPath)
          .replace(
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

  Future<Map<String, dynamic>> _get(
    Uri endpoint, {
    required String accessToken,
    required String what,
  }) => _send('GET', endpoint, accessToken: accessToken, what: what);

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
      final body = _text(response);
      throw ManagementRequestException(
        '$what被拒绝',
        statusCode: response.statusCode,
        refusal:
            _refusal(body) ?? _refusalFromStatus(response.statusCode, body),
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

  /// The refusal the Host published, when the answer carried one.
  ///
  /// One shape to read, because the Host now publishes one: `Refusal` under
  /// `detail`, declared in the contract this file is generated from. There used
  /// to be two here and a guess between them, and the guess is what dropped the
  /// only fact that mattered — an authority credential this Host was never
  /// given — on its way to the screen.
  ///
  /// Forgiving about anything else: a body this cannot read yields null rather
  /// than an exception. A client that threw while reading an error would replace
  /// a refusal a person could act on with a crash nobody can.
  static Refusal? _refusal(String body) {
    final detail = _detail(body);
    if (detail is! Map) return null;
    final kind = detail['kind'];
    if (kind is! String) return null;
    try {
      return Refusal.fromJson(Map<String, dynamic>.from(detail));
    } on Object {
      return null;
    }
  }

  /// A refusal derived from the status, for a Host too old to publish one.
  ///
  /// The version-skew path, and forgiving on purpose: a client that failed on a
  /// body it did not recognise would turn "the Host is a release behind" into a
  /// screen with nothing on it. The mapping mirrors the one the Host uses for
  /// the same purpose — a fallback each side must be able to reach alone, which
  /// is why it is not in the shared contract.
  static Refusal _refusalFromStatus(int statusCode, String body) {
    const byStatus = <int, String>{
      400: 'invalid',
      401: 'denied',
      403: 'denied',
      404: 'not_found',
      409: 'conflict',
      412: 'conflict',
      415: 'invalid',
      422: 'invalid',
    };
    return Refusal(
      kind:
          byStatus[statusCode] ?? (statusCode >= 500 ? 'upstream' : 'invalid'),
      reason: _sentence(body),
      retryable: statusCode >= 500,
    );
  }

  /// The older shapes: a bare sentence, or `{code, message}`.
  static String? _sentence(String body) {
    final detail = _detail(body);
    if (detail is String) {
      return detail;
    }
    if (detail is Map && detail['message'] is String) {
      return detail['message'] as String;
    }
    return null;
  }

  static Object? _detail(String body) {
    if (body.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return decoded['detail'];
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

/// What a held-back control says, by reason.
///
/// Declared here, once, because these words appear on controls in three
/// different features and a second literal of them is how two rows come to
/// describe the same state differently. This file already owns what the Host's
/// answers read as (see [refusalText]); a label for "the Host is not offering
/// this" belongs beside them.
const holdNotBuilt = '尚未开放';
const holdHostNotConfigured = '主机未配置';
const holdUnknownReason = '暂不可用';

/// Why this Host is not offering something, in words for the person holding it.
///
/// Null when the Host can do it, or when it cannot and said nothing useful
/// about why. Non-null is a label for a held-back row: the feature exists in
/// this app, this Host is not offering it, and here is which kind of not.
///
/// Two reasons rather than one, because they lead completely different places.
/// `not_built` is a release nobody has cut and there is nothing to be done about
/// it tonight. `host_not_configured` is a credential this Host was never given —
/// a command somebody can run — and on this product the person holding the phone
/// is usually the person who owns the Host. Folding them was what turned a
/// missing credential into two weeks of guessing.
///
/// A reason this build has not heard of degrades to the neutral label rather
/// than being dropped: the Host may be newer than the phone.
String? capabilityHold(ManagementContextView context, String capability) {
  if (hostCan(context, capability)) return null;
  switch (context.unavailable?[capability]) {
    case 'host_not_configured':
      return holdHostNotConfigured;
    case 'not_built':
      return holdNotBuilt;
  }
  return holdUnknownReason;
}
