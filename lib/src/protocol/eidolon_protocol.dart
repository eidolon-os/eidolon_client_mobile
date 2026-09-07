import 'dart:convert';

const controlTopic = 'eidolon.control';
const clientAudioStateTopic = 'eidolon.audio_state';
const uiStateTopic = 'eidolon.ui_state';
const sessionControlTopic = 'eidolon.session_control';
const transcriptionTopic = 'lk.transcription';
const agentSessionTopic = 'lk.agent.session';

/// Client → server, on [sessionControlTopic]: the other direction of the topic
/// `session_end` arrives on. A client holds its channel open for as long as it
/// is enrolled, so being connected no longer says whether it wants to be heard.
/// Statements of desired state — saying one twice means it once.
const sessionOpenType = 'session_open';
const sessionCloseType = 'session_close';

/// The wire schema version the session-control payload must declare.
///
/// `WIRE_SCHEMA_VERSION` in `eidolon_sdk/biz/contracts`, named here rather than
/// written as a bare `1` at the one call site that needs it.
const sessionControlSchemaVersion = 1;

/// The member naming which conversation a session request is about.
///
/// **Required.** The Channel Provider runs the request through
/// `normalize_conversation_id` and drops it when that returns null — which it
/// does for an absent field — so a payload without this is not a malformed
/// request, it is no request at all. This client omitted it, and the result was
/// a phone that published its microphone into the room, a Provider that
/// subscribed to it, and nothing ever asked an agent to answer. Nothing logged
/// anything.
const sessionConversationIdField = 'conversation_id';

/// The characters and length `normalize_conversation_id` accepts.
///
/// Enforced on this side too, because a rejected id is dropped silently at the
/// far end: the failure would arrive as a conversation that never starts,
/// which is the same symptom as no request at all.
final sessionConversationIdPattern = RegExp(r'^[A-Za-z0-9\-_.:]{1,64}$');

/// Server → client on [sessionControlTopic]: the conversation actually began.
///
/// Not consumed yet. Named so the omission is visible: until it is, this client
/// shows a conversation as live from the moment it *asks* for one, and the
/// firmware distinguishes those two states (`conversation_confirmed_`).
const sessionStartedType = 'session_started';

/// The session-control document, built in one place.
///
/// It lived inline in `EidolonSession` and shipped one member short of the
/// contract — no `conversation_id` — which the Channel Provider drops without
/// logging. The result on hardware was a phone publishing its microphone into
/// the room, the Provider subscribing to it, and no agent ever asked to
/// answer. A wire document with no home is a wire document nothing tests.
///
/// Throws on an id the far end would reject, because there the rejection is
/// silent: a bad id and no request at all produce the same symptom.
Map<String, Object?> sessionRequestPayload({
  required String type,
  required String conversationId,
}) {
  if (type != sessionOpenType && type != sessionCloseType) {
    throw ArgumentError.value(type, 'type', 'not a session request type');
  }
  if (!sessionConversationIdPattern.hasMatch(conversationId)) {
    throw ArgumentError.value(
      conversationId,
      'conversationId',
      'must match the contract: 1-64 of [A-Za-z0-9-_.:]',
    );
  }
  return <String, Object?>{
    'schema_v': sessionControlSchemaVersion,
    'type': type,
    sessionConversationIdField: conversationId,
  };
}

const controlOpRoomJoin = 'room.join';
const sessionIntentField = 'session_intent';
const sessionIntentUserInitiated = 'user_initiated';
const sessionIntentProactive = 'proactive_initiated';

/// Resolves the intent carried by a cross-session `room.join` command.
///
/// Missing and unknown values are normal user-like sessions. Proactive behavior
/// must always be explicitly requested by the trusted Hub orchestrator. This is
/// the same defensive default used by Hub and the ESP32 client.
String roomJoinSessionIntent(Map<String, dynamic> payload) {
  final value = payload[sessionIntentField]?.toString().trim().toLowerCase();
  return value == sessionIntentProactive
      ? sessionIntentProactive
      : sessionIntentUserInitiated;
}

class ControlCommand {
  const ControlCommand({
    required this.id,
    required this.op,
    required this.payload,
    required this.isV1,
    required this.expired,
    this.capabilityVersion = 0,
  });

  final String id;
  final String op;
  final Map<String, dynamic> payload;
  final bool isV1;
  final bool expired;
  final int capabilityVersion;

  static ControlCommand? parse(String raw) {
    try {
      final root = jsonDecode(raw);
      if (root is! Map<String, dynamic>) return null;
      final payload = root['payload'] is Map<String, dynamic>
          ? root['payload'] as Map<String, dynamic>
          : <String, dynamic>{};
      final isV1 = root['v'] == 1 && root['kind'] == 'cmd';
      final op = (root['op'] ??
              root['type'] ??
              root['command'] ??
              payload['op'] ??
              payload['type'] ??
              payload['command'])
          ?.toString();
      if (op == null || op.isEmpty) return null;
      final timestamp = (root['ts'] as num?)?.toInt() ?? 0;
      final ttl = (root['ttl_ms'] as num?)?.toInt() ?? 0;
      final expired = timestamp > 0 &&
          ttl > 0 &&
          DateTime.now().millisecondsSinceEpoch > timestamp + ttl;
      return ControlCommand(
        id: (root['id'] ?? root['command_id'])?.toString() ?? '',
        op: op,
        payload: payload.isEmpty ? root : payload,
        isV1: isV1,
        expired: expired,
        capabilityVersion: (root['capability_version'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

String buildControlAck({
  required ControlCommand command,
  required String deviceId,
  required String status,
  required String code,
  String message = '',
  Map<String, dynamic>? result,
}) {
  return jsonEncode({
    'v': 1,
    'kind': result == null ? 'ack' : 'result',
    if (command.id.isNotEmpty) 'id': 'ack-${command.id}',
    if (command.id.isNotEmpty) 'ref': command.id,
    'device_id': deviceId,
    'op': command.op,
    if (command.capabilityVersion > 0)
      'capability_version': command.capabilityVersion,
    'status': status,
    'code': code,
    if (message.isNotEmpty) 'message': message,
    'ts': DateTime.now().millisecondsSinceEpoch,
    if (result != null) 'result': result,
  });
}
