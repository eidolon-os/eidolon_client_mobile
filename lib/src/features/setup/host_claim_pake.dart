import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// SRP-6a over the Setup code: the phone's half (eidolon_admin ADR-0008).
///
/// The phone used to send the eight-digit code, in plaintext, inside a TLS
/// session pinned to whatever key the Host's self-signed endpoint named. A
/// stand-in Host received it and could relay it. Now the code never leaves
/// the phone: it keys SRP-6a (RFC 5054, 3072-bit group, SHA-512), and both
/// proofs are bound to a context naming the keys this phone pinned. A Host
/// that does not know the code cannot answer, and one that relays to the real
/// Host has its own TLS key in the context the real Host refuses.
///
/// Pure and synchronous, so it can run in an isolate: a 3072-bit modPow is
/// too slow for the UI thread. Held to the same golden vector as the Host
/// (test/fixtures/host_bootstrap/host-claim-srp6a-v1.json), which also carries
/// RFC 5054 Appendix B.
const hostClaimPakeSuite = 'srp6a-rfc5054-3072-sha512-v1';

final _transcriptLabel = Uint8List.fromList([
  ...ascii.encode('eidolon-host-claim-pake-v1'),
  0,
]);
final _clientConfirmInfo =
    ascii.encode('eidolon-host-claim-pake-v1 client confirm');
final _serverConfirmInfo =
    ascii.encode('eidolon-host-claim-pake-v1 server confirm');

/// A value the protocol must refuse: a public value of the wrong width or
/// zero mod N, u = 0, or a context this side cannot encode canonically.
class HostClaimPakeRejected implements Exception {
  const HostClaimPakeRejected(this.reason);

  final String reason;

  @override
  String toString() => 'HostClaimPakeRejected: $reason';
}

/// SRP-6a over one group and hash, as RFC 5054 §2.5–2.6 computes it.
/// Parameterised only so RFC 5054 Appendix B (1024-bit, SHA-1) can check the
/// arithmetic; the claim uses [hostClaimGroup].
class SrpGroup {
  SrpGroup(this.N, this.g, this.hash)
      : width = (N.bitLength + 7) ~/ 8,
        _g = BigInt.from(g) {
    k = bigIntOf(digest([pad(N), pad(_g)]));
  }

  final BigInt N;
  final int g;
  final Hash hash;
  final int width;
  final BigInt _g;
  late final BigInt k;

  Uint8List digest(List<List<int>> parts) {
    final builder = BytesBuilder(copy: false);
    for (final part in parts) {
      builder.add(part);
    }
    return Uint8List.fromList(hash.convert(builder.takeBytes()).bytes);
  }

  Uint8List pad(BigInt value) => bytesOf(value, width);

  /// x = H(s || H(I ":" P)).
  BigInt privateKey(String identity, String password, List<int> salt) =>
      bigIntOf(digest([
        salt,
        digest([utf8.encode('$identity:$password')]),
      ]));

  BigInt verifier(String identity, String password, List<int> salt) =>
      _g.modPow(privateKey(identity, password, salt), N);

  /// A peer's A or B: exactly the group's width, and not zero mod N.
  BigInt publicValue(List<int> encoded) {
    if (encoded.length != width) {
      throw HostClaimPakeRejected('public value must be $width bytes');
    }
    final value = bigIntOf(encoded);
    if (value % N == BigInt.zero) {
      throw const HostClaimPakeRejected('public value is zero mod N');
    }
    return value;
  }

  BigInt scrambler(BigInt A, BigInt B) {
    final u = bigIntOf(digest([pad(A), pad(B)]));
    if (u == BigInt.zero) throw const HostClaimPakeRejected('u is zero');
    return u;
  }

  BigInt clientPublic(BigInt a) => _g.modPow(a, N);

  BigInt serverPublic(BigInt v, BigInt b) => (k * v + _g.modPow(b, N)) % N;

  BigInt clientSecret(BigInt B, BigInt x, BigInt a, BigInt u) {
    // Dart's % on a positive modulus is never negative.
    final base = (B - k * _g.modPow(x, N)) % N;
    return base.modPow(a + u * x, N);
  }

  BigInt serverSecret(BigInt A, BigInt v, BigInt u, BigInt b) =>
      (A * v.modPow(u, N) % N).modPow(b, N);
}

/// RFC 5054 Appendix A, 3072-bit group; the N devices use for Security 2 too.
final hostClaimGroup = SrpGroup(
  BigInt.parse(
    'ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74'
    '020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437'
    '4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed'
    'ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05'
    '98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb'
    '9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b'
    'e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718'
    '3995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33'
    'a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7'
    'abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864'
    'd87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e2'
    '08e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff',
    radix: 16,
  ),
  5,
  sha512,
);

BigInt bigIntOf(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

Uint8List bytesOf(BigInt value, int width) {
  final out = Uint8List(width);
  var remaining = value;
  for (var index = width - 1; index >= 0; index--) {
    out[index] = (remaining & _byteMask).toInt();
    remaining = remaining >> 8;
  }
  if (remaining != BigInt.zero) {
    throw const HostClaimPakeRejected('value does not fit its width');
  }
  return out;
}

final _byteMask = BigInt.from(0xff);

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List base64UrlDecodeNoPad(String text) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));

