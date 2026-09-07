import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses an active Hub response with its channel and audio config', () {
    final parsed = HubConfig.fromJson({
      'success': true,
      'status': 'active',
      'registration_id': 'registration-1',
      'config': {
        'server_url': 'ws://10.0.0.2:7880',
        'token': 'channel-token',
        'identity': 'mobile-1',
        'room_name': 'device-mobile-1',
        'audio': {'sample_rate': 16000, 'channels': 1},
      },
      'device': {'fingerprint': 'p256:abc'},
    });

    expect(parsed.status, HubConfigStatus.active);
    expect(parsed.session.roomName, 'device-mobile-1');
    expect(parsed.session.token, 'channel-token');
    expect(parsed.registrationId, 'registration-1');
  });

  test('the audio the Host names is read by nothing, so it is not carried', () {
    // `HubConfig` used to parse `config.audio` into `sampleRate` and
    // `channels`, defaulting to 16000/1, and no line in `lib/` ever read
    // either. A field that is carried and never used is a claim that this
    // client honours a rate it has no way to set: it publishes through
    // `livekit_client`, whose `AudioCaptureOptions` exposes no rate and whose
    // only publish entry accepts nothing else, so the rate on the wire is
    // WebRTC's to negotiate.
    //
    // Asserted rather than simply deleted, because the deletion is the point:
    // an accessor that answered 16000 is what made the gap look closed.
    final parsed = HubConfig.fromJson(<String, dynamic>{
      'success': true,
      'status': 'active',
      'config': <String, dynamic>{
        'server_url': 'ws://10.0.0.2:7880',
        'token': 'channel-token',
        'identity': 'mobile-1',
        'room_name': 'device-mobile-1',
        'audio': <String, dynamic>{'sample_rate': 48000, 'channels': 2},
      },
    });

    // What is asserted is that this is accepted, not refused: WebRTC will
    // negotiate whatever it negotiates, and refusing here would trade a rate
    // the transport resolves for a Body that cannot talk at all.
    expect(parsed.session.usable, isTrue);
    expect(parsed.status, HubConfigStatus.active);
    // That `HubConfig` can no longer answer about audio is enforced by the
    // compiler, not by an assertion: writing `parsed.sampleRate` here would
    // not compile. Said out loud because the first version of this test
    // reached for `toString()` and checked nothing — `HubConfig` does not
    // override it, so the match could never have been found.
  });

  test('unknown status fails closed to pending approval', () {
    expect(HubConfigStatus.parse('future_status'),
        HubConfigStatus.pendingApproval);
  });
}
