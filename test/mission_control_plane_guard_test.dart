import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two regressions this app has already had, turned into gates.
///
/// The star map's snapshot read was first written onto `/api/local/v1` — the
/// Owner product surface the convergence plan deletes — and hand-written as a
/// 28th method on the client that surface is reached through. Both are the kind
/// of mistake that compiles, ships, and is only noticed by whoever reads the
/// plan next. And the words for "which Companion answers by default" were
/// changed to 默认/DEFAULT across the other two clients precisely because two
/// clients using different words for one fact is how they start disagreeing;
/// this surface was the third voice.
void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('there are sources to check, so these gates cannot pass vacuously', () {
    expect(sources, isNotEmpty);
  });

  test('nothing reaches Mission Control on the plane being deleted', () {
    for (final file in sources) {
      expect(
        file.readAsStringSync(),
        isNot(contains('/api/local/v1/mission-control')),
        reason: '${file.path} reads Mission Control from the deprecated plane; '
            'the target is /api/management/v1, through the generated client',
      );
    }
  });

  test('the star map says 默认, never 主伙伴 or PRIMARY', () {
    final constellation = sources.where(
      (file) => file.path.contains('features/constellation'),
    );
    expect(constellation, isNotEmpty);
    for (final file in constellation) {
      final source = file.readAsStringSync();
      for (final retired in const ['主伙伴', 'PRIMARY', 'isPrimary']) {
        expect(
          source,
          isNot(contains(retired)),
          reason: '${file.path} still says "$retired"; the roster, the '
              'management ABI and Admin Web all say default',
        );
      }
    }
  });

  test('no per-row default flag: the snapshot says it once', () {
    // A flag on every row is a second place the same question gets decided, and
    // it is only ever right while there is one Companion.
    for (final file in sources) {
      expect(
        file.readAsStringSync(),
        isNot(contains('is_primary')),
        reason: '${file.path} reads a per-row default flag off the wire',
      );
    }
  });
}
