import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _inventory() => {
      'contract_version': '1',
      'coverage': 'mounted-devices',
      'devices': [
        {
          'device_id': 'device-1',
          'admission_state': 'ready',
          'mount': {
            'revision': 2,
            'attached_companion_id': 'companion-1',
            'updated_at': '2026-08-09T08:10:00Z',
          },
        },
      ],
    };

void main() {
  test('strictly parses the mounted-only Local API Device projection', () {
    final inventory = MountedDeviceInventory.fromJson(_inventory());

    expect(inventory.devices, hasLength(1));
    expect(
      inventory.devices.single.admissionState,
      MountedDeviceAdmissionState.ready,
    );
    expect(
      inventory.devices.single.mount.attachedCompanionId,
      'companion-1',
    );
  });

  test('rejects inconsistent or expanded Device payloads', () {
    final inconsistent = _inventory();
    final device =
        (inconsistent['devices'] as List).single as Map<String, dynamic>;
    device['mount'] = {
      ...(device['mount'] as Map<String, dynamic>),
      'attached_companion_id': null,
    };
    expect(
      () => MountedDeviceInventory.fromJson(inconsistent),
      throwsFormatException,
    );

    final expanded = _inventory()..['owner_id'] = 'must-not-be-exposed';
    expect(
      () => MountedDeviceInventory.fromJson(expanded),
      throwsFormatException,
    );

    final withMountState = _inventory();
    final stateful =
        (withMountState['devices'] as List).single as Map<String, dynamic>;
    stateful['mount'] = {
      ...(stateful['mount'] as Map<String, dynamic>),
      'state': 'active',
    };
    expect(
      () => MountedDeviceInventory.fromJson(withMountState),
      throwsFormatException,
    );
  });

  test('rejects the inactive state removal used to leave in the list', () {
    final removed = _inventory();
    final device = (removed['devices'] as List).single as Map<String, dynamic>;
    device['admission_state'] = 'inactive';
    device['mount'] = {
      ...(device['mount'] as Map<String, dynamic>),
      'attached_companion_id': null,
    };
    expect(
      () => MountedDeviceInventory.fromJson(removed),
      throwsFormatException,
    );
  });
}
