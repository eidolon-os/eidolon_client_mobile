import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Host projects Kernel's mount together with Hub's canonical Claim, and
/// copies neither. These pin what the phone may read out of that: a device is
/// named by what it is, and the three authorities' facts stay three facts.

const _deviceId =
    'device-instance-cb2f012772ecde9edb09b4e6dd3fb2fedafda81e2591e2ca0fa6afe06d5ae2fa';

Map<String, dynamic> _claim({
  String state = 'active',
  String manifestId = 'box3-device-manifest',
}) =>
    <String, dynamic>{
      'device_ref': <String, dynamic>{
        'device_instance_id': _deviceId,
        'owner_domain_id': 'owner-b0a862b0aab941d64554',
        'owner_domain_generation': 3,
        'claim_generation': 1,
        'trust_epoch': 1,
      },
      'business_owner_id': 'owner_683f0000000000000000',
      'manifest_ref': <String, dynamic>{
        'manifest_id': manifestId,
        'revision': 1,
        'digest': 'sha256:${'a' * 64}',
      },
      'state': state,
      'revision': 1,
      'updated_at': '2026-08-25T00:00:00Z',
    };

Map<String, dynamic> _inventory({
  String claimState = 'active',
  String? companionId = 'c_01',
}) =>
    <String, dynamic>{
      'contract_version': '1',
      'coverage': 'active-kernel-mounts-with-owner-scoped-hub-claims',
      'devices': <dynamic>[
        <String, dynamic>{
          'claim': _claim(state: claimState),
          'mount': <String, dynamic>{
            'revision': 2,
            'attached_companion_id': companionId,
            'updated_at': '2026-08-25T08:10:00Z',
          },
        },
      ],
    };

void main() {
  test('parses the Host projection of Kernel membership and Hub Claim', () {
    final device = MountedDeviceInventory.fromJson(_inventory()).devices.single;

    expect(device.deviceId, _deviceId);
    expect(device.state, MountedDeviceState.ready);
    expect(device.mount.attachedCompanionId, 'c_01');
    // The Claim is kept whole: the generation and trust epoch inside it are
    // what a later removal has to name, and re-deriving them is how a stale
    // one gets sent.
    expect(device.deviceRef.claimGeneration, 1);
    expect(device.deviceRef.ownerDomainGeneration, 3);
  });

  test('a device nothing answers through is not shown as ready', () {
    final inventory = MountedDeviceInventory.fromJson(
      _inventory(companionId: null),
    );
    expect(
      inventory.devices.single.state,
      MountedDeviceState.awaitingCompanion,
    );
  });

  test('a revoked Claim with a surviving mount is its own state', () {
    // Removal's first half: platform access is gone, the mount is not. Folding
    // this into "fine" leaves the one screen that could offer the retry unable
    // to say anything is wrong.
    for (final state in ['revoked', 'suspended']) {
      final inventory = MountedDeviceInventory.fromJson(
        _inventory(claimState: state),
      );
      expect(
        inventory.devices.single.state,
        MountedDeviceState.accessRevoked,
        reason: state,
      );
    }
  });

  test('rejects a projection that is not this contract', () {
    final expanded = _inventory()..['owner_id'] = 'must-not-be-exposed';
    expect(
      () => MountedDeviceInventory.fromJson(expanded),
      throwsFormatException,
    );

    final oldCoverage = _inventory()..['coverage'] = 'mounted-devices';
    expect(
      () => MountedDeviceInventory.fromJson(oldCoverage),
      throwsFormatException,
    );

    final withMountState = _inventory();
    final device =
        (withMountState['devices'] as List).single as Map<String, dynamic>;
    device['mount'] = <String, dynamic>{
      ...(device['mount'] as Map<String, dynamic>),
      'state': 'active',
    };
    expect(
      () => MountedDeviceInventory.fromJson(withMountState),
      throwsFormatException,
    );

    // The shape this consumer used to expect, which the Host stopped sending
    // when the inventory became a projection of the canonical Claim.
    final flattened = _inventory();
    (flattened['devices'] as List)[0] = <String, dynamic>{
      'device_id': 'device-1',
      'admission_state': 'ready',
      'mount': <String, dynamic>{
        'revision': 1,
        'attached_companion_id': 'c_01',
        'updated_at': '2026-08-25T08:10:00Z',
      },
    };
    expect(
      () => MountedDeviceInventory.fromJson(flattened),
      throwsFormatException,
    );
  });

  test('rejects two rows for one device', () {
    final duplicated = _inventory();
    final devices = duplicated['devices'] as List;
    devices.add(Map<String, dynamic>.from(devices.single as Map));
    expect(
      () => MountedDeviceInventory.fromJson(duplicated),
      throwsFormatException,
    );
  });

  group('a device is named, not enumerated', () {
    MountedDevice device({String manifestId = 'box3-device-manifest'}) =>
        MountedDevice.fromJson(<String, dynamic>{
          'claim': _claim(manifestId: manifestId),
          'mount': <String, dynamic>{
            'revision': 1,
            'attached_companion_id': null,
            'updated_at': '2026-08-25T08:10:00Z',
          },
        });

    test('by what it is, then by the tail of its identifier', () {
      // Nobody has named devices yet, and the accepted Manifest is the only
      // thing that says what this is. An identifier is what someone falls back
      // to when nothing will tell them.
      expect(device().label, 'box3-device-manifest');
      expect(device().detail, endsWith('e06d5ae2fa'));
    });

    test('the second line never repeats the first', () {
      final named = device();
      expect(named.detail, isNot(named.label));
    });
  });
}
