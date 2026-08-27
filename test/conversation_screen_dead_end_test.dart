import 'package:eidolon_client_mobile/main.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/phone_identity_fixtures.dart';

/// What the person holding the phone can actually do.
///
/// The report this fixes: 「打开对话」→「连接我的 Eidolon」 reaches 待批准 with
/// 「主机正在认领 Mobile」 and one control, 「立即检查状态」, forever. Two things
/// had to change on this screen — the sentence, and the button.
void main() {
  Future<void> open(
    WidgetTester tester,
    MobileBodyStanding standing,
    HubConfigStatus status, {
    bool withApprovalRoute = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: ClientPage(
          platform: FakePhonePlatform(),
          provisioner: _FakeProvisioner(
            HubConfig(
              status: status,
              session: const RoomConfig(
                serverUrl: '',
                token: '',
                identity: '',
                roomName: '',
              ),
              deviceFingerprint: phoneFingerprint,
              bodyStanding: standing,
            ),
          ),
          onApproveThisPhone: withApprovalRoute ? (_) async {} : null,
        ),
      ),
    );
    // The headline says the same words as the button in this phase, so aim at
    // the actions block rather than at the text.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('compact-actions')),
        matching: find.text('连接我的 Eidolon'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an unenrolled phone is not offered a retry', (tester) async {
    await open(
      tester,
      MobileBodyStanding.notEnrolled,
      HubConfigStatus.unregistered,
    );

    expect(find.text('立即检查状态'), findsNothing);
    expect(find.text('正在检查…'), findsNothing);
    expect(find.text('这台手机还不是一个身体'), findsWidgets);
    expect(find.textContaining('主机正在认领 Mobile'), findsNothing);
    expect(find.textContaining('自动向前推进'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone awaiting its own approval is offered the approval',
      (tester) async {
    await open(
      tester,
      MobileBodyStanding.pendingReview,
      HubConfigStatus.pendingApproval,
    );

    expect(find.text('去批准这台手机'), findsWidgets);
    expect(find.text('等你批准这台手机'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no route to the queue, the check button is still there',
      (tester) async {
    // Falling back rather than showing a dead button: this state does advance,
    // so re-asking is a real action even when this screen cannot navigate.
    await open(
      tester,
      MobileBodyStanding.pendingReview,
      HubConfigStatus.pendingApproval,
      withApprovalRoute: false,
    );

    expect(find.text('去批准这台手机'), findsNothing);
    expect(find.text('立即检查状态'), findsWidgets);
  });

  testWidgets('the id on screen is the one Hub would recognise',
      (tester) async {
    await open(
      tester,
      MobileBodyStanding.notEnrolled,
      HubConfigStatus.unregistered,
    );

    expect(find.text(phoneDeviceInstanceId), findsWidgets);
    expect(find.text(phoneInstallId), findsNothing);
  });
}

class _FakeProvisioner implements ConversationProvisioner {
  _FakeProvisioner(this.response);

  final HubConfig response;

  @override
  String get serviceName => 'owner-domain_01';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/admission');

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async => response;
}
