import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/protocol/livekit_session_binding.dart';
import 'package:flutter_test/flutter_test.dart';

/// The binding the Provider seals a session into, read from this side.
///
/// `DF-LIVEKIT-SESSION-BINDING-001` now pins it — the member set, the canonical
/// bytes, the base64 form and the `binding_format` that names its version — so
/// the first test below is this app against the Provider's own artifact rather
/// than against a payload typed here. `DF-CHANNEL-BINDING-001` names this
/// repository among the requirement's owners and lists no mobile consumer test;
/// this file is that test.
///
/// The locally built payloads that follow are still worth their place: the
/// vector holds one valid document and four it says must be refused, and the
/// refusals this app owns need to be provoked with values the vector does not
/// carry. What each one asserts beyond the shape is the part that decides
/// whether a person gets a sentence they can act on — an unreadable binding has
/// to be told apart from a channel that has not arrived, because only one of
/// them is a wait.
String seal(Object? payload) => base64.encode(utf8.encode(jsonEncode(payload)));

Map<String, dynamic> _vector() => jsonDecode(
      File('test/fixtures/device_foundation/livekit-session-binding.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;

Map<String, Object?> sessionPayload({
  int schemaVersion = liveKitSessionBindingSchemaVersion,
  String serverUrl = 'wss://livekit.owner-domain.invalid',
  String token = 'a.jwt.token',
}) =>
    <String, Object?>{
      'schema_version': schemaVersion,
      'session': <String, Object?>{
        'server_url': serverUrl,
        'token': token,
        'identity': 'device-instance-${'a' * 64}',
        'room_name': 'eidolon-0123456789abcdef01234567',
      },
      'audio': <String, Object?>{'sample_rate': 16000, 'channels': 1},
    };

void main() {
  test('the Provider\'s own binding becomes the room the vector describes', () {
    final vector = _vector();
    final session =
        (vector['binding']! as Map<String, dynamic>)['session']!
            as Map<String, dynamic>;

    // The wire bytes, not a re-encoding of the decoded document: what this app
    // has to be able to read is exactly what the Provider put on the wire.
    final room = liveKitSessionFromBinding(
      bindingFormat: vector['binding_format']! as String,
      opaqueBinding: vector['opaque_binding']! as String,
    );

    expect(room.serverUrl, session['server_url']);
    expect(room.token, session['token']);
    expect(room.identity, session['identity']);
    expect(room.roomName, session['room_name']);
    expect(room.usable, isTrue);
    // The constant this app compares against is the version half of the
    // agreement, and the vector is where the Provider states it.
    expect(liveKitSessionBindingFormat, vector['binding_format']);
  });

  test('the wire form decodes, and the form the vector calls not-it does not',
      () {
    // `opaque_binding_encoding` names the one form the Provider emits, and the
    // vector carries the other under `not_the_opaque_binding` so that a
    // consumer cannot quietly treat them as interchangeable.
    //
    // This app refuses the other one, and it is worth being exact about why,
    // because I have now been wrong about it in both directions. Dart's
    // `base64.decode` accepts **either alphabet** but **requires padding**, so
    // what fails is the missing `=`, not the `-`/`_`. Refusing is the right
    // outcome anyway — the vector's label for those bytes is that they are not
    // the binding — but a comment claiming tolerance this decoder does not
    // have is how a producer that dropped padding would look like a corrupt
    // channel instead of a version disagreement.
    final vector = _vector();

    expect(vector['opaque_binding_encoding'], 'base64-standard-with-padding');
    expect(
      'sha256:${sha256.convert(base64.decode(vector['opaque_binding']! as String))}',
      vector['canonical_sha256'],
    );

    final other = (vector['not_the_opaque_binding']! as Map<String, dynamic>)[
        'base64url_no_padding']! as String;
    expect(other, isNot(vector['opaque_binding']));
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: vector['binding_format']! as String,
        opaqueBinding: other,
      ),
      throwsA(
        isA<UnreadableSessionBinding>().having(
          (error) => error.message,
          'message',
          contains('base64'),
        ),
      ),
    );
    // And the same bytes with padding restored are readable, which is what
    // isolates the cause to the padding rather than the alphabet.
    expect(
      liveKitSessionFromBinding(
        bindingFormat: vector['binding_format']! as String,
        opaqueBinding: base64.normalize(other),
      ).token,
      liveKitSessionFromBinding(
        bindingFormat: vector['binding_format']! as String,
        opaqueBinding: vector['opaque_binding']! as String,
      ).token,
    );
  });

  test('the audio the Provider asks for is not honoured, and not refused', () {
    // The vector says a binding with three channels or a rate out of range
    // must be refused, and this app refuses neither. Kept as an assertion
    // about the current behaviour, with the reason now established rather than
    // assumed:
    //
    // `audio.sample_rate` and `audio.channels` are settable by a Body that
    // feeds PCM into the transport, which is what the firmware does —
    // `livekit_session.cc` takes the binding's values with a fallback. This
    // Body publishes through `livekit_client`, whose `AudioCaptureOptions`
    // carries nine members and no rate or channel count, and whose only
    // publish entry (`setMicrophoneEnabled`) takes nothing else. WebRTC
    // negotiates the rate on the wire. There is nothing here to set.
    //
    // So refusing would deny a channel this app can join, and honouring is not
    // expressible — which makes this a question about which obligation applies
    // to a transport-negotiated Body, and that belongs to the contract.
    // `DF-CHANNEL-BINDING-AUDIO-001` is registered against this repository and
    // the evidence has gone to the SDK. Until it answers, this test is what
    // keeps the behaviour from being changed by accident in either direction.
    final vector = _vector();
    final refusals = (vector['must_refuse']! as List<Object?>)
        .cast<Map<String, dynamic>>();
    final audioCases = refusals.where(
      (entry) => (entry['case_id']! as String).contains('SAMPLE-RATE') ||
          (entry['case_id']! as String).contains('CHANNELS'),
    );

    expect(audioCases, hasLength(2));
    for (final entry in audioCases) {
      final room = liveKitSessionFromBinding(
        bindingFormat: vector['binding_format']! as String,
        opaqueBinding: seal(entry['binding']),
      );
      expect(room.usable, isTrue, reason: entry['case_id'] as String);
    }
  });

  test('the refusals this app owns are the ones the vector lists', () {
    // The other two. These it does refuse, and from the vector's own payloads
    // rather than from payloads typed here — a refusal that only fires on a
    // locally invented shape is not evidence about the Provider's.
    final vector = _vector();
    for (final entry in (vector['must_refuse']! as List<Object?>)
        .cast<Map<String, dynamic>>()
        .where(
          (entry) => (entry['case_id']! as String).contains('SCHEMA-VERSION') ||
              (entry['case_id']! as String).contains('NO-TOKEN'),
        )) {
      expect(
        () => liveKitSessionFromBinding(
          bindingFormat: vector['binding_format']! as String,
          opaqueBinding: seal(entry['binding']),
        ),
        throwsA(isA<UnreadableSessionBinding>()),
        reason: entry['case_id'] as String,
      );
    }
  });

  test('a session binding becomes the room this device may join', () {
    final room = liveKitSessionFromBinding(
      bindingFormat: liveKitSessionBindingFormat,
      opaqueBinding: seal(sessionPayload()),
    );

    expect(room.serverUrl, 'wss://livekit.owner-domain.invalid');
    expect(room.token, 'a.jwt.token');
    expect(room.identity, 'device-instance-${'a' * 64}');
    expect(room.roomName, 'eidolon-0123456789abcdef01234567');
    expect(room.usable, isTrue);
  });

  test('the format string is the one the Provider stamps', () {
    // Written out rather than referenced, because the constant it is compared
    // against is the thing under test. The producer's copy is
    // `BINDING_FORMAT` in `channel_provider/adapters/livekit/adapter.py`.
    expect(
      liveKitSessionBindingFormat,
      'application/vnd.eidolon.livekit-session+json;v=2',
    );
  });

  test('a padded binding decodes, because the producer emits padding', () {
    // `channel_provider/service.py` calls `b64encode`, which pads whenever the
    // payload is not a multiple of three bytes — so roughly two bindings in
    // three carry `=`. Constructed rather than assumed here: the default
    // fixture happens to land on a boundary and would not exercise it.
    var token = 'a.jwt.token';
    var encoded = seal(sessionPayload(token: token));
    while (!encoded.endsWith('=')) {
      token = '${token}x';
      encoded = seal(sessionPayload(token: token));
    }

    final room = liveKitSessionFromBinding(
      bindingFormat: liveKitSessionBindingFormat,
      opaqueBinding: encoded,
    );

    expect(room.token, token);
  });

  test('another transport\'s binding is refused by name', () {
    // The format is the only thing that says what the bytes are. Decoding them
    // as LiveKit anyway would produce a room full of empty strings and report
    // it later as an unusable session.
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: 'application/vnd.eidolon.mqtt-topic+json;v=1',
        opaqueBinding: seal(sessionPayload()),
      ),
      throwsA(
        isA<UnreadableSessionBinding>().having(
          (error) => error.message,
          'message',
          contains('mqtt'),
        ),
      ),
    );
  });

  test('a version this build does not read names both numbers', () {
    // It moved from 1 to 2 once already. A client meeting a 3 should say which
    // two disagree, not report a missing channel — waiting does not close a
    // version gap.
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: liveKitSessionBindingFormat,
        opaqueBinding: seal(sessionPayload(schemaVersion: 3)),
      ),
      throwsA(
        isA<UnreadableSessionBinding>()
            .having((error) => error.message, 'message', contains('2'))
            .having((error) => error.message, 'message', contains('3')),
      ),
    );
  });

  test('a binding that names no server is not a channel', () {
    // `RoomConfig.fromJson` fills absent members with empty strings, which is
    // right for a lenient reader and wrong here: a binding that arrived and
    // cannot be joined must not be reported as a channel that has arrived.
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: liveKitSessionBindingFormat,
        opaqueBinding: seal(sessionPayload(serverUrl: '')),
      ),
      throwsA(isA<UnreadableSessionBinding>()),
    );
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: liveKitSessionBindingFormat,
        opaqueBinding: seal(sessionPayload(token: '')),
      ),
      throwsA(isA<UnreadableSessionBinding>()),
    );
  });

  test('bytes that are not JSON, and JSON that is not a binding', () {
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: liveKitSessionBindingFormat,
        opaqueBinding: base64.encode(utf8.encode('not json')),
      ),
      throwsA(isA<UnreadableSessionBinding>()),
    );
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: liveKitSessionBindingFormat,
        opaqueBinding: seal(<Object?>['an', 'array']),
      ),
      throwsA(isA<UnreadableSessionBinding>()),
    );
    expect(
      () => liveKitSessionFromBinding(
        bindingFormat: liveKitSessionBindingFormat,
        opaqueBinding: seal(<String, Object?>{'schema_version': 2}),
      ),
      throwsA(isA<UnreadableSessionBinding>()),
    );
  });
}