String hostClaimPassword(String code) =>
    sha256.convert(utf8.encode(code)).toString();

final _safeContextString = RegExp(r'^[A-Za-z0-9_:.\-]*$');

/// Canonical JSON: keys sorted, no whitespace, ASCII. Values are restricted
/// to what the context ever holds — UUIDs, base64url, `sha256:…`, a few
/// fixed words and a non-negative integer — so Dart's encoder cannot produce
/// a different spelling of the same object than the Host's does.
Uint8List hostClaimContextBytes(Map<String, Object> context) {
  final keys = context.keys.toList()..sort();
  final ordered = <String, Object>{};
  for (final key in keys) {
    final value = context[key]!;
    if (value is String && _safeContextString.hasMatch(value)) {
      ordered[key] = value;
    } else if (value is int && value >= 0) {
      ordered[key] = value;
    } else {
      throw HostClaimPakeRejected('context field $key is not canonical');
    }
  }
  return Uint8List.fromList(ascii.encode(jsonEncode(ordered)));
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

Uint8List hostClaimTranscript(
    Uint8List context, List<int> salt, BigInt A, BigInt B) {
  final group = hostClaimGroup;
  return group.digest([
    _transcriptLabel,
    _u32(context.length),
    context,
    _u32(salt.length),
    salt,
    group.pad(A),
    group.pad(B),
  ]);
}

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha512, key).convert(data).bytes);

Uint8List _hkdfExpand(List<int> prk, List<int> info, int length) {
  final output = BytesBuilder(copy: false);
  var block = <int>[];
  for (var counter = 1; output.length < length; counter++) {
    block = _hmac(prk, [...block, ...info, counter]);
    output.add(block);
  }
  return Uint8List.sublistView(output.takeBytes(), 0, length);
}

/// HKDF-SHA512 (RFC 5869) with the transcript as salt and K as input.
({Uint8List client, Uint8List server}) hostClaimConfirmationKeys(
    List<int> K, List<int> transcript) {
  final prk = _hmac(transcript, K);
  return (
    client: _hkdfExpand(prk, _clientConfirmInfo, 64),
    server: _hkdfExpand(prk, _serverConfirmInfo, 64),
  );
}

/// What the phone sends to confirm, and the one answer it will accept.
class HostClaimProof {
  const HostClaimProof({
    required this.clientPublic,
    required this.clientProof,
    required this.expectedServerProof,
  });

  /// A, 384 bytes, unpadded base64url.
  final String clientPublic;

  /// M1, unpadded base64url.
  final String clientProof;

  /// M2 as an honest Host that knows the code must send it.
  final String expectedServerProof;

  /// Constant time, and false for anything that is not a well-formed M2.
  bool acceptsServerProof(Object? presented) {
    if (presented is! String) return false;
    final Uint8List actual;
    try {
      actual = base64UrlDecodeNoPad(presented);
    } on FormatException {
      return false;
    }
    final expected = base64UrlDecodeNoPad(expectedServerProof);
    if (actual.length != expected.length) return false;
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= actual[index] ^ expected[index];
    }
    return difference == 0;
  }
}

/// Everything a proof needs, in a form an isolate can be handed.
class HostClaimProofRequest {
  const HostClaimProofRequest({
    required this.code,
    required this.identity,
    required this.context,
    required this.salt,
    required this.serverPublic,
  });

  final String code;

  /// SRP's I: the commissioning id of the window.
  final String identity;

  /// Built by the phone from what it pinned, never taken from the Host.
  final Map<String, Object> context;

  /// Unpadded base64url, as the Host sent them.
  final String salt;
  final String serverPublic;
}

/// The phone's half of one handshake. [a] is for tests; production draws it.
HostClaimProof proveHostClaim(HostClaimProofRequest request, {BigInt? a}) {
  final group = hostClaimGroup;
  final salt = base64UrlDecodeNoPad(request.salt);
  final B = group.publicValue(base64UrlDecodeNoPad(request.serverPublic));
  final ephemeral = a ?? _randomEphemeral();
  final A = group.clientPublic(ephemeral);
  final u = group.scrambler(A, B);
  final x = group.privateKey(
      request.identity, hostClaimPassword(request.code), salt);
  final K = group.digest([group.pad(group.clientSecret(B, x, ephemeral, u))]);
  final transcript = hostClaimTranscript(
      hostClaimContextBytes(request.context), salt, A, B);
  final keys = hostClaimConfirmationKeys(K, transcript);
  final m1 = _hmac(keys.client, transcript);
  final m2 = _hmac(keys.server, [...transcript, ...m1]);
  return HostClaimProof(
    clientPublic: base64UrlNoPad(group.pad(A)),
    clientProof: base64UrlNoPad(m1),
    expectedServerProof: base64UrlNoPad(m2),
  );
}

BigInt _randomEphemeral() {
  final random = Random.secure();
  return bigIntOf(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// Off the UI thread: the modPows take long enough to drop frames.
Future<HostClaimProof> proveHostClaimInBackground(
        HostClaimProofRequest request) =>
    Isolate.run(() => proveHostClaim(request));
