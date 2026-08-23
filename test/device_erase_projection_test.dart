import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _status(String state, String? result) => {
      'contract': 'eidolon.device-foundation.device-operation-status',
      'contract_version': '1.0',
      'operation_id': 'erase_operation_01',
      'operation_type': 'device-local.erase',
      'request_fingerprint':
          'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'device_ref': {
        'device_instance_id': 'device_erase_01',
        'owner_domain_id': 'owner_01',
        'claim_generation': 7,
        'trust_epoch': 4,
        'accepted_manifest_digest':
            'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
      'created_at': '2026-08-23T00:00:00Z',
      'deadline': '2026-08-30T00:00:00Z',
      'state': state,
      'attempt_count': 1,
      'terminal_result': result,
    };

void main() {
  test('delivery acceptance never projects device erased', () {
    final pending = DeviceLocalEraseOperationStatusV1.fromJson(
      _status('delivery-accepted', null),
    );
    expect(pending.deviceErased, isFalse);

    final permanent = DeviceLocalEraseOperationStatusV1.fromJson(
      _status('permanent-failure', 'permanent-failure'),
    );
    expect(permanent.deviceErased, isFalse);

    final acknowledged = DeviceLocalEraseOperationStatusV1.fromJson(
      _status('acknowledged', 'erased'),
    );
    expect(acknowledged.deviceErased, isTrue);
  });

  test('channel revoke condition cannot substitute for erase ACK', () {
    const channelAccessRevoked = true;
    final erase = DeviceLocalEraseOperationStatusV1.fromJson(
      _status('delivery-accepted', null),
    );

    expect(channelAccessRevoked, isTrue);
    expect(erase.deviceErased, isFalse);
  });

  test('incoherent terminal result is rejected instead of projected', () {
    expect(
      () => DeviceLocalEraseOperationStatusV1.fromJson(
        _status('acknowledged', 'permanent-failure'),
      ),
      throwsFormatException,
    );
  });
}
