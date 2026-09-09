import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/models/conversation_mode.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/phone_identity_fixtures.dart';

class _Platform extends FakePhonePlatform {
  @override
  Future<bool> requestMicrophonePermission() async => true;
}

class _Provisioner implements ConversationProvisioner {
  final modes = <ConversationMode?>[];
  @override
  String get serviceName => 'Host';
  @override
  Uri get serviceUri => Uri.parse('https://host.test');
  @override
  Future<HubConfig> provision(
      {String sessionIntent = '', ConversationMode? mode}) async {
    modes.add(mode);
    return const HubConfig(
        status: HubConfigStatus.active,
        session: RoomConfig(
            serverUrl: 'wss://room.test',
            token: 'token',
            identity: 'device',
            roomName: 'room'));
  }
}

class _Session extends EidolonSession {
  final data = StreamController<SessionData>.broadcast();
  final states = StreamController<SessionState>.broadcast();
  final events = <String>[];
  Completer<void>? opening;
  bool connected = false;
  @override
  Stream<SessionData> get dataEvents => data.stream;
  @override
  Stream<SessionState> get stateEvents => states.stream;
  @override
  String get conversationId => 'test-1';
  @override
  bool get isConnected => connected;
  @override
  Future<void> connect(RoomConfig config) async {
    connected = true;
    events.add('connect');
  }

  @override
  Future<void> openSession() async => events.add('open');
  @override
  Future<void> closeSession() async => events.add('close');
  @override
  Future<void> disconnect() async {
    connected = false;
    events.add('disconnect');
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    if (enabled) await opening?.future;
    events.add('mic-$enabled');
  }

  @override
  Future<void> publishAudioState(
      {required bool muted,
      required bool agentSpeaking,
      bool reliable = false}) async {
    if (mode == ConversationMode.ptt && reliable) events.add('ptt-$pttHeld');
  }

  void emit(String topic, Map<String, Object?> payload) => data.add(SessionData(
      topic, jsonEncode({'conversation_id': conversationId, ...payload})));
  @override
  Future<void> dispose() async {
    await data.close();
    await states.close();
    await super.dispose();
  }
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final mode in ConversationMode.values) {
    test(
        '${mode.name}: explicit start configures mode and waits for confirmation',
        () async {
      final session = _Session();
      final provisioner = _Provisioner();
      final c = ClientController(
          platform: _Platform(),
          session: session,
          conversationProvisioner: provisioner);
      await c.start();
      await c.retry();
      c.onAppResumed();
      expect(session.events, isEmpty);
      expect(provisioner.modes, [null, null]);
      await c.join(mode: mode);
      expect(provisioner.modes.last, mode);
      expect(session.events.take(2), ['connect', 'open']);
      expect(c.microphoneEnabled, false);
      session.emit('eidolon.session_control', {'type': 'session_started'});
      await settle();
      expect(c.microphoneEnabled, mode != ConversationMode.ptt);
      session.emit('lk.transcription',
          {'source': 'user', 'text': '第一轮', 'is_final': true});
      await settle();
      if (mode == ConversationMode.ptt) {
        await c.setPttHeld(true);
        expect(c.microphoneEnabled, true);
        await c.setPttHeld(false);
      } else {
        session.emit('eidolon.ui_state', {'state': 'listening'});
        await settle();
        expect(c.microphoneEnabled, true);
      }

      await c.leave();
      session.states.add(const SessionState('disconnected'));
      c.onAppResumed();
      await settle();
      expect(session.events.where((e) => e == 'connect'), hasLength(1));
      expect(session.events.last, 'disconnect');
      expect(c.microphoneEnabled, false);
      c.dispose();
    });
  }
  test('PTT rapid release is ordered after delayed microphone opening',
      () async {
    final session = _Session();
    final c = ClientController(
        platform: _Platform(),
        session: session,
        conversationProvisioner: _Provisioner());
    await c.start();
    await c.join(mode: ConversationMode.ptt);
    session.emit('eidolon.session_control', {'type': 'session_started'});
    await settle();
    session.events.clear();
    session.opening = Completer<void>();
    final pressed = c.setPttHeld(true);
    await settle();
    final released = c.setPttHeld(false);
    session.opening!.complete();
    await Future.wait([pressed, released]);
    expect(session.events.first, 'ptt-true');
    expect(session.events.last, 'ptt-false');
    expect(session.events.indexOf('mic-false'),
        greaterThan(session.events.indexOf('mic-true')));
    expect(c.microphoneEnabled, false);
    expect(c.pttHeld, false);
    await c.leave();
    c.dispose();
  });
  for (final mode in [
    ConversationMode.halfDuplex,
    ConversationMode.fullDuplex
  ]) {
    test('${mode.name}: playback gating respects manual mute', () async {
      final session = _Session();
      final c = ClientController(
          platform: _Platform(),
          session: session,
          conversationProvisioner: _Provisioner());
      await c.start();
      await c.join(mode: mode);
      session.emit('eidolon.session_control', {'type': 'session_started'});
      await settle();
      session.emit('eidolon.ui_state', {'state': 'speaking'});
      await settle();
      expect(c.microphoneEnabled, mode == ConversationMode.fullDuplex);
      session.emit('eidolon.ui_state', {'state': 'listening'});
      await settle();
      expect(c.microphoneEnabled, true);
      await c.toggleMicrophone();
      session.emit('eidolon.ui_state', {'state': 'speaking'});
      session.emit('eidolon.ui_state', {'state': 'listening'});
      await settle();
      expect(c.microphoneEnabled, false);
      await c.leave();
      c.dispose();
    });
  }
}
