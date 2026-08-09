import 'package:eidolon_client_mobile/src/features/device_setup/device_pairing_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_pairing_scanner.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_pairing_vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Scanner implements DevicePairingScanner {
  _Scanner(this.result, {this.error});

  final DevicePairingPayload? result;
  final Object? error;

  @override
  Future<DevicePairingPayload?> scan() async {
    if (error case final error?) throw error;
    return result;
  }
}

class _Vault implements DevicePairingVault {
  _Vault([this.value]);

  PendingDevicePairingClaim? value;
  var saveCount = 0;
  var clearCount = 0;

  @override
  Future<void> clear(String hostId) async {
    clearCount += 1;
    value = null;
  }

  @override
  Future<PendingDevicePairingClaim?> load(String hostId) async => value;

  @override
  Future<void> save({
    required String hostId,
    required PendingDevicePairingClaim claim,
  }) async {
    saveCount += 1;
    value = claim;
  }
}

void main() {
  testWidgets('scans compact pairing proof and completes Owner admission',
      (tester) async {
    String? seenSetupId;
    String? seenRequestId;
    DevicePairingPayload? received;
    final vault = _Vault();
    const pairing = DevicePairingPayload(
      enrollmentId: 'enrollment_1',
      pairingSecret: 'device-generated-pairing-secret-00001',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DevicePairingPage(
          hostId: 'ehost-0123456789abcdefabcd',
          scanner: _Scanner(pairing),
          vault: vault,
          onClaim: ({
            required setupId,
            required requestId,
            required pairing,
          }) async {
            seenSetupId = setupId;
            seenRequestId = requestId;
            received = pairing;
            return DeviceAdmissionProgress(
              setupId: setupId,
              requestId: requestId,
              deviceId: 'device-1',
              enrollmentId: pairing.enrollmentId,
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

    await tester.tap(find.byKey(const Key('scan-device-pairing-code')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-pairing-ready')), findsOneWidget);
    expect(seenSetupId, startsWith('device-pair-'));
    expect(seenRequestId, startsWith('device-pair-claim-'));
    expect(received?.enrollmentId, 'enrollment_1');
    expect(find.text(pairing.pairingSecret), findsNothing);
    expect(vault.saveCount, 1);
    expect(vault.clearCount, 1);
    expect(vault.value, isNull);
  });

  testWidgets('invalid scanner result stays at the product scan boundary',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DevicePairingPage(
          hostId: 'ehost-0123456789abcdefabcd',
          scanner: _Scanner(null, error: const FormatException('invalid')),
          vault: _Vault(),
          onClaim: ({
            required setupId,
            required requestId,
            required pairing,
          }) =>
              throw StateError('must not claim'),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scan-device-pairing-code')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-pairing-error')), findsOneWidget);
    expect(find.textContaining('有效的 Eidolon 设备二维码'), findsOneWidget);
    expect(find.byKey(const Key('scan-device-pairing-code')), findsOneWidget);
  });

  testWidgets('restores encrypted pending proof for exact forward retry',
      (tester) async {
    const pairing = DevicePairingPayload(
      enrollmentId: 'enrollment-resume',
      pairingSecret: 'device-generated-pairing-secret-resume',
    );
    final vault = _Vault(
      const PendingDevicePairingClaim(
        setupId: 'device-pair-stable',
        requestId: 'device-pair-claim-stable',
        pairing: pairing,
      ),
    );
    DevicePairingPayload? received;
    await tester.pumpWidget(
      MaterialApp(
        home: DevicePairingPage(
          hostId: 'ehost-0123456789abcdefabcd',
          scanner: _Scanner(null),
          vault: vault,
          onClaim: ({
            required setupId,
            required requestId,
            required pairing,
          }) async {
            received = pairing;
            return DeviceAdmissionProgress(
              setupId: setupId,
              requestId: requestId,
              deviceId: 'device-resume',
              enrollmentId: pairing.enrollmentId,
              ownerId: 'owner-1',
              state: DeviceAdmissionState.binding,
              completedStage: 'kernel-mounted',
            );
          },
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-device-admission')), findsOneWidget);
    await tester.tap(find.byKey(const Key('continue-device-admission')));
    await tester.pumpAndSettle();

    expect(received?.pairingSecret, pairing.pairingSecret);
    expect(vault.clearCount, 0);
    expect(vault.value, isNotNull);
    expect(find.text('正在关联 Companion'), findsOneWidget);
  });
}
