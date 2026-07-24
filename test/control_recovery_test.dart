import 'dart:async';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:eidolon_client_mobile/src/services/hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const room = RoomConfig(
    serverUrl: 'ws://hub.local:7880',
    token: 'token',
    identity: 'mobile-test',
    roomName: 'mobile-test-control',
  );
  const active = HubConfig(
    status: HubConfigStatus.active,
    active: room,
    control: room,
  );
  const hub = HubService(
    instanceName: 'Test Hub',
    registerUrl: 'http://hub.local/api/device/register',
  );

  test('control reconnect watchdog refreshes config without waiting for SDK',
      () async {
    final session = _FakeSession();
    final hubClient = _FakeHubClient(active);
    final controller = ClientController(
      hubClient: hubClient,
      session: session,
      controlReconnectGrace: Duration.zero,
      controlRecoveryRetry: const Duration(milliseconds: 10),
    )
      ..hub = hub
      ..config = active
      ..phase = ClientPhase.ready;

    session.emit(const SessionState(SessionPlane.control, 'reconnecting'));
    await _waitUntil(() => session.connectControlCalls == 1);

    expect(hubClient.registerCalls, 1);
    expect(session.connectControlCalls, 1);
    expect(controller.controlConnection, ChannelConnectionState.connected);
    expect(controller.phase, ClientPhase.ready);

    controller.dispose();
  });

  test('foreground resume immediately recovers a disconnected control room',
      () async {
    final session = _FakeSession();
    final hubClient = _FakeHubClient(active);
    final controller = ClientController(
      hubClient: hubClient,
      session: session,
    )
      ..hub = hub
      ..config = active
      ..phase = ClientPhase.ready;

    controller.onAppResumed();
    await _waitUntil(() => session.connectControlCalls == 1);

    expect(hubClient.registerCalls, 1);
    expect(controller.controlConnection, ChannelConnectionState.connected);

    controller.dispose();
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 50; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached before timeout');
}

class _FakeHubClient extends HubClient {
  _FakeHubClient(this.response);

  final HubConfig response;
  int registerCalls = 0;

  @override
  Future<HubConfig> register(
    String registerUrl, {
    String sessionIntent = '',
  }) async {
    registerCalls += 1;
    return response;
  }
}

class _FakeSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();
  bool _controlConnected = false;
  int connectControlCalls = 0;

  @override
  Stream<SessionState> get stateEvents => _states.stream;

  @override
  bool get isControlConnected => _controlConnected;

  void emit(SessionState state) {
    _states.add(state);
  }

  @override
  Future<void> connectControl(RoomConfig config) async {
    connectControlCalls += 1;
    _controlConnected = true;
    emit(const SessionState(SessionPlane.control, 'connected'));
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}
