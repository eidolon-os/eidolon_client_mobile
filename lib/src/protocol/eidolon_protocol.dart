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
