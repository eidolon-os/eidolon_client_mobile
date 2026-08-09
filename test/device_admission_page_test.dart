import 'package:eidolon_client_mobile/src/features/device_setup/device_admission_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _device = PendingDeviceEnrollment(
  deviceId: 'aa:bb:cc:dd:ee:ff',
  displayName: 'Living Room Device',
  deviceKind: 'voice-client',
  enrolledAt: DateTime.utc(2026, 8, 9),
);

void main() {
  testWidgets('loads pending devices and waits for explicit confirmation', (
    tester,
  ) async {
    String? approvedDevice;
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceAdmissionPage(
          hostId: 'host-1',
          loadPending: () async => [_device],
          onApprove: ({required requestId, required deviceId}) async {
            approvedDevice = deviceId;
            return DeviceAdmissionProgress(
              requestId: requestId,
              deviceId: deviceId,
              ownerId: 'owner-1',
              state: DeviceAdmissionState.ready,
              completedStage: 'companion-attached',
              companionId: 'companion-1',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Living Room Device'), findsOneWidget);
    expect(approvedDevice, isNull);
    expect(find.byKey(const Key('confirm-device-admission')), findsNothing);

    await tester.tap(find.byKey(const Key('pending-device-aa:bb:cc:dd:ee:ff')));
    await tester.pump();
    expect(
        find.byKey(const Key('device-admission-confirmation')), findsOneWidget);
    expect(approvedDevice, isNull);

    await tester.tap(find.byKey(const Key('confirm-device-admission')));
    await tester.pumpAndSettle();

    expect(approvedDevice, _device.deviceId);
    expect(find.byKey(const Key('device-admission-ready')), findsOneWidget);
  });

  testWidgets('shows a screen-independent empty state and can refresh', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceAdmissionPage(
          hostId: 'host-1',
          loadPending: () async {
            loads += 1;
            return const [];
          },
          onApprove: ({required requestId, required deviceId}) async =>
              throw StateError('must not approve'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-pending-devices')), findsOneWidget);
    expect(find.textContaining('二维码'), findsNothing);
    await tester.tap(find.byKey(const Key('refresh-pending-devices')));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });
}
