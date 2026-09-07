/// RFC 8785 JSON Canonicalisation, for this app's one definition of it.
///
/// Two things in this product are signed or authenticated over canonical JSON
/// bytes rather than over a document: the Owner Domain descriptor's signature,
/// and the ClaimGrant's AAD. They are unrelated features that happen to need
/// the identical rule, and the rule is not "encode the JSON" — it is a specific
/// ordering and encoding that two independent implementations can only agree on
/// by both being right.
///
/// So it lives here, once. It used to be a private `_canonicalJson` inside the
/// Owner Domain verifier, which was correct and unreachable; the ClaimGrant
/// path needed the same rule and the cheap move was to write it again. This
/// repository has spent a lot of its history on what happens next when one rule
/// has two homes — see `protocol/companion_contract.dart` for the same story
/// about a vocabulary, and `docs/设备与Body/Manifest契约收敛.md` for what five
/// homes cost.
///
/// Boundary, matching the rest of `protocol/`: no Flutter, no feature imports.
/// The authority for the bytes is not this file — it is the SDK's golden
/// vectors, which `test/canonical_json_golden_test.dart` holds it to.
library;

import 'dart:collection';
import 'dart:convert';

/// The canonical UTF-8 form of [value], as a Dart string.
///
/// Accepts the JSON value types only. What it produces is what a signer on the
/// other end hashed, so anything this cannot render exactly is refused rather
/// than approximated — an approximated byte here is a signature that fails with
/// no explanation at the far end of the link.
String canonicalJsonEncode(Object? value) => jsonEncode(canonicalJsonValue(value));

/// [value] rebuilt with every object's keys in canonical order.
///
/// Exposed separately from [canonicalJsonEncode] because a caller sometimes
/// needs the ordered structure itself — to hash it, or to hand it to something
/// that will encode it — and re-parsing an encoded string to get it back is how
/// a second, subtly different ordering gets introduced.
Object? canonicalJsonValue(Object? value) {
  if (value == null || value is String || value is bool) return value;
  if (value is int) return value;
  if (value is double) {
    // RFC 8785 §3.2.2.3 serialises numbers with the ECMAScript
    // `Number::toString` algorithm, which Dart's `jsonEncode` does not
    // implement: an integral double renders as `2.0` where the canonical form
    // is `2`, and the two hash differently. No contract in this product carries
    // a fractional number, so this is refused rather than silently rendered the
    // Dart way. If one ever does, the fix is to implement that algorithm here —
    // not to let this through.
    throw FormatException(
      'Canonical JSON cannot render the number $value: '
      'RFC 8785 number formatting is not implemented, and no Eidolon contract '
      'uses a non-integer number',
    );
  }
  if (value is List) {
    return value.map(canonicalJsonValue).toList(growable: false);
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('Canonical JSON keys must be strings');
    }
    // RFC 8785 §3.2.3 orders member names by their UTF-16 code units, which is
    // exactly what Dart's `String.compareTo` compares.
    final keys = value.keys.cast<String>().toList()..sort();
    return LinkedHashMap<String, Object?>.fromEntries(
      keys.map((key) => MapEntry(key, canonicalJsonValue(value[key]))),
    );
  }
  throw FormatException(
    'Canonical JSON cannot render a ${value.runtimeType}',
  );
}
