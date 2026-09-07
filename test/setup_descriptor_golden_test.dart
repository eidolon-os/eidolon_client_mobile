import 'dart:convert';
import 'dart:io';

import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter_test/flutter_test.dart';

/// The setup descriptor used to be a field table written out by hand in the
/// firmware and a second one written out by hand here, kept in step by a person
/// comparing two files. It stopped being in step the way that always happens:
/// the device encoded "this offer never ends" as `expires_in_seconds: 0`, this
/// side required a duration it could act on, and every device out of the box was
/// refused with "the description this device returned does not match the v1
/// contract" — while neither end was wrong about its own half.
///
/// So the field table lives in the SDK now, this file asserts against the golden
/// vector synced byte-for-byte by tool/sync_device_foundation_v1.py, and a
/// field added to the contract without reaching this binding is a red test
/// rather than a device the Owner cannot set up.
void main() {
  Map<String, dynamic> vector() => jsonDecode(
        File(
          'test/fixtures/device_foundation/setup-descriptor.json',
        ).readAsStringSync(),
      ) as Map<String, dynamic>;

  Map<String, dynamic> shape(String name) => Map<String, dynamic>.from(
        (vector()[name]! as Map)['descriptor']! as Map,
      );

  test('the generated binding declares exactly the fields the vector does', () {
    final golden = vector();
    expect(
      SetupDescriptorV1.requiredFields,
      (golden['required_fields']! as List).cast<String>().toSet(),
    );
    expect(
      SetupDescriptorV1.optionalFields,
      (golden['optional_fields']! as List).cast<String>().toSet(),
    );
    expect(SetupDescriptorV1.contractVersion, golden['contract_version']);
    expect(
      SetupDescriptorTrustV1.values.map((value) => value.wireValue).toSet(),
      (golden['trust_values']! as List).cast<String>().toSet(),
    );
  });

  test('the golden descriptor parses through the generated binding', () {
    for (final name in ['bounded_window', 'no_deadline']) {
      final descriptor = SetupDescriptorV1.fromJson(shape(name));
      expect(descriptor.toJson(), shape(name));
    }
    expect(
      SetupDescriptorV1.fromJson(shape('bounded_window')).expiresIn!.seconds,
      600,
    );
    expect(SetupDescriptorV1.fromJson(shape('no_deadline')).expiresIn, isNull);
  });

  test('a field nobody declared is not a descriptor', () {
    // The exact-key check is what makes the golden vector load-bearing: a field
    // added in the SDK and not carried into this binding arrives as a key this
    // side has never heard of, and is refused instead of silently dropped.
    final value = shape('bounded_window')
      ..['expires_at'] = '2026-08-25T00:00:00Z';
    expect(() => SetupDescriptorV1.fromJson(value), throwsFormatException);
    for (final field in SetupDescriptorV1.requiredFields) {
      final missing = shape('bounded_window')..remove(field);
      expect(
        () => SetupDescriptorV1.fromJson(missing),
        throwsFormatException,
        reason: field,
      );
    }
  });

  test('no number stands in for an offer that does not end', () {
    for (final encoded in <Object?>[0, -1, 1.5, '600', true, null]) {
      final value = shape('bounded_window')..['expires_in_seconds'] = encoded;
      expect(
        () => SetupDescriptorV1.fromJson(value),
        throwsFormatException,
        reason: '$encoded',
      );
    }
    // And the absence is the answer rather than a fault, which is the whole of
    // the regression this vector exists to hold shut.
    final endless = shape('bounded_window')..remove('expires_in_seconds');
    expect(SetupDescriptorV1.fromJson(endless).expiresIn, isNull);
  });

  test('every rejected duration the SDK names is rejected here too', () {
    // Including null: writing the key with nothing in it is a producer reaching
    // for a stand-in, and it must not read as the absence that means "this
    // offer does not end".
    for (final encoded in vector()['rejected_expires_in_seconds']! as List) {
      final value = shape('bounded_window')..['expires_in_seconds'] = encoded;
      expect(
        () => SetupDescriptorV1.fromJson(value),
        throwsFormatException,
        reason: '$encoded',
      );
    }
  });
}
