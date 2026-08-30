import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../generated/device_foundation_v1.dart';

/// How a device's instance identity is derived from its own operational key.
///
/// One function, and the only place in this app that may produce one. A device
/// instance id is a statement about a key, not a name a client may choose: this
/// app used to derive `mobile-android-<hash>` from ANDROID_ID and hand it to
/// Hub, which answered 422 to anything that is not this — so the phone's own
/// enrollment could never exist, and the phone's read path compared its
/// invented id against Hub's derived one and never matched.
///
/// The canonical home for this rule is the generated SDK binding
/// (`contracts/device_foundation/v1/generation/templates/device_foundation_v1.dart`,
/// alongside `DeviceInstanceIdV1.parse`), which is where the P2 收口 in
/// `docs/跨系统/纯软件Body准入方案.md` §3.2 puts it for all three languages. Until
/// that lands this is the fourth implementation of one rule, so it is held to
/// the SDK's own vector rather than to review: see
/// `test/device_instance_identity_test.dart`, which replays
/// `golden/development-commissioning-identity.json`.
///
/// Takes the key as it appears on the wire, not a pre-hashed digest. A caller
/// that hashes it itself — the phone's `fingerprint` field already carries
/// `p256:<sha256 of the same bytes>`, so it was tempting — would be a fifth
/// implementation, and one that cannot be checked against a vector describing
/// keys.
String deriveDeviceInstanceId(String operationalPublicKey) {
  final digest = sha256.convert(
    _requireP256Spki(_operationalPublicKeyBytes(operationalPublicKey)),
  );
  return DeviceInstanceIdV1.parse('device-instance-$digest').value;
}

/// The 26-byte header every P-256 SubjectPublicKeyInfo starts with: SEQUENCE,
/// AlgorithmIdentifier { id-ecPublicKey, prime256v1 }, then a 66-byte BIT
/// STRING whose contents are the 65-byte uncompressed point.
const List<int> _p256SpkiPrefix = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
  0x42, 0x00,
];

/// Refuse to hash anything that is not SPKI DER.
///
/// Which bytes get hashed *is* the identity, and the difference is invisible
/// once hashed: a raw uncompressed point (`0x04 || X || Y`, 65 bytes) is the
/// same key as its 91-byte SPKI DER encoding, and hashing it yields a
/// perfectly well-formed `device-instance-<64hex>` that Hub has never heard
/// of. What comes back is a 422 naming nothing — no crypto error, no signature
/// failure, just an id nobody recognises.
///
/// Not hypothetical, and not only this side's problem. The ESP32 firmware
/// derives through `mbedtls_pk_write_pubkey_der` and is correct today, but the
/// natural PSA idiom for its in-progress mbedtls 4 port is
/// `psa_export_public_key`, which for P-256 returns the raw point. That port
/// would have shipped boards that could not be claimed while every older board
/// kept working — which reads as "that board is broken" rather than as an
/// encoding mistake. This side has the same exposure: Android happens to hand
/// over `certificate.publicKey.encoded`, which is SPKI DER, and nothing until
/// now said it had to be.
List<int> _requireP256Spki(List<int> raw) {
  if (raw.length == 65 && raw.first == 0x04) {
    throw const FormatException(
      'Operational public key is a raw uncompressed point, not SPKI DER: '
      'hashing it would derive an identity no Authority has a record of',
    );
  }
  if (raw.length != _p256SpkiPrefix.length + 65) {
    throw const FormatException(
      'Operational public key is not a P-256 SubjectPublicKeyInfo',
    );
  }
  for (var index = 0; index < _p256SpkiPrefix.length; index += 1) {
    if (raw[index] != _p256SpkiPrefix[index]) {
      throw const FormatException(
        'Operational public key is not a P-256 SubjectPublicKeyInfo',
      );
    }
  }
  return raw;
}

/// The scheme an operational public key names itself with on the wire.
const operationalKeySpkiScheme = 'p256-spki:';

/// The bytes a wire public key stands for, whether or not it names its scheme.
///
/// Both spellings occur in the contract — enrollment carries
/// `p256-spki:<base64url>` while the erase vectors carry the bare base64url
/// SPKI — and they have to mean the same key. Stripping it here rather than in
/// each caller is the whole content of the rule above: "which bytes get hashed"
/// is what a device instance id *is*, and two callers that disagree about the
/// prefix derive two identities for one key.
List<int> _operationalPublicKeyBytes(String operationalPublicKey) {
  final encoded = operationalPublicKey.startsWith(operationalKeySpkiScheme)
      ? operationalPublicKey.substring(operationalKeySpkiScheme.length)
      : operationalPublicKey;
  if (encoded.isEmpty) {
    throw const FormatException('Operational public key is empty');
  }
  final List<int> raw;
  try {
    raw = base64Url.decode(
      encoded.padRight(encoded.length + (-encoded.length % 4), '='),
    );
  } on FormatException {
    throw const FormatException(
      'Operational public key is not base64url SPKI',
    );
  }
  if (raw.isEmpty) {
    throw const FormatException('Operational public key is empty');
  }
  return raw;
}
