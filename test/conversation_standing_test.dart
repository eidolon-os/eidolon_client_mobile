import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_standing.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/protocol/eidolon_protocol.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/phone_identity_fixtures.dart';

/// What this client claims about a conversation, against what it actually
/// knows.
///
/// Every test here is one sentence the screen used to say without evidence.
/// The two that cost a person something on real hardware:
///
/// 「正在聆听」 from the moment the microphone opened. The far end's
/// `session_started` means it is serving, not that it can hear: the agent's
/// `_warmup_stages` logs a dead STT and carries on by design, so a deaf agent
/// confirms the session and then hears nothing at all.
///
/// 「对话中」 held forever when the agent died. It could not publish
/// `session_end` — the channel was already gone — so no packet arrived and a
/// boolean stayed true, with the microphone open and metered.
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

  ({ClientController controller, _StandingSession session}) build() {
    final session = _StandingSession();
    final controller = ClientController(
      platform: _MicGrantedPlatform(),
      session: session,
      conversationProvisioner: _FakeProvisioner(active()),
    );
    return (controller: controller, session: session);
  }

  String started(String? conversationId) => jsonEncode(<String, Object?>{
        'schema_v': sessionControlSchemaVersion,
        'type': sessionStartedType,
        if (conversationId != null) sessionConversationIdField: conversationId,
      });

  String transcript({
    required String text,
    required bool isFinal,
    String? identity,
  }) =>
      jsonEncode(<String, Object?>{
        'text': text,
        'is_final': isFinal,
        if (identity != null) 'participant_identity': identity,
      });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Start, join, and let the far end confirm — the state every test below
  /// begins from, because the presence signal is only about a conversation
  /// this client is actually in.
  Future<({ClientController controller, _StandingSession session})>
      inConversation() async {
    final built = build();
    await built.controller.start();
    await built.controller.join();
    built.session.emit(
      sessionControlTopic,
      started(built.session.conversationId),
    );
    await settle();
    return built;
  }

  group('serving is not the same fact as hearing', () {
    test('session_started confirms serving and nothing more', () async {
      final built = build();
      await built.controller.start();
      await built.controller.join();
      built.session.emit(
        sessionControlTopic,
        started(built.session.conversationId),
      );
      await settle();

      expect(
        built.controller.conversationStanding,
        ConversationStanding.accepted,
      );
      expect(
        built.controller.conversationStanding.hearsUs,
        isFalse,
        reason: 'a deaf agent reaches session_started too',
      );
      built.controller.dispose();
    });

    test('a final transcript of our own speech is what proves hearing',
        () async {
      final built = build();
      await built.controller.start();
      await built.controller.join();
      built.session.emit(
        sessionControlTopic,
        started(built.session.conversationId),
      );
      built.session.emit(
        transcriptionTopic,
        transcript(text: '你好啊', isFinal: true, identity: deviceIdentity),
      );
      await settle();

      expect(
        built.controller.conversationStanding,
        ConversationStanding.hearing,
      );
      built.controller.dispose();
    });

    test('the far end talking about itself proves nothing about hearing us',
        () async {
      // An agent whose STT is dead still greets: TTS is a separate stage, and
      // a warmup failure in one does not stop the other. So its own speech
      // coming back is exactly the evidence that must not count.
      final built = build();
      await built.controller.start();
      await built.controller.join();
      built.session.emit(
        sessionControlTopic,
        started(built.session.conversationId),
      );
      built.session.emit(
        transcriptionTopic,
        transcript(text: '你好，我在', isFinal: true, identity: 'agent-AJ_x'),
      );
      await settle();

      expect(
        built.controller.conversationStanding,
        ConversationStanding.accepted,
      );
      built.controller.dispose();
    });

    test('an interim transcript is not yet evidence', () async {
      final built = build();
      await built.controller.start();
      await built.controller.join();
      built.session.emit(
        sessionControlTopic,
        started(built.session.conversationId),
      );
      built.session.emit(
        transcriptionTopic,
        transcript(text: '你', isFinal: false, identity: deviceIdentity),
      );
      await settle();

      expect(
        built.controller.conversationStanding,
        ConversationStanding.accepted,
      );
      built.controller.dispose();
    });
  });

  group('a far end that leaves without saying so', () {
    test('an empty room ends the claim, closes the microphone, and says why',
        () async {
      final built = await inConversation();

      built.session.presence(false);
      await settle();

      expect(
        built.controller.conversationStanding,
        ConversationStanding.farEndGone,
      );
      expect(
        built.controller.microphoneEnabled,
        isFalse,
        reason: 'it was open and metered for nobody',
      );
      // Not back to standby: a conversation that was cut off must not be
      // presented as one that finished. That is the dead end this screen was
      // rewritten to delete.
      expect(built.controller.phase, ClientPhase.conversation);
      expect(built.controller.uiState.headline, '对话已中断');
      expect(built.controller.uiState.connectionLabel, '对面已离开');
      built.controller.dispose();
    });

    test('a channel that is already gone is not the far end leaving', () async {
      // On teardown LiveKit reports every remote participant as disconnected.
      // Reporting that as abandonment would put a fault on the screen every
      // time a person pressed 结束对话, and would say a dropped channel twice
      // in two different sets of words.
      final built = await inConversation();

      built.session.connected = false;
      built.session.presence(false);
      await settle();

      expect(
        built.controller.conversationStanding,
        isNot(ConversationStanding.farEndGone),
      );
      built.controller.dispose();
    });

    test('an empty room outside a conversation is not a fault', () async {
      // Standing on the channel with nobody else in the room is the normal
      // resting state of this client: the channel outlives conversations by
      // design. Only a conversation can be abandoned.
      final built = build();
      await built.controller.start();

      built.session.presence(false);
      await settle();

      expect(
        built.controller.conversationStanding,
        isNot(ConversationStanding.farEndGone),
      );
      expect(built.controller.phase, ClientPhase.ready);
      built.controller.dispose();
    });

    test('a late transcript does not resurrect a far end that is gone',
        () async {
      final built = await inConversation();
      built.session.presence(false);
      await settle();

      built.session.emit(
        transcriptionTopic,
        transcript(text: '还在吗', isFinal: true, identity: deviceIdentity),
      );
      await settle();

      expect(
        built.controller.conversationStanding,
        ConversationStanding.farEndGone,
        reason: 'an empty participant list is the harder evidence',
      );
      built.controller.dispose();
    });
  });

  group('an ack says what was done', () {
    String refresh() => jsonEncode(<String, Object?>{
          'v': 1,
          'kind': 'cmd',
          'op': controlOpConfigRefresh,
          'id': 'cmd-1',
        });

    test('a refresh onto a live channel is acked as not yet in force',
        () async {
      final built = build();
      await built.controller.start();
      built.session.published.clear();

      built.session.emit(controlTopic, refresh());
      await settle();
      await settle();

      final ack = built.session.published.last;
      expect(ack, contains('"config_applied":false'));
      expect(ack, contains('channel_in_use'));
      built.controller.dispose();
    });

    test('a refresh that does build the channel is acked as in force',
        () async {
      final built = build();
      await built.controller.start();
      // Down at the moment the refresh lands, which is the case where a
      // refreshed config really does take effect.
      built.session.connected = false;
      built.session.published.clear();

      built.session.emit(controlTopic, refresh());
      await settle();
      await settle();

      final ack = built.session.published.last;
      expect(ack, contains('"config_applied":true'));
      expect(ack, isNot(contains('pending_reason')));
      built.controller.dispose();
    });
  });
}

