import 'package:eidolon_client_mobile/src/features/device_setup/device_admission_page.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';

void main() {
  testWidgets('empty recovery never presents completion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: _page(load: (_) async => canonicalRecoveryPage([]))),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('空列表不代表'), findsOneWidget);
    expect(find.byKey(const Key('confirm-enrollment-decision')), findsNothing);
  });

  testWidgets(
      'one confirmation shows immutable actor/context and explicit Decision',
      (tester) async {
    var projection = canonicalProjection(state: 'pending_review');
    String? sentRequestId;
    await tester.pumpWidget(
      MaterialApp(
        home: _page(
          load: (_) async => canonicalRecoveryPage([projection]),
          decide: ({
            required String requestId,
            required EnrollmentRecoveryProjectionV1 projection,
          }) async {
            expect(projection.json['approval_decision'], isNull);
            sentRequestId = requestId;
            return canonicalProjection(
              state: 'approved_awaiting_handoff',
              withDecision: true,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enrollment-enrollment_01')));
    await tester.pump();

    expect(find.byKey(const Key('immutable-decision-context')), findsOneWidget);
    expect(find.textContaining('Actor：controller_01'), findsOneWidget);
    expect(find.textContaining('批准不会宣称'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-enrollment-decision')));
    await tester.pumpAndSettle();

    expect(sentRequestId, startsWith('mobile-decision-'));
    expect(find.text('已批准，等待设备领取 Grant'), findsOneWidget);
    expect(find.byKey(const Key('confirm-enrollment-decision')), findsNothing);
  });

  testWidgets('approved/grant/claim stay listed and foreground reloads',
      (tester) async {
    var loads = 0;
    final projections = [
      canonicalProjection(
        state: 'approved_awaiting_handoff',
        withDecision: true,
      ),
      canonicalProjection(
        state: 'grant_delivered',
        deviceId: namedDeviceInstanceId('device_02'),
        withDecision: true,
        withDelivery: true,
      ),
      canonicalProjection(
        state: 'grant_acknowledged',
        deviceId: namedDeviceInstanceId('device_03'),
        withDecision: true,
        withDelivery: true,
        claimState: 'active',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: _page(load: (_) async {
          loads += 1;
          return canonicalRecoveryPage(projections);
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.text('已批准，等待设备领取 Grant'), findsOneWidget);
    expect(find.text('Grant 已交付，等待 ClaimActive'), findsOneWidget);
    expect(find.text('ClaimActive'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(loads, 2);
  });
}

typedef _Load = Future<EnrollmentProposalPageV1> Function(
  AdmissionListCursorV1? after,
);

DeviceAdmissionPage _page({
  required _Load load,
  EnrollmentDecision? decide,
}) =>
    DeviceAdmissionPage(
      ownerDomainId: 'owner-domain_01',
      ownerDomainGeneration: 3,
      businessOwnerId: 'business-owner_01',
      controllerId: 'controller_01',
      loadRecovery: ({AdmissionListCursorV1? after}) => load(after),
      onDecide: decide ??
          ({
            required String requestId,
            required EnrollmentRecoveryProjectionV1 projection,
          }) async =>
              projection,
    );
