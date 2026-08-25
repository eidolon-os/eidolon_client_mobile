import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter_test/flutter_test.dart';

/// What this app may read out of the Host's device answer.
///
/// The composition moved: the Host sees Hub's Claim and Kernel's mount and says
/// one thing about a device — what it is, whether it is ready, who answers
/// through it — while the canonical facts a removal has to name stay carried
/// underneath rather than re-derived here. What is left on this side is the
/// enum a screen switches on, and these pin the two readings that matter.

const _deviceId =
    'device-instance-cb2f012772ecde9edb09b4e6dd3fb2fedafda81e2591e2ca0fa6afe06d5ae2fa';

Map<String, dynamic> _wire({
  String state = 'ready',
  String? companionId = 'c_01',
  String label = 'box3-device-manifest',
  String kind = 'box3-device-manifest',
}) =>
    <String, dynamic>{
      'device_id': _deviceId,
      'label': label,
      'kind': kind,
      'state': state,
      'answers_as_companion_id': companionId,
      'answers_as_companion_name': companionId == null ? '' : '小忆',
      'revision': 2,
      'updated_at': '2026-08-25T08:10:00Z',
      'online': 'unknown',
      'online_reason': '这台主机没有任何东西在观测设备是否开着',
      'claim_state': state == 'access_revoked' ? 'revoked' : 'active',
      'claim_generation': 1,
      'trust_epoch': 1,
      'owner_domain_generation': 3,
      'manifest_id': kind,
      'manifest_revision': 1,
    };

MountedDeviceInventory _inventory({
  String state = 'ready',
  String? companionId = 'c_01',
}) =>
    MountedDeviceInventory.fromView(
      DevicesView.fromJson({
        'contract_version': '1',
        'coverage': '只包含已经属于你的设备。',
        'devices': [_wire(state: state, companionId: companionId)],
      }),
    );

void main() {
  test('reads the Host answer, and keeps what a removal will have to name', () {
    final device = _inventory().devices.single;

    expect(device.deviceId, _deviceId);
    expect(device.state, MountedDeviceState.ready);
    expect(device.attachedCompanionId, 'c_01');
    // Named, not identified: the row can say who answers rather than printing
    // an id at somebody.
    expect(device.attachedCompanionName, '小忆');
    // The generations a later removal has to name are carried rather than
    // re-derived — re-deriving them is how a stale one gets sent.
    expect(device.claimGeneration, 1);
    expect(device.ownerDomainGeneration, 3);
    expect(device.revision, 2);
  });

  test('a device nothing answers through is not shown as ready', () {
    final device = _inventory(
      state: 'awaiting_companion',
      companionId: null,
    ).devices.single;

    expect(device.state, MountedDeviceState.awaitingCompanion);
    expect(device.attachedCompanionName, '');
  });

  test('a withdrawn Claim with a surviving mount is its own state', () {
    // Removal's first half: platform access is gone, the mount is not. Folding
    // it into "fine" leaves the one screen that could offer the retry unable to
    // say anything is wrong.
    final device = _inventory(state: 'access_revoked').devices.single;

    expect(device.state, MountedDeviceState.accessRevoked);
    expect(device.claimState, 'revoked');
  });

  test('a state this version has never heard of is not read as fine', () {
    // The Host knows something this app does not, and "fine" is the one guess
    // that costs somebody a device.
    final device = _inventory(state: 'quarantined').devices.single;

    expect(device.state, MountedDeviceState.accessRevoked);
  });

  test('a device nobody named is labelled by the Host, never blank', () {
    final device = MountedDevice.fromView(
      DeviceView.fromJson(_wire(label: '…6d5ae2fa', kind: '')),
    );

    expect(device.label, '…6d5ae2fa');
    // The line underneath falls back to the identifier, which is what someone
    // reads out when asking for help.
    expect(device.detail, _deviceId);
  });

  test('online is whatever the Host said, and it says unknown', () {
    // Never inferred here: an active Claim and a live mount both say the device
    // is *known*, and neither says it is switched on.
    final device = _inventory().devices.single;

    expect(device.online, 'unknown');
    expect(device.onlineReason, isNotEmpty);
  });
}
