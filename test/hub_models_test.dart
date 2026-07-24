import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses an active Hub response with control and audio config', () {
    final parsed = HubConfig.fromJson({
      'success': true,
      'status': 'active',
      'registration_id': 'registration-1',
      'config': {
        'server_url': 'ws://10.0.0.2:7880',
        'token': 'voice-token',
        'identity': 'mobile-1',
        'room_name': 'voice-room',
        'audio': {'sample_rate': 16000, 'channels': 1},
        'control': {
          'server_url': 'ws://10.0.0.2:7880',
          'token': 'control-token',
          'identity': 'mobile-1',
          'room_name': 'device-mobile-1-control',
        },
      },
      'device': {'fingerprint': 'p256:abc'},
    });

    expect(parsed.status, HubConfigStatus.active);
    expect(parsed.active.roomName, 'voice-room');
    expect(parsed.control?.roomName, 'device-mobile-1-control');
    expect(parsed.registrationId, 'registration-1');
    expect(parsed.sampleRate, 16000);
  });

  test('unknown status fails closed to pending approval', () {
    expect(HubConfigStatus.parse('future_status'),
        HubConfigStatus.pendingApproval);
  });
}
