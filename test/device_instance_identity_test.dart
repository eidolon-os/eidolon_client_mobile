import 'dart:convert';
import 'dart:io';

import 'package:eidolon_client_mobile/src/features/device_setup/device_instance_identity.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// A device instance id is a statement about a key, and this app used to make
/// it up.
///
/// The consequence was not a wrong string. It was that the phone could never be
/// enrolled — Hub answers 422 to any candidate id that is not
/// `device-instance-<sha256 of the operational key's SPKI>` — and that the
/// phone's own read path compared its invented `mobile-android-<hash>` against
/// the field Hub derives, a comparison that was false by construction. So even
/// after someone else created the record, this phone could not have found it.
///
/// These vectors are the SDK's own, vendored by
/// `tool/sync_device_foundation_v1.py`. Review is what let four
/// implementations of one rule disagree.
void main() {
  final golden = jsonDecode(
    File(
      'test/fixtures/device_foundation/commissioning-voucher.json',
    ).readAsStringSync(),
  ) as Map<String, dynamic>;

  test('the derivation reproduces the canonical vector', () {
    expect(
      deriveDeviceInstanceId(golden['operational_public_key'] as String),
      golden['device_instance_id'],
    );
  });

  test('a key names the same device whether or not it names its scheme', () {
    // Both spellings occur in the contract — enrollment carries the prefixed
    // form, the erase vectors carry the bare SPKI. A caller that strips the
    // prefix and one that forgets to used to derive two identities for one
    // key: Admission stored one spelling, Device Control received the other,
    // and every claimed device was refused on its first call after a restart.
    final prefixed = golden['operational_public_key'] as String;
    final bare = prefixed.substring(operationalKeySpkiScheme.length);

    expect(deriveDeviceInstanceId(bare), deriveDeviceInstanceId(prefixed));
  });

  test('the digest is over the key bytes, not over the wire string', () {
    // The phone already holds `p256:<sha256 of the same bytes>` in its
    // fingerprint, so concatenating that hex was the tempting shortcut. It
    // would be a second implementation of the rule, and one no vector about
    // keys could ever check.
    final spkiSha256 = golden['operational_spki_sha256'] as String;

    expect(
      deriveDeviceInstanceId(golden['operational_public_key'] as String),
      'device-instance-${spkiSha256.substring('sha256:'.length)}',
    );
  });

  group('the contract vector for this rule', () {
    // Vendored from the SDK by tool/sync_device_foundation_v1.py. Before
    // it existed this app was correct by coincidence: Android happens to hand
    // over SPKI DER, and nothing said it had to. Three of the four
    // implementations of this rule would hash a raw uncompressed point into a
    // well-formed identity no Authority has a record of.
    final derivation = jsonDecode(
      File(
        'test/fixtures/device_foundation/device-instance-derivation.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;

    test('every accepted spelling of one key is one device', () {
      for (final spelling in derivation['accepted_spellings'] as List) {
        expect(
          deriveDeviceInstanceId(spelling as String),
          derivation['device_instance_id'],
          reason: 'spelling $spelling derived another device',
        );
      }
    });

    test('every encoding the vector refuses is refused here too', () {
      for (final entry in derivation['must_refuse'] as List) {
        final refused = entry as Map<String, dynamic>;
        expect(
          () => deriveDeviceInstanceId(refused['encoded'] as String),
          throwsA(isA<FormatException>()),
          reason: 'the vector refuses ${refused['case']} and this does not',
        );
      }
    });

    test('the id this app derives is the one the vector states', () {
      expect(
        deriveDeviceInstanceId(derivation['operational_public_key'] as String),
        derivation['device_instance_id'],
      );
      // And never the digest the vector records for the wrong encoding — the
      // one somebody would see in the wild if an implementation drifted.
      final rawPoint = (derivation['must_refuse'] as List).firstWhere(
        (entry) => (entry as Map)['case'] == 'raw-uncompressed-point',
      ) as Map<String, dynamic>;
      expect(
        derivation['device_instance_id'],
        isNot(rawPoint['digest_if_wrongly_hashed']),
      );
    });
  });

  test('the same key in the wrong encoding is refused, not silently rehashed',
      () {
    // The trap this closes, and it is invisible once hashed: a raw
    // uncompressed point (`0x04 || X || Y`) is the *same key* as its SPKI DER
    // encoding, and hashing it yields a perfectly well-formed
    // `device-instance-<64hex>` that no Authority has a record of. The answer
    // is a 422 naming nothing — no crypto error, no signature failure.
    //
    // Live on the firmware side right now: ESP32 derives through
    // `mbedtls_pk_write_pubkey_der` and is correct, but the natural PSA idiom
    // for its in-progress mbedtls 4 port, `psa_export_public_key`, returns the
    // raw point for P-256. That port would have shipped boards that could not
    // be claimed while every older board kept working.
    final spki = base64Url.decode(
      _pad((golden['operational_public_key'] as String)
          .substring(operationalKeySpkiScheme.length)),
    );
    // The point is carried inside the SPKI, so this is the same key.
    final rawPoint = spki.sublist(spki.length - 65);
    expect(rawPoint.first, 0x04);

    expect(
      () => deriveDeviceInstanceId(base64Url.encode(rawPoint)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('raw uncompressed point'),
        ),
      ),
    );
    // And the correct encoding of that same key still derives the vector's id.
    expect(
      deriveDeviceInstanceId(golden['operational_public_key'] as String),
      golden['device_instance_id'],
    );
  });

  test('a key that is not a P-256 SPKI is refused', () {
    expect(
      () => deriveDeviceInstanceId(base64Url.encode(List.filled(91, 0x30))),
      throwsA(isA<FormatException>()),
    );
  });

  test('an invented identity is refused rather than derived', () {
    expect(
      () => deriveDeviceInstanceId('mobile-android-dcaa15ac8c09efa36c97'),
      throwsA(isA<FormatException>()),
    );
    expect(() => deriveDeviceInstanceId(''), throwsA(isA<FormatException>()));
    expect(
      () => deriveDeviceInstanceId('p256-spki:'),
      throwsA(isA<FormatException>()),
    );
  });

  test('a platform identity names the device by its key, not by its install',
      () {
    final identity = DeviceIdentity(
      installId: 'mobile-android-dcaa15ac8c09efa36c97825ad21bec49',
      operationalPublicKey: golden['operational_public_key'] as String,
      fingerprint: golden['operational_spki_sha256'] as String,
    );

    expect(identity.deviceInstanceId, golden['device_instance_id']);
    expect(identity.deviceInstanceId, isNot(identity.installId));
  });
}

String _pad(String value) =>
    value.padRight(value.length + (-value.length % 4), '=');
