import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/protocol/eidolon_protocol.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/phone_identity_fixtures.dart';

/// Who a transcript line is attributed to, and who this client is entitled to
/// name.
///
/// The far-end label used to be the literal string `'Eidolon'`. It was right
/// for as long as one Companion existed on the Host, and it became wrong the
/// first time a device was bound to a second one — silently, because a name
/// nobody checks cannot fail. That binding is a normal Owner action: the
/// picker for it says "换一个 Companion 不会重新配网，也不会动它的记忆".
///
/// Nothing on the wire tells a Body which Companion is answering. The device's
/// token deliberately carries no `companion_id` — "server-side orchestration
/// is declared where the room is declared, never routed through a credential
/// handed to the device" — so the Host resolves who answers from the Kernel
/// mount at every `session_open`, and the answer can differ between two
/// conversations on one standing channel. The `companion_display_name` this
/// client does know is the name the Owner typed at workspace setup, sent
/// outbound once; it is not this device's binding and goes stale exactly when
/// a switch happens.
///
/// So these tests fix the two halves: the speaker this client *can* identify,
/// and the one it must not invent a name for.
void main() {
  const deviceIdentity = 'device-instance-x';

  HubConfig active() => const HubConfig(
        status: HubConfigStatus.active,
        session: RoomConfig(
          serverUrl: 'wss://livekit.invalid',
          token: 'token',
          identity: deviceIdentity,
          roomName: 'eidolon-device-x',
        ),
        deviceFingerprint: phoneFingerprint,
      );

  ({ClientController controller, _TranscriptSession session}) build() {
    final session = _TranscriptSession();
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: session,
      conversationProvisioner: _FakeProvisioner(active()),
    );
    return (controller: controller, session: session);
  }

  String line({
    required String text,
    String? participantIdentity,
    String? source,
  }) =>
      jsonEncode(<String, Object?>{
        'text': text,
        if (participantIdentity != null)
          'participant_identity': participantIdentity,
        if (source != null) 'source': source,
        'is_final': true,
      });

  test('the Owner is identified by the identity the Provider minted', () async {
    // This equality is not two strings that happen to match. The Provider mints
    // the device token `.with_identity(spec.device_id)` and hands the same
    // value to the client as its session identity, and the agent resolves the
    // runtime from that participant identity — so if it ever drifted the whole
    // session would fail loudly rather than mislabel a line.
    final built = build();
    await built.controller.start();

    built.session.emit(line(text: '你好', participantIdentity: deviceIdentity));
    await Future<void>.delayed(Duration.zero);

    expect(built.controller.transcript.single.speaker, '你');
    built.controller.dispose();
  });

  test('the far end is not given a name this client was never told', () async {
    final built = build();
    await built.controller.start();

    built.session.emit(
      line(text: '在的', participantIdentity: 'agent-AJ_something'),
    );
    await Future<void>.delayed(Duration.zero);

    final speaker = built.controller.transcript.single.speaker;
    // Asserted as a value, not merely as "not Eidolon": a bare `isNot` would
    // still pass if the label became some *other* Companion's name, which is
    // the same defect one identifier along.
    expect(speaker, 'Companion');
    built.controller.dispose();
  });

  test('a line with no identity at all is still not attributed to a name',
      () async {
    // `source`/`role` may be absent — LiveKit's forwarded transcript is not
    // obliged to carry it — and so may the identity. Falling back to a guess
    // is what this test exists to prevent.
    final built = build();
    await built.controller.start();

    built.session.emit(line(text: '嗯'));
    await Future<void>.delayed(Duration.zero);

    expect(built.controller.transcript.single.speaker, 'Companion');
    built.controller.dispose();
  });
}

/// A session that can be fed transcript packets on the transcription topic.
///
/// Subclassed rather than mocked for the same reason as the lifecycle fake:
/// the member under test is what the controller does with a packet, and the
/// real class needs a live LiveKit room to construct anything else.
class _TranscriptSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();
  final _data = StreamController<SessionData>.broadcast();

  void emit(String payload) =>
      _data.add(SessionData(transcriptionTopic, payload));

  @override
  Stream<SessionState> get stateEvents => _states.stream;

  @override
  Stream<SessionData> get dataEvents => _data.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect(RoomConfig config) async {}

  @override
  Future<void> openSession() async {}

  @override
  Future<void> closeSession() async {}

  @override
  Future<void> publishAudioState({
    required bool muted,
    required bool agentSpeaking,
    bool reliable = false,
  }) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await _data.close();
    await super.dispose();
  }
}

class _FakeProvisioner implements ConversationProvisioner {
  _FakeProvisioner(this._config);

  final HubConfig _config;

  @override
  String get serviceName => 'Product Hub';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/descriptor');

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async => _config;
}
