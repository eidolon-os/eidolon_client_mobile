import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_manifest.dart';
import 'package:eidolon_client_mobile/src/protocol/canonical_json.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';

/// What this phone declares, held to the contract's own vector.
///
/// `DF-MANIFEST-SOFTWARE-BODY-DOCUMENT-VALID` is the software Body's Manifest
/// as `eidolon_sdk/contracts` states it, vendored by
/// `tool/sync_device_foundation_v1.py`. Producing it and asserting against
/// it is the whole point: before the Manifest had a schema, this declaration and
/// the mirror in the Channel Provider's tests were two hand-written copies kept
/// in step by review, and nothing turned red when they drifted.
///
/// The remaining assertions are not about the bytes — the vector settles those.
/// They are about *why* each member is the value it is, because the Channel
/// Provider turns these into channel capability and into LiveKit publish
/// grants. A future change to the vector should have to answer them.
void main() {
  Map<String, dynamic> golden() =>
      canonicalContractValue('DF-MANIFEST-SOFTWARE-BODY-DOCUMENT-VALID');

  Map<String, Object?> document() =>
      mobileBodyManifestDocument(title: golden()['title']! as String);

  List<Map<String, Object?>> mediaOf(Map<String, Object?> value) =>
      (value['media']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .toList(growable: false);

  test('the declaration this phone emits is the contract vector', () {
    // `canonicalContractValue` throws on an id it cannot find, which is the
    // half that makes this assertion mean anything: a fixture that quietly
    // matched nothing would leave the producer unchecked and the test green.
    expect(document(), golden());
  });

  test('the vector is a manifest, and it is the software Body one', () {
    // Guards against the id being repointed at some other document — the
    // assertion above would still pass against a vector for a board.
    final title = golden()['title'];
    expect(title, 'Eidolon Mobile');
    expect(golden().keys.toSet(), <String>{
      'schema_version',
      'title',
      'properties',
      'actions',
      'events',
      'media',
    });
  });

  test('audio is bidirectional, which is what earns a conversational agent',
      () {
    // The Provider produces a serving spec — and therefore dispatches an agent
    // — only when the device publishes audio. A Manifest that subscribed only
    // would get a channel and never be answered.
    final audio =
        mediaOf(document()).firstWhere((entry) => entry['kind'] == 'audio');

    expect(audio['direction'], 'bidirectional');
  });

  test('video is subscribe only, so no camera source is ever granted', () {
    // `spec.video.publishes` is what puts `camera` in the LiveKit token's
    // allowed sources. This client renders the Companion and sends no camera,
    // so asking for one would be a standing permission for nothing.
    final video =
        mediaOf(document()).firstWhere((entry) => entry['kind'] == 'video');

    expect(video['direction'], 'subscribe');
    expect(
      mediaOf(document()).where((entry) => entry['direction'] == 'publish'),
      isEmpty,
    );
  });

  test('turn-taking is declared as a pinned fact, not an option', () {
    // The Provider reads `schema.const` (or a single-entry enum) and otherwise
    // falls back to half duplex, which would silently halve this client's
    // conversation quality without anything reporting a problem.
    final properties = (document()['properties']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final mode = properties.firstWhere(
      (entry) => entry['name'] == 'interaction_mode',
    );

    expect((mode['schema']! as Map<String, Object?>)['const'], 'full_duplex');
    expect(mode['writable'], isFalse);
    expect(mode['observable'], isFalse);
  });

  test('the ref digest is over the canonical document', () {
    // Recomputed by the Authority before the proposal is accepted, so a digest
    // over anything else is a 422 rather than a silent mismatch.
    final ref = mobileBodyManifestRef(title: 'Eidolon Mobile');
    final canonical = canonicalJsonEncode(ref['document']);

    expect(ref['document'], golden());
    expect(ref['digest'], 'sha256:${sha256.convert(utf8.encode(canonical))}');
    expect(ref['manifest_id'], mobileBodyManifestId);
    expect(ref['revision'], mobileBodyManifestRevision);
  });

  test('the manifest id is what the Owner will see as this device kind', () {
    // The Authority copies `manifest_id` into `device_kind`. It gates nothing,
    // which is exactly why it should name the Body honestly instead of
    // borrowing a kind that means something else.
    expect(mobileBodyManifestId, 'eidolon-mobile-android');
  });

  test('the title is the Owner\'s, and is required', () {
    // The one member the vector cannot fix: a person names their phone.
    expect(
      mobileBodyManifestDocument(title: '  Kitchen phone  ')['title'],
      'Kitchen phone',
    );
    expect(
      () => mobileBodyManifestDocument(title: '   '),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => mobileBodyManifestDocument(title: 'x' * 129),
      throwsA(isA<FormatException>()),
    );
  });
}
