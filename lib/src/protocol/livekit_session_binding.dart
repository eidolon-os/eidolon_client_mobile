/// The binding a Channel Provider seals a device's session into.
///
/// The Hub relays this without reading it — deliberately, so an Authority never
/// has to know how a channel is realised. But it is not opaque to the two ends
/// that do: it has a version, a field set, and a parser on each side.
///
/// ## This is the third implementation, and now there is a vector
///
/// The producer is `eidolon_channel/.../adapters/livekit/adapter.py`, which
/// builds it inline; the firmware parses it in
/// `eidolon-client-esp32/main/eidolon/hub_types.h` and
/// `hub_onboarding_protocol.cc`. For a while none of the three was written
/// down in `eidolon_sdk/contracts`, so nothing turned red when one drifted —
/// and `schema_version: 2` says it had drifted once already.
///
/// `DF-LIVEKIT-SESSION-BINDING-001` pins it now, and
/// `test/livekit_session_binding_test.dart` reads this app against the
/// Provider's own wire bytes. `DF-CHANNEL-BINDING-001` names this repository
/// among the requirement's owners.
///
/// ## Why `audio` is dropped
///
/// `DF-LIVEKIT-SESSION-BINDING-001` says a binding whose `audio` names three
/// channels or a rate out of range must be refused, and this reader refuses
/// neither. That looks like neglect and is not; it is a difference between two
/// kinds of Body, and it is written down here because the alternative is a
/// comment that promises a fix nobody can make.
///
/// `audio.sample_rate` and `audio.channels` are settable by a Body that feeds
/// PCM into the transport itself, which is what the firmware does —
/// `livekit_session.cc` takes the binding's values, with a fallback, and opens
/// its capture at them. This Body does not feed PCM. It publishes through
/// `livekit_client`, whose `AudioCaptureOptions` has nine members and not one
/// of them is a rate or a channel count, and whose only publish entry point
/// (`setMicrophoneEnabled`) accepts nothing else. The rate on the wire is
/// negotiated by WebRTC.
///
/// So there is nothing here to set and nothing to check a request against.
/// Refusing on the member would deny a channel this app can join perfectly
/// well — trading a rate mismatch that WebRTC resolves for a Body that cannot
/// talk at all. `DF-CHANNEL-BINDING-AUDIO-001` is registered against this
/// repository for the gap; the evidence above has gone to the SDK, because
/// which of the two obligations applies to a transport-negotiated Body is a
/// contract question, not this file's.
library;

import 'dart:convert';

import '../models/hub_models.dart';

/// The media type the Provider stamps on a LiveKit session binding.
///
/// Held as a constant and compared, never parsed loosely: a binding in some
/// other format is not a binding this app can read, and treating an unknown one
/// as LiveKit would produce a `RoomConfig` full of empty strings that fails
/// later as "the session is unusable".
const liveKitSessionBindingFormat =
    'application/vnd.eidolon.livekit-session+json;v=2';

/// The payload version this app understands.
const liveKitSessionBindingSchemaVersion = 2;

/// Raised when a binding cannot be read as a LiveKit session.
///
/// Named rather than returning an empty session, because the two are different
/// and only one of them is worth telling somebody about: an unusable session
/// looks like a channel that has not arrived yet, and a binding this build
/// cannot read is a version gap that waiting will not close.
class UnreadableSessionBinding implements Exception {
  const UnreadableSessionBinding(this.message);

  final String message;

  @override
  String toString() => 'UnreadableSessionBinding: $message';
}

/// The room this device may join, read out of one channel binding.
///
/// [bindingFormat] and [opaqueBinding] are the two members the Authority
/// relayed. The format is checked first: it is the only thing that says what
/// the bytes are, and decoding them on the assumption that they are LiveKit is
/// how a different transport's binding becomes a confusing parse failure.
RoomConfig liveKitSessionFromBinding({
  required String bindingFormat,
  required String opaqueBinding,
}) {
  if (bindingFormat != liveKitSessionBindingFormat) {
    throw UnreadableSessionBinding(
      'this build reads $liveKitSessionBindingFormat, and the Host sent '
      '$bindingFormat',
    );
  }
  final List<int> bytes;
  try {
    // The producer emits standard base64 with padding
    // (`channel_provider/service.py` calls `b64encode`), which is also what
    // `DF-LIVEKIT-SESSION-BINDING-001` names in `opaque_binding_encoding`.
    //
    // Dart's decoder accepts either alphabet but requires the padding, so the
    // URL-safe unpadded form — the one the vector carries under
    // `not_the_opaque_binding`, precisely so nobody conflates the two — is
    // refused here, on its length. That is the right outcome for bytes the
    // Provider does not send, and it is stated exactly because leniency about
    // the alphabet is easy to mistake for leniency about the padding.
    bytes = base64.decode(opaqueBinding);
  } on FormatException {
    throw const UnreadableSessionBinding(
      'the channel binding is not base64',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const UnreadableSessionBinding(
      'the channel binding does not contain JSON',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const UnreadableSessionBinding(
      'the channel binding is not an object',
    );
  }
  final version = decoded['schema_version'];
  if (version != liveKitSessionBindingSchemaVersion) {
    // A version gap named as one. `schema_version` moved from 1 to 2 once
    // already, and the client that meets a 3 should say which two numbers
    // disagree rather than report a missing session.
    throw UnreadableSessionBinding(
      'this build reads session binding version '
      '$liveKitSessionBindingSchemaVersion, and the Host sent $version',
    );
  }
  final session = decoded['session'];
  if (session is! Map<String, dynamic>) {
    throw const UnreadableSessionBinding(
      'the channel binding carries no session',
    );
  }
  final room = RoomConfig.fromJson(session);
  if (!room.usable) {
    // `RoomConfig.fromJson` fills absent members with empty strings, which is
    // right for a lenient reader and wrong here: a binding that arrived and
    // cannot be joined must not be reported as a channel.
    throw const UnreadableSessionBinding(
      'the channel binding names no server or no token',
    );
  }
  return room;
}
