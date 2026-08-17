import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every platform method this app calls has to exist on the other side.
///
/// This test exists because of a real regression: the Dart half of device
/// provisioning was replaced with a new set of platform calls and the Android
/// half was never written. Nine unit tests passed — they were written against a
/// fake `MethodChannel`, which answers anything — while the product could not
/// set up a single device, and the first person to find out was the one holding
/// the tablet.
///
/// A fake proves that a caller behaves correctly given an answer. It cannot
/// prove that anyone is there to answer. That is what this reads the sources
/// for.
void main() {
  const channelName = 'live.eidolon.mobile/platform';

  test('every method Dart invokes is handled in MainActivity', () {
    final called = _methodsInvokedFromDart();
    final handled = _methodsHandledInKotlin();

    expect(
      called,
      isNotEmpty,
      reason: 'the reader found no platform calls, so it is not reading Dart',
    );
    expect(
      handled,
      isNotEmpty,
      reason: 'the reader found no handlers, so it is not reading Kotlin',
    );

    final missing = called.difference(handled).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'Dart calls these over $channelName and Android implements none of '
          'them, so the product fails on the device while the tests pass',
    );
  });

  test('MainActivity handles nothing Dart has stopped calling', () {
    final called = _methodsInvokedFromDart();
    final handled = _methodsHandledInKotlin();

    // The other half of the same mistake: a platform method kept alive after
    // its caller is gone reads as a working feature and is dead weight.
    final orphaned = handled.difference(called).toList()..sort();
    expect(orphaned, isEmpty);
  });
}

Set<String> _methodsInvokedFromDart() {
  // invokeMethod / invokeListMethod / invokeMapMethod, with the method name
  // either on the same line or wrapped onto the next one.
  final call = RegExp(
    "invoke(?:List|Map)?Method(?:<[^>]*>)?"
    "\\(\\s*'([a-zA-Z]+)'",
  );
  final methods = <String>{};
  for (final file in _dartSources()) {
    final source = file.readAsStringSync().replaceAll('\n', ' ');
    for (final match in call.allMatches(source)) {
      methods.add(match.group(1)!);
    }
  }
  return methods;
}

Set<String> _methodsHandledInKotlin() {
  final source = File(
    'android/app/src/main/kotlin/live/eidolon/eidolon_client_mobile/'
    'MainActivity.kt',
  ).readAsStringSync();
  final body = source.substring(source.indexOf('when (call.method)'));
  final branch = RegExp("^\\s*\"([a-zA-Z]+)\" ->", multiLine: true);
  return branch
      .allMatches(body.substring(0, body.indexOf('else -> result')))
      .map((match) => match.group(1)!)
      .toSet();
}

Iterable<File> _dartSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));
