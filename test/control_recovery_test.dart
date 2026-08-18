import 'dart:async';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:eidolon_client_mobile/src/services/hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

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

    session.emit(const SessionState('reconnecting'));
    await _waitUntil(() => session.connectCalls == 1);

    expect(hubClient.registerCalls, 1);
    expect(session.connectCalls, 1);
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
    await _waitUntil(() => session.connectCalls == 1);

    expect(hubClient.registerCalls, 1);
    expect(controller.controlConnection, ChannelConnectionState.connected);

    controller.dispose();
  });

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
    expect(session.connectCalls, 1);
    controller.dispose();
  });

  test('a failure only a person can clear is not offered as a retry', () async {
    // The retry button is drawn from `retryable`. Offering it here would send
    // the person around a loop that ends at the same refusal, so the failure
    // says what it is and the control it needs instead.
    final controller = ClientController(
      platform: _FakePlatform(),
      hubClient: _FakeHubClient(active),
      session: _FakeSession(),
      conversationProvisioner: _ThrowingProvisioner(
        const MobileProvisioningBlocked(
          title: '这台手机需要先被移除',
          message: '请到「我的 Eidolon」→「打开设备管理」，点开这台手机，选「移除设备」。',
          detail: 'handoff returned HTTP 409',
        ),
      ),
    );

    await controller.start();

    expect(controller.phase, ClientPhase.error);
    expect(controller.failure!.retryable, isFalse);
    expect(controller.failure!.title, '这台手机需要先被移除');
    expect(controller.failure!.message, contains('打开设备管理'));
    // The exception type never reaches the person; the diagnosis still does.
    expect(controller.failure!.message, isNot(contains('Bad state')));
    expect(controller.failure!.technicalDetails, contains('409'));

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

class _FakeProvisioner implements ConversationProvisioner {
  _FakeProvisioner(this.response);

  final HubConfig response;
  var calls = 0;

  @override
  String get serviceName => 'Product Hub';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/descriptor');

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async {
    calls += 1;
    return response;
  }
}

class _ThrowingProvisioner implements ConversationProvisioner {
  _ThrowingProvisioner(this.error);

  final Object error;

  @override
  String get serviceName => 'Product Hub';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/descriptor');

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async => throw error;
}

class _FakePlatform extends PlatformBridge {
  @override
  Future<DeviceIdentity> getDeviceIdentity() async => const DeviceIdentity(
        deviceId: 'mobile-test',
        fingerprint: 'p256:test',
      );
}

class _FakeSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();
  bool _connected = false;
  int connectCalls = 0;

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
    _connected = true;
    emit(const SessionState('connected'));
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}
