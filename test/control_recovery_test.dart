import 'package:eidolon_client_mobile/src/models/conversation_mode.dart';
import 'dart:async';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:eidolon_client_mobile/src/services/hub_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/phone_identity_fixtures.dart';

void main() {
  const room = RoomConfig(
    serverUrl: 'ws://hub.local:7880',
    token: 'token',
    identity: 'mobile-test',
    roomName: 'mobile-test-channel',
  );
  const active = HubConfig(
    status: HubConfigStatus.active,
    session: room,
  );
  const hub = HubService(
    instanceName: 'Test Hub',
    registerUrl: 'http://hub.local/api/device/register',
  );

  for (final event in ['disconnected', 'reconnecting']) {
    test('standby $event never opens a Room, including resume and retry',
        () async {
      final session = _FakeSession();
      final hubClient = _FakeHubClient(active);
      final controller =
          ClientController(hubClient: hubClient, session: session)
            ..hub = hub
            ..config = active
            ..phase = ClientPhase.ready;
      session.emit(SessionState(event));
      controller.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      await controller.retry();
      expect(session.connectCalls, 0);
      expect(controller.phase, ClientPhase.ready);
      controller.dispose();
    });
  }

  test('product conversation uses authenticated provisioner, not legacy URL',
      () async {
    final session = _FakeSession();
    final provisioner = _FakeProvisioner(active);
    final controller = ClientController(
      platform: _FakePlatform(),
      session: session,
      conversationProvisioner: provisioner,
    );

    await controller.start();

    expect(provisioner.calls, 1);
    expect(controller.hub?.api, 'device-onboarding-v1');
    expect(controller.phase, ClientPhase.ready);
    expect(session.connectCalls, 0);
    controller.dispose();
  });
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

class _FakeProvisioner implements ConversationProvisioner {
  _FakeProvisioner(this.response);

  final HubConfig response;
  var calls = 0;

  @override
  String get serviceName => 'Product Hub';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/descriptor');

  @override
  Future<HubConfig> provision(
      {String sessionIntent = '', ConversationMode? mode}) async {
    calls += 1;
    return response;
  }
}

class _FakePlatform extends FakePhonePlatform {}

class _FakeSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();
  bool _connected = false;
  int connectCalls = 0;
  bool failConnect = false;

  @override
  Stream<SessionState> get stateEvents => _states.stream;

  @override
  bool get isConnected => _connected;

  void emit(SessionState state) {
    _states.add(state);
  }

  @override
  Future<void> connect(RoomConfig config) async {
    connectCalls += 1;
    if (failConnect) throw TimeoutException('unreachable room');
    _connected = true;
    emit(const SessionState('connected'));
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}
