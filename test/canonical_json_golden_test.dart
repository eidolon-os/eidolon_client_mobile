import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/protocol/canonical_json.dart';
import 'package:flutter_test/flutter_test.dart';

/// One canonicaliser, held to every vector that depends on it.
///
/// Two unrelated features authenticate over canonical JSON bytes — the Owner
/// Domain descriptor's signature and the ClaimGrant's AAD — and until this test
/// existed only the first had a vector. That is the shape of the problem: a
/// rule with one home and one pin is safe, and the moment a second caller
/// arrives without a second pin, the rule quietly becomes "whatever the first
/// caller happened to need".
///
/// So the subject here is `canonicalJsonEncode` itself rather than any one
/// caller. A third consumer should add its vector to this file, not a
/// canonicaliser to its own feature.
Map<String, dynamic> _golden(String name) =>
    jsonDecode(
      File('test/fixtures/device_foundation/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  test('Owner Domain descriptor signing bytes match the golden', () {
    final vector = _golden('owner-domain-descriptor.json');
    final document = Map<String, dynamic>.from(vector['descriptor']! as Map)
      ..remove('signature');

    expect(canonicalJsonEncode(document), vector['canonical_signing_utf8']);
  });

  test('ClaimGrant AAD canonical bytes match the wire envelope golden', () {
    final vector = _golden('claim-grant-wire-envelope.json');
    final envelope = vector['envelope']! as Map<String, dynamic>;

    final canonical = canonicalJsonEncode(envelope['aad']);

    // Byte-for-byte, not "same fields". Two implementations agreeing on the
    // field set and disagreeing on the bytes is precisely the failure AEAD
    // authentication cannot describe: the tag is simply wrong.
    expect(canonical, vector['aad_canonical_utf8']);
    expect(
      'sha256:${sha256.convert(utf8.encode(canonical))}',
      vector['aad_sha256'],
    );
  });

  test('ClaimGrant AAD canonical bytes match the AAD golden', () {
    // A second vector over the same rule, with a different AAD — a derived
    // instance id, `proposal_revision: 3`, `trust_epoch: 4`. Not redundant: it
    // is the one that would stay green if the envelope vector were regenerated
    // wrongly, and vice versa.
    final vector = _golden('claim-grant-aad.json');

    final canonical = canonicalJsonEncode(vector['aad']);

    // The string, not only its digest. A digest can say "not these bytes" and
    // nothing more, and this is the document neither end ever sends — both
    // build it from the Proposal they hold and feed it to the AEAD — so a
    // canonicaliser that disagrees on one member shows up as a ClaimGrant that
    // will not open, which reads like a key or transport fault. The SDK now
    // publishes the canonical string beside the digest for exactly that
    // reason; asserting against it is what names the member.
    expect(canonical, vector['canonical_aad_utf8']);
    // Kept, and now a different assertion: that the vector's two forms are one
    // document. They are produced by one `rfc8785.dumps` in the SDK, so this
    // is cheap — and it is the assertion that fails if a future regeneration
    // updates one and not the other.
    expect(
      sha256.convert(utf8.encode(canonical)).toString(),
      vector['canonical_aad_sha256'],
    );
  });

  test('admission evidence canonical bytes match the voucher golden', () {
    // The document this phone will sign to propose itself as a Body. It is
    // pinned here rather than in the admission client because the thing that
    // can be wrong about it is the encoder, and the encoder is what this file
    // is about — the client only chooses which four fields go in.
    final vector = _golden('commissioning-voucher.json');

    expect(
      canonicalJsonEncode(vector['evidence_document']),
      vector['evidence_canonical_utf8'],
    );
  });

  test('the Device Foundation command envelope matches the RFC 8785 vector', () {
    final vector = _golden('canonical-vectors.json');
    final envelope = (vector['vectors']! as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['vector_id'] == 'DF-COMMAND-ENVELOPE-001');

    expect(canonicalJsonEncode(envelope['value']), envelope['canonical_utf8']);
  });

  test('string escaping matches RFC 8785 section 3.2.2', () {
    // The standard's own vector. Its `numbers` are refused (see below), but its
    // string is the interesting half either way: control characters, a
    // non-ASCII code point, quotes and backslashes are where two encoders that
    // agree on every Eidolon document so far would first disagree.
    final vector = _golden('canonical-vectors.json');
    final rfc = (vector['vectors']! as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['vector_id'] == 'RFC8785-SECTION-3.2.2');
    final value = rfc['value']! as Map<String, dynamic>;
    final canonical = rfc['canonical_utf8']! as String;

    // Taken from the authority rather than transcribed: everything the vector
    // renders after `"string":`, which is that member's canonical form.
    final expectedString =
        canonical.substring(canonical.indexOf('"string":') + '"string":'.length,
            canonical.length - 1);

    expect(
      canonicalJsonEncode(<String, Object?>{
        'literals': value['literals'],
        'string': value['string'],
      }),
      '{"literals":[null,true,false],"string":$expectedString}',
    );
  });

  test('the vector this canonicaliser cannot render is refused by name', () {
    // RFC 8785 section 3.2.2.3 formats numbers with ECMAScript
    // `Number::toString`, which this app does not implement because no Eidolon
    // contract carries a fractional number. That is a real gap, and this test
    // is where it is admitted: the vector exists, it is vendored, and the
    // encoder refuses it rather than producing bytes that merely look right.
    final vector = _golden('canonical-vectors.json');
    final rfc = (vector['vectors']! as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['vector_id'] == 'RFC8785-SECTION-3.2.2');

    expect(
      () => canonicalJsonEncode(rfc['value']),
      throwsA(isA<FormatException>()),
    );
  });

  test('member names are ordered by UTF-16 code unit, not by locale', () {
    // RFC 8785 §3.2.3. Spelled out because a locale-aware sort would put these
    // in a different order and every vector above would still pass — they
    // happen to contain only lowercase ASCII names.
    final encoded = canonicalJsonEncode(<String, Object?>{
      'b': 1,
      'A': 2,
      'a': 3,
      'B': 4,
      'Z': 5,
    });

    expect(encoded, '{"A":2,"B":4,"Z":5,"a":3,"b":1}');
  });

  test('nested objects are ordered at every depth', () {
    final encoded = canonicalJsonEncode(<String, Object?>{
      'outer': <String, Object?>{'z': 1, 'a': 2},
      'list': <Object?>[
        <String, Object?>{'y': 1, 'b': 2},
      ],
    });

    expect(encoded, '{"list":[{"b":2,"y":1}],"outer":{"a":2,"z":1}}');
  });

  test('a fractional number is refused rather than rendered the Dart way', () {
    // Dart renders an integral double as `2.0` where RFC 8785 renders `2`, so
    // letting numbers through would produce bytes that hash differently from
    // the signer's with nothing to show for it. Refusing names the gap.
    expect(
      () => canonicalJsonEncode(<String, Object?>{'value': 2.0}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => canonicalJsonEncode(<String, Object?>{'value': 1.5}),
      throwsA(isA<FormatException>()),
    );
  });

  test('a non-string member name is refused', () {
    expect(
      () => canonicalJsonEncode(<Object, Object?>{1: 'one'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('a value that is not JSON is refused', () {
    expect(
      () => canonicalJsonEncode(<String, Object?>{'when': DateTime(2026)}),
      throwsA(isA<FormatException>()),
    );
  });
}
