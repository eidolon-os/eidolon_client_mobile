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
/// `tool/sync_device_foundation_binding.sh`. Review is what let four
/// implementations of one rule disagree.
void main() {
  final golden = jsonDecode(
    File(
      'test/fixtures/device_foundation/development-commissioning-identity.json',
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
