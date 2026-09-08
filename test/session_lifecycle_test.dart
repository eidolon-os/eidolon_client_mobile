import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/protocol/eidolon_protocol.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/phone_identity_fixtures.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_standing.dart';

/// What the far end says about a conversation's life, and what this client does
/// with it.
///
/// Both signals travel the reverse direction of `eidolon.session_control`, and
/// before this neither was consumed. The cost was paid twice on real hardware:
/// the screen read 「正在聆听」 from the moment this client *published* its
/// request, once while the Channel Provider was silently discarding that
/// request for want of a `conversation_id`, and again while an agent joined the
/// room and raised `TypeError` a millisecond later. An Owner spoke several
/// sentences into an empty room both times.
///
/// The microphone was genuinely open, so 「正在聆听」 was not a lie about the
/// phone. It was a claim about the far end that the phone had no grounds for —
/// and the firmware has kept the distinction all along as
/// `conversation_confirmed_`.
void main() {
  HubConfig active() => const HubConfig(
        status: HubConfigStatus.active,
        session: RoomConfig(
          serverUrl: 'wss://livekit.invalid',
          token: 'token',
          identity: 'device-instance-x',
          roomName: 'eidolon-device-x',
        ),
        deviceFingerprint: phoneFingerprint,
      );

  ({ClientController controller, _LifecycleSession session}) build() {
    final session = _LifecycleSession();
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: session,
      conversationProvisioner: _FakeProvisioner(active()),
    );
    return (controller: controller, session: session);
  }

  String packet(String type, {String? conversationId, String? reason}) =>
      jsonEncode(<String, Object?>{
        'schema_v': sessionControlSchemaVersion,
        'type': type,
        if (conversationId != null)
          sessionConversationIdField: conversationId,
        if (reason != null) sessionEndReasonField: reason,
      });

  test('a conversation is not confirmed until the far end says so', () async {
    final built = build();
    await built.controller.start();

    // Nothing has answered. This is the state the screen was calling
    // 「正在聆听」.
    expect(built.controller.conversationStanding, ConversationStanding.asked);
    expect(
      built.controller.uiState.conversationStanding.answered,
      isFalse,
      reason: 'the screen has to be able to see this',
    );

    built.session.emit(
      packet(sessionStartedType, conversationId: built.session.conversationId),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      built.controller.conversationStanding,
      ConversationStanding.accepted,
    );
    built.controller.dispose();
  });

  test('a lifecycle packet about another conversation is not about this one',
      () async {
    // The agent's `session_end` for conversation N can arrive after this client
    // has opened N+1. Acting on it would end the wrong conversation — the same
    // mistake the Device Control nonce echo exists to prevent, one topic over.
    final built = build();
    await built.controller.start();

    built.session.emit(
      packet(sessionStartedType, conversationId: 'mobile-someone-else-0001'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      built.controller.conversationStanding.answered,
      isFalse,
      reason: 'confirmed by a packet about a different conversation',
    );
    built.controller.dispose();
  });

  test('an end the service caused is said out loud', () async {
    // The one end a person has to be told about. Leaving quietly is how a
    // phone returns to standby with nothing said about why it stopped, which
    // is what happened while the agent was crashing on startup.
    final built = build();
    await built.controller.start();
    final id = built.session.conversationId;

    built.session.emit(
      packet(sessionEndType, conversationId: id, reason: sessionEndError),
    );
    await Future<void>.delayed(Duration.zero);

    expect(built.controller.failure, isNotNull);
    expect(built.controller.failure!.kind, ClientErrorKind.liveKit);
    expect(built.controller.failure!.technicalDetails, contains('session_end'));
    built.controller.dispose();
  });

  test('an ordinary end is not dressed up as a failure', () async {
    // `user_left`, `idle_normal_end`, `proactive_done`, `superseded` are all
    // ways a conversation legitimately finishes. Reporting one as an error is
    // the mirror image of the bug above, and it is the more likely of the two
    // to get the message ignored.
    final built = build();
    await built.controller.start();
    final id = built.session.conversationId;

    built.session.emit(
      packet(sessionEndType, conversationId: id, reason: 'user_left'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(built.controller.failure, isNull);
    built.controller.dispose();
  });
}

/// A session that carries a conversation id and can be fed lifecycle packets.
///
/// Subclassed rather than mocked because the member under test is what the
/// controller does with a packet, and the real class needs a live LiveKit room
/// to construct anything else.
class _LifecycleSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();
  final _data = StreamController<SessionData>.broadcast();

  /// Shaped the way `_newConversationId` shapes one, so the correlation under
  /// test is against a realistic value rather than a placeholder.
  @override
  String? get conversationId => 'mobile-0123abcd-4567ef89-00000001';

  void emit(String payload) => _data.add(SessionData(sessionControlTopic, payload));

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
