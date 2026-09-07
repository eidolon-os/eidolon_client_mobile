import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lock that says which canonical bytes this app was built against.
///
/// This file is the gate. `docs/设备与Body/Manifest契约收敛.md` §9.2 ① found
/// that this repository's sync check had **no caller** — not in `scripts/`, the
/// README, docs, git hooks or the build — so fourteen vendored files stayed in
/// step only while someone remembered to run it by hand. A check nobody runs is
/// not a check, and the missing digests were the second-order problem: a check
/// with nothing to compare against has nothing to compare.
///
/// So the half that needs no SDK checkout lives here, in the suite that runs on
/// every change: the lock's shape, the vendored bytes against their recorded
/// digests, and — the one that matters most — that the lock covers everything
/// vendored on disk. `tool/sync_device_foundation_v1.py --check` owns the other
/// half, which is whether the lock still agrees with the pinned SDK commit, and
/// needs the SDK repository to answer.
///
/// The coverage assertion is not ceremony. Building this lock the first time,
/// a character class that spelled `[A-Z_]+` silently dropped `ES256` and
/// produced a lock covering thirteen of fourteen files — passing, and blind to
/// the fourteenth. A check that verifies a set it also chooses can always be
/// made to pass by choosing less.
void main() {
  final lock = jsonDecode(
    File('device_foundation_sdk.lock.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  List<Map<String, dynamic>> entries() => (lock['files']! as List<Object?>)
      .cast<Map<String, dynamic>>()
      .toList(growable: false);

  test('the pin names bytes, and a whole commit is the only way to', () {
    // An abbreviation is resolved by git against whatever the SDK holds at the
    // time, so it can start meaning something else, or stop resolving, as
    // history grows — for the one field whose whole job is to say which bytes.
    // This repository shipped ten whole ids and then one seven-character one,
    // and nothing was observably wrong. Enforced here rather than in review
    // because it is cheap to violate for a long time before it is expensive.
    expect(
      RegExp(r'^[0-9a-f]{40}$').hasMatch(lock['sdk_commit'] as String),
      isTrue,
      reason: 'sdk_commit must be a whole 40-character lowercase commit id',
    );
  });

  test('the lock names files, because a check with nothing to check passes',
      () {
    expect(entries(), isNotEmpty);
    for (final entry in entries()) {
      expect(entry.keys.toSet(), <String>{'source', 'target', 'sha256'});
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(entry['sha256'] as String),
        isTrue,
        reason: '${entry['target']} has no usable digest',
      );
    }
  });

  test('every vendored file is the bytes the lock recorded', () {
    // The independent record. Comparing a copy against the pin alone cannot
    // tell "the pin still means what it meant" from "the pin moved and my copy
    // was silently synced to the new thing"; this can.
    for (final entry in entries()) {
      final target = File(entry['target'] as String);
      expect(target.existsSync(), isTrue, reason: '${target.path} is missing');
      expect(
        sha256.convert(target.readAsBytesSync()).toString(),
        entry['sha256'],
        reason: '${target.path} is not the bytes this app was built against',
      );
    }
  });

  test('the lock covers every vendored file on disk', () {
    // The assertion that would have caught a lock covering thirteen of
    // fourteen. A file that is vendored and unlocked is worse than one that is
    // not vendored at all: the tests read it, so stale bytes stay
    // self-consistently green.
    final covered = entries().map((entry) => entry['target'] as String).toSet();
    final onDisk = <String>{
      'lib/src/generated/device_foundation_v1.dart',
      ...Directory('test/fixtures/device_foundation')
          .listSync()
          .whereType<File>()
          .map((file) => file.path),
    };

    expect(
      onDisk.difference(covered),
      isEmpty,
      reason: 'vendored from the SDK but not locked, so nothing checks it',
    );
    expect(
      covered.difference(onDisk),
      isEmpty,
      reason: 'locked but not on disk, so the lock describes a file nobody has',
    );
  });

  test('the lock still agrees with the pinned SDK commit', () {
    // The other half, and the one that needs the SDK repository: whether the
    // pin still resolves to the bytes the lock recorded. `flutter test` is what
    // the release gate runs for this repo (`REQUIRED_TESTS` in
    // `eidolon_ops/device_management_gate.py` lists "tests"), so this is where
    // it belongs — the same place ESP32 puts its runner inside `host-tests`.
    final sdk = Directory('../eidolon_sdk/.git');
    if (!sdk.existsSync()) {
      // Named rather than silent. A skip that says nothing is the shape
      // `docs/设备与Body/Manifest契约收敛.md` §9.1 calls out in another repo;
      // this one says which half went unchecked and which half did not.
      markTestSkipped(
        'the SDK repository is not beside this one, so the pin could not be '
        'resolved; the vendored bytes were still checked against the lock',
      );
      return;
    }
    final result = Process.runSync(
      'python3',
      ['tool/sync_device_foundation_v1.py', '--check'],
    );

    expect(
      result.exitCode,
      0,
      reason: '${result.stdout}\n${result.stderr}',
    );
  });
}
