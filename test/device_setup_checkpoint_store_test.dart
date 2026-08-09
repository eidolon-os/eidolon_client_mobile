import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_checkpoint_store.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

const _preferenceKey = 'eidolon.device-setup-checkpoints.v1';

DeviceSetupCheckpoint _checkpoint(
  String setupId, {
  int minute = 0,
  String? deviceId,
}) =>
    DeviceSetupCheckpoint(
      contractVersion: DeviceSetupCheckpoint.currentContractVersion,
      setupId: setupId,
      requestId: 'request-$setupId',
      provisioningState: DeviceProvisioningState.networkConfigured,
      admissionState: DeviceAdmissionState.pendingApproval,
      updatedAt: DateTime.utc(2026, 8, 9, 10, minute),
      deviceId: deviceId ?? 'device-$setupId',
      enrollmentId: 'enrollment-$setupId',
    );

void main() {
  test('checkpoint survives store recreation without persisting secrets',
      () async {
    final preferences = InMemoryAppPreferences();
    final first = PersistentDeviceSetupCheckpointStore(
      preferences: preferences,
    );
    await first.save(_checkpoint('setup-1'));

    final recreated = PersistentDeviceSetupCheckpointStore(
      preferences: preferences,
    );
    final loaded = await recreated.load('setup-1');
    final raw = await preferences.readString(_preferenceKey);

    expect(loaded?.requestId, 'request-setup-1');
    expect(loaded?.deviceId, 'device-setup-1');
    expect(raw, isNot(contains('wifi-password')));
    expect(raw, isNot(contains('pairing-secret')));
  });

  test('concurrent saves are serialized and oldest checkpoints are evicted',
      () async {
    final preferences = InMemoryAppPreferences();
    final store = PersistentDeviceSetupCheckpointStore(
      preferences: preferences,
      maximumEntries: 2,
    );

    await Future.wait([
      store.save(_checkpoint('setup-1')),
      store.save(_checkpoint('setup-2', minute: 1)),
      store.save(_checkpoint('setup-3', minute: 2)),
    ]);

    expect(await store.load('setup-1'), isNull);
    expect(await store.load('setup-2'), isNotNull);
    expect(await store.load('setup-3'), isNotNull);
  });

  test('malformed checkpoint is isolated from valid recovery state', () async {
    final preferences = InMemoryAppPreferences();
    await preferences.writeString(
      _preferenceKey,
      jsonEncode({
        'contract_version': '1',
        'checkpoints': [
          {'contract_version': '1', 'setup_id': 42},
          _checkpoint('setup-valid').toJson(),
        ],
      }),
    );
    final store = PersistentDeviceSetupCheckpointStore(
      preferences: preferences,
    );

    expect((await store.load('setup-valid'))?.deviceId, 'device-setup-valid');
    expect(await store.load('missing'), isNull);
  });

  test('remove clears only the selected setup', () async {
    final preferences = InMemoryAppPreferences();
    final store = PersistentDeviceSetupCheckpointStore(
      preferences: preferences,
    );
    await store.save(_checkpoint('setup-1'));
    await store.save(_checkpoint('setup-2'));

    await store.remove('setup-1');

    expect(await store.load('setup-1'), isNull);
    expect(await store.load('setup-2'), isNotNull);
  });
}
