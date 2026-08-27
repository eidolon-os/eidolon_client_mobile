import 'dart:async';

import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/phone_identity_fixtures.dart';

/// The screen stops polling for something that cannot arrive.
///
/// A phone with no Enrollment used to reach `pendingApproval`, be drawn as
/// 「待批准 / 主机正在认领 Mobile」, and re-ask the Host every five seconds for the
/// rest of the session. Nothing was going to answer differently: only a device
/// may propose itself, and this version cannot. The retry was the whole product
/// in that state.
void main() {
  HubConfig standing(MobileBodyStanding value, HubConfigStatus status) =>
      HubConfig(
        status: status,
        session: const RoomConfig(
          serverUrl: '',
          token: '',
          identity: '',
          roomName: '',
        ),
        deviceFingerprint: phoneFingerprint,
        bodyStanding: value,
      );

  Future<ClientController> connect(HubConfig config) async {
    final provisioner = _FakeProvisioner(config);
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: provisioner,
    );
    await controller.start();
    return controller;
  }

  test('no Enrollment is a stop, not a wait', () async {
    final controller = await connect(
      standing(MobileBodyStanding.notEnrolled, HubConfigStatus.unregistered),
    );

    expect(controller.phase, ClientPhase.bodyBlocked);
    expect(controller.isWaiting, isFalse);
    expect(controller.failure, isNull, reason: 'nothing failed');
    expect(controller.uiState.headline, isNot(contains('正在')));
    controller.dispose();
  });

  test('a stop does not poll', () async {
    final provisioner = _FakeProvisioner(
      standing(MobileBodyStanding.notEnrolled, HubConfigStatus.unregistered),
    );
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: provisioner,
    );

    await controller.start();
    final afterStart = provisioner.calls;
    // Comfortably past the five-second activation refresh this used to arm.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await controller.checkActivation();

    expect(provisioner.calls, afterStart,
        reason: 'a state that cannot advance must not be re-asked');
    controller.dispose();
  });

  test('ClaimActive without a Channel stops too, and says why', () async {
    final controller = await connect(
      standing(
        MobileBodyStanding.claimActiveWithoutChannel,
        HubConfigStatus.waitingBinding,
      ),
    );

    expect(controller.phase, ClientPhase.bodyBlocked);
    expect(controller.isWaiting, isFalse);
    expect(controller.uiState.supportingText, contains('当前版本'));
    controller.dispose();
  });

  test('a stage that does advance still waits, and offers the approval',
      () async {
    final controller = await connect(
      standing(
        MobileBodyStanding.pendingReview,
        HubConfigStatus.pendingApproval,
      ),
    );

    expect(controller.phase, ClientPhase.awaitingApproval);
    expect(controller.isWaiting, isTrue);
    expect(controller.awaitsThisControllersApproval, isTrue);
    controller.dispose();
  });

  test('the legacy register path keeps its own refusal', () async {
    // `unregistered` with no standing is the old Hub register response, and it
    // must keep throwing rather than quietly becoming a blocked screen.
    final controller = ClientController(
      platform: FakePhonePlatform(),
      session: _FakeSession(),
      conversationProvisioner: _FakeProvisioner(
        const HubConfig(
          status: HubConfigStatus.unregistered,
          session: RoomConfig(
            serverUrl: '',
            token: '',
            identity: '',
            roomName: '',
          ),
        ),
      ),
    );

    await controller.start();

    expect(controller.phase, ClientPhase.error);
    controller.dispose();
  });
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

class _FakeSession extends EidolonSession {
  final _states = StreamController<SessionState>.broadcast();

  @override
  Stream<SessionState> get stateEvents => _states.stream;

  @override
  bool get isConnected => false;

  @override
  Future<void> connect(RoomConfig config) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}
