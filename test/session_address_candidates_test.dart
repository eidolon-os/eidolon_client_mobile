import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';

class TestRoom extends Room {
  TestRoom(this.attempt);
  final Future<void> Function(String) attempt;
  int releases = 0;
  @override
  Future<void> connect(String url, String token,
          {ConnectOptions? connectOptions,
          RoomOptions? roomOptions,
          FastConnectOptions? fastConnectOptions}) =>
      attempt(url);
  @override
  Future<void> disconnect() async {}
  @override
  Future<bool> dispose() async {
    releases++;
    return super.dispose();
  }
}

const config = RoomConfig(
    serverUrl: 'ws://old:7880',
    token: 'same-token',
    identity: 'device',
    roomName: 'same-room',
    serverUrls: ['ws://old:7880', 'ws://reachable:7880']);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'failed candidate is disposed before trying another and emits no terminal state',
      () async {
    final tried = <String>[];
    final rooms = <TestRoom>[];
    final session = EidolonSession(roomFactory: () {
      if (rooms.isNotEmpty) expect(rooms.last.releases, 1);
      final room = TestRoom((url) async {
        tried.add(url);
        if (url.contains('old')) throw StateError('unreachable');
      });
      rooms.add(room);
      return room;
    });
    final states = <String>[];
    final subscription =
        session.stateEvents.listen((event) => states.add(event.state));
    await session.connect(config);
    await Future<void>.delayed(Duration.zero);
    expect(tried, config.serverUrls);
    expect(states, ['connecting', 'connected']);
    await session.dispose();
    expect(rooms.map((r) => r.releases), [1, 1]);
    await subscription.cancel();
  });

  test('cancelled connection cannot try another candidate or publish connected',
      () async {
    final pending = Completer<void>();
    final started = Completer<void>();
    var attempts = 0;
    final session = EidolonSession(
        roomFactory: () => TestRoom((url) {
              attempts++;
              started.complete();
              return pending.future;
            }));
    final states = <String>[];
    final subscription =
        session.stateEvents.listen((event) => states.add(event.state));
    final connecting = session.connect(config);
    final result = expectLater(connecting, throwsStateError);
    await started.future;
    await session.disconnect();
    pending.complete();
    await result;
    expect(attempts, 1);
    expect(states, isNot(contains('connected')));
    await session.dispose();
    await subscription.cancel();
  });
  test('all candidates failing releases every room and reports failure',
      () async {
    final rooms = <TestRoom>[];
    final session = EidolonSession(roomFactory: () {
      final room = TestRoom((_) async => throw StateError('unreachable'));
      rooms.add(room);
      return room;
    });
    await expectLater(session.connect(config), throwsStateError);
    expect(rooms, hasLength(2));
    expect(rooms.map((room) => room.releases), [1, 1]);
    await session.dispose();
  });

  test('late prior connection cannot destroy a replacement connection',
      () async {
    final pending = Completer<void>();
    final started = Completer<void>();
    var count = 0;
    final rooms = <TestRoom>[];
    final session = EidolonSession(roomFactory: () {
      final first = count++ == 0;
      final room = TestRoom((_) async {
        if (first) {
          started.complete();
          await pending.future;
        }
      });
      rooms.add(room);
      return room;
    });
    final first = expectLater(session.connect(config), throwsStateError);
    await started.future;
    await session.connect(config);
    pending.complete();
    await first;
    expect(rooms, hasLength(2));
    expect(rooms.first.releases, 1);
    expect(rooms.last.releases, 0);
    await session.dispose();
  });
}