/// A session whose far end can be emptied, and whose acks can be read back.
class _StandingSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();
  final _data = StreamController<SessionData>.broadcast();
  final _presence = StreamController<bool>.broadcast();

  /// Acks and other control payloads this client published.
  final List<String> published = <String>[];

  bool connected = true;

  @override
  String? get conversationId => 'mobile-0123abcd-4567ef89-00000001';

  void emit(String topic, String payload) =>
      _data.add(SessionData(topic, payload));

  /// Reports occupancy verbatim, the way the real session does.
  ///
  /// Deliberately holds no opinion about when the report is actionable: an
  /// earlier version of this fake implemented that guard itself, so the
  /// product's copy of it was never executed and deleting it left every test
  /// green.
  void presence(bool present) => _presence.add(present);

  @override
  Stream<bool> get farEndPresent => _presence.stream;

  @override
  Stream<SessionState> get stateEvents => _states.stream;

  @override
  Stream<SessionData> get dataEvents => _data.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect(RoomConfig config) async {
    connected = true;
  }

  @override
  Future<void> openSession() async {}

  @override
  Future<void> closeSession() async {}

  @override
  Future<void> publishControl(String payload) async => published.add(payload);

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {}

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
    await _presence.close();
    await super.dispose();
  }
}

/// The one permission `join()` refuses to proceed without.
///
/// The shared fake leaves `requestMicrophonePermission` to the real
/// MethodChannel, which answers null under `flutter test` — so a conversation
/// never actually opened, and every assertion about being in one would have
/// passed for the wrong reason had it not been asserted directly.
class _MicGrantedPlatform extends FakePhonePlatform {
  @override
  Future<bool> requestMicrophonePermission() async => true;
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
