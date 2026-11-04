import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_claim_pake.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';

/// The Host's half of the Setup code PAKE, computed the way eidolon_admin's
/// pake.py computes it, so a phone test exercises a real exchange rather
/// than a canned answer. Its context is its own; give it other keys than the
/// phone pinned and it plays a stand-in Host.
class FakePakeHost {
  FakePakeHost({
    required this.code,
    required this.commissioningId,
    required this.hostPublicKey,
    required this.tlsSpkiFingerprint,
    required this.resetEpoch,
    required this.transport,
    this.lieAboutServerProof = false,
  });

  final String code;
  final String commissioningId;
  String hostPublicKey;
  String tlsSpkiFingerprint;
  final int resetEpoch;
  final String transport;

  /// A stand-in that accepts any proof and answers with a made-up one.
  bool lieAboutServerProof;

  final _random = Random.secure();
  final _handshakes = <String,
      ({
    BigInt v,
    BigInt b,
    BigInt B,
    List<int> salt,
    Map<String, Object> context
  })>{};
  final confirmedControllerKeys = <String>[];
  int starts = 0;
  int confirms = 0;

  List<int> _bytes(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256));

  Map<String, dynamic> start(Map<String, dynamic> payload) {
    starts += 1;
    if (payload['suite'] != hostClaimPakeSuite) {
      throw const CommissioningRequestException(
          'unsupported_suite', 'unsupported suite');
    }
    if (payload['commissioning_id'] != commissioningId) {
      throw const CommissioningRequestException(
          'commissioning_denied', 'Commissioning session is unavailable');
    }
    final group = hostClaimGroup;
    final salt = _bytes(16);
    final b = bigIntOf(_bytes(32));
    final v = group.verifier(commissioningId, hostClaimPassword(code), salt);
    final B = group.serverPublic(v, b);
    final handshakeId = base64UrlNoPad(_bytes(16));
    final context = <String, Object>{
      'commissioning_id': commissioningId,
      'controller_public_key_sha256': base64UrlNoPad(sha256
          .convert(
              base64UrlDecodeNoPad(payload['controller_public_key'] as String))
          .bytes),
      'handshake_id': handshakeId,
      'host_public_key': hostPublicKey,
      'reset_epoch': resetEpoch,
      'suite': hostClaimPakeSuite,
      'tls_spki_fingerprint': tlsSpkiFingerprint,
      'transport': transport,
    };
    _handshakes[handshakeId] = (v: v, b: b, B: B, salt: salt, context: context);
    return {
      'suite': hostClaimPakeSuite,
      'handshake_id': handshakeId,
      'salt': base64UrlNoPad(salt),
      'B': base64UrlNoPad(group.pad(B)),
      'context': context,
    };
  }

  /// The server proof, or the refusal a real Host would send.
  String confirm(Map<String, dynamic> payload) {
    confirms += 1;
    final handshake = _handshakes.remove(payload['handshake_id']);
    if (handshake == null) {
      throw const CommissioningRequestException(
          'pake_handshake_unknown', 'Start the Setup code exchange again');
    }
    if (lieAboutServerProof) return base64UrlNoPad(_bytes(64));
    final group = hostClaimGroup;
    final A = group.publicValue(base64UrlDecodeNoPad(payload['A'] as String));
    final u = group.scrambler(A, handshake.B);
    final K = group.digest(
        [group.pad(group.serverSecret(A, handshake.v, u, handshake.b))]);
    final transcript = hostClaimTranscript(
        hostClaimContextBytes(handshake.context),
        handshake.salt,
        A,
        handshake.B);
    final keys = hostClaimConfirmationKeys(K, transcript);
    final expected = Hmac(sha512, keys.client).convert(transcript).bytes;
    final presented = base64UrlDecodeNoPad(payload['client_proof'] as String);
    var difference = expected.length ^ presented.length;
    for (var index = 0;
        index < expected.length && index < presented.length;
        index++) {
      difference |= expected[index] ^ presented[index];
    }
    if (difference != 0) {
      throw const CommissioningRequestException(
          'commissioning_denied', 'Commissioning session is unavailable');
    }
    confirmedControllerKeys
        .add(handshake.context['controller_public_key_sha256']! as String);
    return base64UrlNoPad(
        Hmac(sha512, keys.server).convert([...transcript, ...presented]).bytes);
  }
}

/// A controller public key the PAKE can hash: base64url, as the platform
/// keystore hands it out (an SPKI DER in production).
const fakeControllerPublicKey =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEimCALNuzFLN8_CAwcawkWD_TQLT9kJKqK6zE'
    'WO3-QUfz8rk5BcV3TlblYIQkRKZPwZZCuVO0gsja6_EllO0KcgE';

/// The proof computed in the test's own isolate: a widget test's fake clock
/// never delivers an `Isolate.run` result.
Future<HostClaimProof> proveDirectly(HostClaimProofRequest request) async =>
    proveHostClaim(request);
