// Exercise the SDK event boundary without a network connection.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:collection';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'session_address_candidates_test.dart' show TestRoom, config;

class Participant extends Fake implements RemoteParticipant {
  Participant(this.identity, this.kind);
  @override
  final String identity;
  @override
  final ParticipantKind kind;
}

class ControlRoom extends TestRoom {
  ControlRoom() : super((_) async {});
  @override
  String get name => 'same-room';
  final peers = <String, RemoteParticipant>{};
  @override
  UnmodifiableMapView<String, RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(peers);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only the room provider transport identity authenticates its receipt',
      () async {
    final room = ControlRoom();
    final session = EidolonSession(roomFactory: () => room);
    final received = <SessionData>[];
    final sub = session.dataEvents.listen(received.add);
    await session.connect(config);
    for (final identity in [
      null,
      'device',
      'channel-provider-other',
      'channel-provider-same-room'
    ]) {
      room.events.emit(DataReceivedEvent(
        participant: identity == null
            ? null
            : Participant(identity, ParticipantKind.STANDARD),
        data: utf8.encode('{"sender":"channel-provider-same-room"}'),
        topic: 'eidolon.session_control',
      ));
    }
    await Future<void>.delayed(Duration.zero);
    expect(received.map((event) => event.fromProvider),
        [false, false, false, true]);
    await session.dispose();
    await sub.cancel();
  });

  test('a visible provider cannot make an unattended room look answered',
      () async {
    final room = ControlRoom();
    final session = EidolonSession(roomFactory: () => room);
    final presence = <bool>[];
    final sub = session.farEndPresent.listen(presence.add);
    await session.connect(config);
    final provider =
        Participant('channel-provider-same-room', ParticipantKind.STANDARD);
    room.peers[provider.identity] = provider;
    room.events.emit(ParticipantConnectedEvent(participant: provider));
    await Future<void>.delayed(Duration.zero);
    expect(presence.last, false);
    final agent = Participant('agent', ParticipantKind.AGENT);
    room.peers[agent.identity] = agent;
    room.events.emit(ParticipantConnectedEvent(participant: agent));
    await Future<void>.delayed(Duration.zero);
    expect(presence.last, true);
    room.peers.remove(agent.identity);
    room.events.emit(ParticipantDisconnectedEvent(participant: agent));
    await Future<void>.delayed(Duration.zero);
    expect(presence.last, false);
    await session.dispose();
    await sub.cancel();
  });
}
