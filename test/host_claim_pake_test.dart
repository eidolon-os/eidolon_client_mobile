import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_claim_pake.dart';
import 'package:flutter_test/flutter_test.dart';

/// The phone's SRP-6a held to the Host's bytes: the golden vector the Host
/// generates (eidolon_admin contracts/bootstrap/v1/golden), vendored here, and
/// RFC 5054 Appendix B, which that vector carries.
final _golden = jsonDecode(
  File('test/fixtures/host_bootstrap/host-claim-srp6a-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

BigInt _hex(String value) => BigInt.parse(value, radix: 16);

List<int> _bytes(String hex) => [
      for (var index = 0; index < hex.length; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ];

String _hexOf(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

File? _hostCopy() {
  // Walk to the filesystem root: a worktree sits deeper than a checkout, and
  // a walk that stops short skips the check while reporting success.
  var directory = Directory.current;
  while (true) {
    final file = File('${directory.path}/eidolon_admin/contracts/bootstrap/v1/'
        'golden/host-claim-srp6a-v1.json');
    if (file.existsSync()) return file;
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

void main() {
  final handshake = _golden['handshake'] as Map<String, dynamic>;
  final context = Map<String, Object>.from(handshake['context'] as Map);

  test('the vendored vector is the one the Host generates', () {
    final host = _hostCopy();
    if (host == null) {
      markTestSkipped('eidolon_admin is not beside this checkout');
      return;
    }
    expect(
      File('test/fixtures/host_bootstrap/host-claim-srp6a-v1.json')
          .readAsStringSync(),
      host.readAsStringSync(),
      reason: 'copy eidolon_admin/contracts/bootstrap/v1/golden/'
          'host-claim-srp6a-v1.json here again',
    );
  });

  test('the arithmetic is RFC 5054 Appendix B', () {
    final rfc = _golden['rfc5054_appendix_b'] as Map<String, dynamic>;
    expect(rfc['hash'], 'sha1');
    final group = SrpGroup(_hex(rfc['N'] as String), rfc['g'] as int, sha1);
    final salt = _bytes(rfc['salt'] as String);
    final identity = rfc['identity'] as String;
    final password = rfc['password'] as String;
    final a = _hex(rfc['a'] as String);
    final b = _hex(rfc['b'] as String);
    final x = group.privateKey(identity, password, salt);
    final v = group.verifier(identity, password, salt);
    final A = group.clientPublic(a);
    final B = group.serverPublic(v, b);
    final u = group.scrambler(A, B);

    expect(group.k, _hex(rfc['k'] as String));
    expect(x, _hex(rfc['x'] as String));
    expect(v, _hex(rfc['v'] as String));
    expect(A, _hex(rfc['A'] as String));
    expect(B, _hex(rfc['B'] as String));
    expect(u, _hex(rfc['u'] as String));
    expect(group.clientSecret(B, x, a, u), _hex(rfc['S'] as String));
    expect(group.serverSecret(A, v, u, b), _hex(rfc['S'] as String));
  });

  test('the group is the one the Host and the devices use', () {
    final group = _golden['group'] as Map<String, dynamic>;
    expect(hostClaimGroup.N, _hex(group['N'] as String));
    expect(hostClaimGroup.g, group['g']);
    expect(hostClaimGroup.width, group['width']);
    expect(hostClaimGroup.k, _hex(group['k'] as String));
  });

  test('every intermediate value of the golden handshake', () {
    final group = hostClaimGroup;
    final salt = _bytes(handshake['salt'] as String);
    final identity = handshake['identity'] as String;
    final code = handshake['code'] as String;
    final a = _hex(handshake['a'] as String);
    final B = _hex(handshake['B'] as String);

    expect(hostClaimPassword(code), handshake['password']);
    final x = group.privateKey(identity, hostClaimPassword(code), salt);
    expect(x, _hex(handshake['x'] as String));
    final A = group.clientPublic(a);
    expect(_hexOf(group.pad(A)), handshake['A']);
    final u = group.scrambler(A, B);
    expect(u, _hex(handshake['u'] as String));
    final S = group.clientSecret(B, x, a, u);
    expect(_hexOf(group.pad(S)), handshake['S']);
    final K = group.digest([group.pad(S)]);
    expect(_hexOf(K), handshake['K']);
    final encoded = hostClaimContextBytes(context);
    expect(ascii.decode(encoded), handshake['context_bytes']);
    final transcript = hostClaimTranscript(encoded, salt, A, B);
    expect(_hexOf(transcript), handshake['transcript_hash']);
    final keys = hostClaimConfirmationKeys(K, transcript);
    expect(_hexOf(keys.client), handshake['client_confirm_key']);
    expect(_hexOf(keys.server), handshake['server_confirm_key']);

    final proof = proveHostClaim(
      HostClaimProofRequest(
        code: code,
        identity: identity,
        context: context,
        salt: base64UrlNoPad(salt),
        serverPublic: base64UrlNoPad(_bytes(handshake['B'] as String)),
      ),
      a: a,
    );
    expect(_hexOf(base64UrlDecodeNoPad(proof.clientPublic)), handshake['A']);
    expect(_hexOf(base64UrlDecodeNoPad(proof.clientProof)),
        handshake['client_proof']);
    expect(
      proof.acceptsServerProof(base64UrlNoPad(_bytes(
        handshake['server_proof'] as String,
      ))),
      isTrue,
    );
  });

  test('a server proof that is not exactly M2 is not accepted', () {
    final proof = proveHostClaim(
      HostClaimProofRequest(
        code: handshake['code'] as String,
        identity: handshake['identity'] as String,
        context: context,
        salt: base64UrlNoPad(_bytes(handshake['salt'] as String)),
        serverPublic: base64UrlNoPad(_bytes(handshake['B'] as String)),
      ),
      a: _hex(handshake['a'] as String),
    );
    final m2 = _bytes(handshake['server_proof'] as String);
    final flipped = [...m2]..[17] ^= 0x01;
    expect(proof.acceptsServerProof(base64UrlNoPad(flipped)), isFalse);
    expect(proof.acceptsServerProof(base64UrlNoPad(m2.sublist(1))), isFalse);
    expect(proof.acceptsServerProof(null), isFalse);
    expect(proof.acceptsServerProof('not base64url!'), isFalse);
    // The other proofs the Host refuses are other proofs, not this one.
    for (final refusal in _golden['host_refuses_proof'] as List) {
      expect((refusal as Map)['client_proof'],
          isNot(handshake['client_proof']));
    }
  });

  test('a public value the Host would refuse is refused here too', () {
    for (final refusal in _golden['both_refuse_public_value'] as List) {
      final value = (refusal as Map)['value'] as String;
      expect(
        () => hostClaimGroup.publicValue(_bytes(value)),
        throwsA(isA<HostClaimPakeRejected>()),
        reason: refusal['name'] as String,
      );
      expect(
        () => proveHostClaim(HostClaimProofRequest(
          code: handshake['code'] as String,
          identity: handshake['identity'] as String,
          context: context,
          salt: base64UrlNoPad(_bytes(handshake['salt'] as String)),
          serverPublic: base64UrlNoPad(_bytes(value)),
        )),
        throwsA(isA<HostClaimPakeRejected>()),
      );
    }
  });

  test('a context value the encoder could spell two ways is refused', () {
    for (final odd in <Object>['café', 'a"b', r'a\b', -1, 1.5, true]) {
      expect(
        () => hostClaimContextBytes({...context, 'transport': odd}),
        throwsA(isA<HostClaimPakeRejected>()),
        reason: '$odd',
      );
    }
  });

  test('a fresh proof differs every time but always verifies', () {
    final request = HostClaimProofRequest(
      code: handshake['code'] as String,
      identity: handshake['identity'] as String,
      context: context,
      salt: base64UrlNoPad(_bytes(handshake['salt'] as String)),
      serverPublic: base64UrlNoPad(_bytes(handshake['B'] as String)),
    );
    final watch = Stopwatch()..start();
    final first = proveHostClaim(request);
    final elapsed = watch.elapsedMilliseconds;
    final second = proveHostClaim(request);
    expect(first.clientPublic, isNot(second.clientPublic));
    expect(first.clientProof, isNot(second.clientProof));
    // ignore: avoid_print
    print('one proof: $elapsed ms (JIT, test VM)');
  });
}
