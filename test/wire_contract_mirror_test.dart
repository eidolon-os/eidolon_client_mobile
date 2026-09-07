import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// This client's wire vocabulary, held to the SDK's.
///
/// `eidolon_sdk/biz/contracts` is Python, is not vendored, and is never
/// transmitted, so the only thing that carries it here is somebody copying a
/// value. That is how the session-control request came to be sent one member
/// short of the contract for twelve days: the SDK added
/// `SESSION_CONVERSATION_ID_FIELD` on 2026-08-26 and made it required, the
/// firmware followed the same day, and this client did not. The Channel
/// Provider discarded every request the phone made — silently, because
/// `normalize_conversation_id(null)` is null and a null there is dropped
/// without a log line.
///
/// A mirror test for this file already existed in the SDK. It asserted a
/// hand-picked list of six constants, and the constant that had just been
/// added was not on it. That is the same failure as a lock covering thirteen
/// of fourteen files, and it is why the checker's unit is a *vocabulary*
/// rather than a constant: every SDK name in a declared vocabulary must carry
/// a decision in `wire_contract_mirror.json`, so a new one lands in neither
/// column and fails.
///
/// It runs here rather than only in the SDK for a reason this session earned:
/// the test that was supposed to protect this repository lived in another
/// repository, and nothing here went red when it fell short. A client that
/// cannot check itself is a client that finds out on hardware.
void main() {
  test('the wire vocabulary agrees with the SDK, and nothing is undecided', () {
    final sdk = Directory('../eidolon_sdk/eidolon_sdk/biz/contracts');
    if (!sdk.existsSync()) {
      // Named rather than silent, the way `device_foundation_lock_test.dart`
      // names its half: this says which check did not run and why, so a green
      // suite cannot be mistaken for a verified one.
      markTestSkipped(
        'the SDK repository is not beside this one, so the wire vocabulary '
        'could not be compared; every other check in this suite still ran',
      );
      return;
    }

    final result = Process.runSync(
      'python3',
      ['tool/check_wire_contract_mirror.py'],
    );

    expect(
      result.exitCode,
      0,
      reason: '${result.stdout}\n${result.stderr}',
    );
  });

  test('the ledger decides, rather than listing what is convenient', () {
    // The ledger is the thing that can be made to pass by choosing less, so
    // its own shape is asserted: every entry carries exactly one of the two
    // decisions, and a "not mirrored" carries a reason somebody can argue
    // with rather than an empty string.
    final ledger = File('wire_contract_mirror.json');
    expect(ledger.existsSync(), isTrue);

    final decoded = ledger.readAsStringSync();
    expect(decoded, contains('"constants"'));
    // The scope is the whole contract file, not a list of prefixes. That list
    // was itself a roll-call and it went short by twenty constants — three of
    // which this client had mirrored all along with nothing checking them —
    // so a ledger that reintroduces one has reintroduced the fault.
    expect(
      decoded,
      isNot(contains('"vocabularies"')),
      reason: 'the boundary is the contract file; a prefix list can go short',
    );

    final constants = RegExp(r'"([A-Z][A-Z0-9_]*)":\s*\{([^}]*)\}')
        .allMatches(decoded);
    expect(constants, isNotEmpty);
    for (final entry in constants) {
      final body = entry.group(2)!;
      final mirrored = body.contains('"dart"');
      final unmirrored = body.contains('"not_mirrored"');
      expect(
        mirrored ^ unmirrored,
        isTrue,
        reason: '${entry.group(1)} must be mirrored or explained, not both '
            'and not neither',
      );
      if (unmirrored) {
        final reason = RegExp(r'"not_mirrored":\s*"([^"]*)"').firstMatch(body);
        expect(reason, isNotNull, reason: entry.group(1));
        expect(
          reason!.group(1)!.trim().length,
          greaterThan(20),
          reason: '${entry.group(1)} needs a reason, not a placeholder',
        );
      }
    }
  });
}
