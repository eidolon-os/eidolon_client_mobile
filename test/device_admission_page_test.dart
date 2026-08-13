import 'package:eidolon_client_mobile/src/features/device_setup/device_admission_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
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

  testWidgets('shows why the Host refused instead of guessing at it', (
    tester,
  ) async {
    // A conflict the Host can explain used to reach the person as "refresh the
    // list" — advice that cannot help when the refusal is not about the list.
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceAdmissionPage(
          hostId: 'host-1',
          loadPending: () async => [_device],
          onApprove: ({required requestId, required deviceId}) async =>
              throw const LocalApiRequestException(
            'Device admission 返回 HTTP 409',
            statusCode: 409,
            reason: '主机上已经没有这台设备了。',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pending-device-aa:bb:cc:dd:ee:ff')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-device-admission')));
    await tester.pumpAndSettle();

    final error = tester.widget<Text>(
      find.byKey(const Key('device-admission-error')),
    );
    expect(error.data, contains('主机上已经没有这台设备了'));
    expect(error.data, isNot(contains('请刷新列表')));
  });
}
