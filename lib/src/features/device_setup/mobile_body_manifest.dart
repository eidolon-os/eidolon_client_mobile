/// What this phone declares it can carry, as a Body.
///
/// A Manifest is not a description for people to read. The Channel Provider is
/// the one consumer that reads its content, and it turns these members directly
/// into a channel's media capability and into the LiveKit token's publish
/// grants — so a declaration is a request for permissions, and declaring one
/// this app does not use is asking for something it will never send.
///
/// The firmware states the same rule from the other side: "a camera that claims
/// a microphone is granted one and is assigned a voice agent that waits forever
/// for audio" (`hub_onboarding_protocol.cc`). Everything here is a fact about
/// this build.
///
/// ## Where the authority is
///
/// Not here. The document below must equal the contract's own vector,
/// `DF-MANIFEST-SOFTWARE-BODY-DOCUMENT-VALID` in
/// `examples/valid/common.json`, and `test/mobile_body_manifest_test.dart`
/// asserts exactly that against the vendored copy.
///
/// This was a hand-written copy until 2026-09-06, kept in step with a second
/// copy in the Channel Provider's tests by review alone, because
/// `eidolon_sdk/contracts` had no Manifest schema at all. It has one now
/// (`common/schemas.schema.json#/$defs/DeviceCapabilityManifest`), the
/// Authority validates against it at the admission entry, and both copies read
/// the vector instead of each other. The history is in
/// `docs/设备与Body/Manifest契约收敛.md`.
///
/// One consequence worth knowing here: a wrong shape is now refused by
/// `POST /enrollments` with a 422 that names the difference, rather than
/// accepted and left to fail at channel provisioning as a binding that never
/// arrives.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../protocol/canonical_json.dart';

/// The manifest id this phone declares.
///
/// It is also, in effect, this device's kind: the Authority copies
/// `manifest_id` into the owner-facing `device_kind`
/// (`hub/admission/persistence.py`) and from there it reaches the LiveKit
/// token's metadata. Nothing gates on it — a Provider carries an unknown kind
/// exactly as it carries a known one — so this names the Body honestly rather
/// than trying to pass as something already registered somewhere.
const mobileBodyManifestId = 'eidolon-mobile-android';

/// How many times this build's declaration has changed.
///
/// Not a version of the app. It orders a device's successive accounts of
/// itself, and the Authority uses it to decide whether an incoming assertion is
/// newer than the one it accepted. It moves when the members below move, and
/// at no other time.
const mobileBodyManifestRevision = 1;

/// Turn-taking, as a fact about this build rather than a preference.
///
/// `full_duplex` because the client turns on WebRTC echo cancellation, noise
/// suppression and gain control explicitly when it publishes the microphone.
/// A build that stopped doing that would have to change this, and would be
/// wrong not to: the Provider hands the mode to the agent, which uses it to
/// decide whether it may speak while listening.
const mobileBodyInteractionMode = 'full_duplex';

/// What this phone calls itself until the Owner renames it.
///
/// A name, not an identity: the Authority reads it as a display name on first
/// Claim and the Owner can change it afterwards on the devices page. Nothing
/// is derived from it, which is why a shared default is honest rather than
/// lazy — two phones with the same name are still two different Bodies, told
/// apart by their instance ids.
const defaultMobileBodyTitle = 'Eidolon Mobile';

/// The declaration itself.
///
/// [title] is what the Owner sees; the Authority reads it as the device's
/// display name on first Claim.
Map<String, Object?> mobileBodyManifestDocument({required String title}) {
  final named = title.trim();
  if (named.isEmpty || named.length > 128) {
    throw const FormatException(
      'A Body title must be present and at most 128 characters',
    );
  }
  return <String, Object?>{
    'actions': const <Object?>[],
    'events': const <Object?>[],
    'media': const <Object?>[
      // Publishes the microphone and hears the Companion.
      <String, Object?>{
        'codecs': <String>['opus'],
        'direction': 'bidirectional',
        'kind': 'audio',
      },
      // Subscribe only. Declaring `publish` here would put `camera` in the
      // token's allowed sources for a client that never sends one — a
      // permission granted for nothing, and one the Owner would have no way to
      // see was unused.
      <String, Object?>{
        'codecs': <String>['h264'],
        'direction': 'subscribe',
        'kind': 'video',
      },
    ],
    'properties': const <Object?>[
      <String, Object?>{
        'name': 'interaction_mode',
        'observable': false,
        // A `const` schema is the device stating a fact about itself rather
        // than offering a choice. The Provider reads exactly this shape.
        'schema': <String, Object?>{
          'const': mobileBodyInteractionMode,
          'type': 'string',
        },
        'writable': false,
      },
    ],
    'schema_version': 1,
    'title': named,
  };
}

/// The `manifest` member of a CreateEnrollment: the document and its identity.
///
/// The digest is over the canonical document, and the Authority recomputes it
/// before accepting the proposal (`hub/admission/application.py`) — so it is
/// checked on arrival rather than trusted.
Map<String, Object?> mobileBodyManifestRef({required String title}) {
  final document = mobileBodyManifestDocument(title: title);
  final canonical = canonicalJsonEncode(document);
  return <String, Object?>{
    'manifest_id': mobileBodyManifestId,
    'revision': mobileBodyManifestRevision,
    'digest': 'sha256:${sha256.convert(utf8.encode(canonical))}',
    'document': document,
  };
}
