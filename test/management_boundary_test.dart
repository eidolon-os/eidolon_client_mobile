import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The management surface may only reach the Host through the generated client.
///
/// Phase 0's last gate, and the reason it is a test rather than a convention is
/// sitting right next to it: `LocalApiClient` is 27 hand-written methods over
/// `/api/local/v1`, grown one call at a time, and the cheapest way to add a
/// management feature is to add method 28. That works, once. Then this app and
/// Admin Web hold two different opinions of the same wire, and the document
/// neither is generated from stops being the contract.
///
/// Read from the sources, because the failure is an import that compiles.
void main() {
  final management = Directory('lib/src/management');
  final files = management
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('there are sources to check, so this gate cannot pass vacuously', () {
    expect(files, isNotEmpty);
  });

  test('nothing here imports the hand-written Local API client', () {
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(contains('local_api_client.dart')),
        reason: '${file.path} imports the hand-written client',
      );
      // The feature folder is where the composition root lives; depending on it
      // from here would invert the direction that keeps this surface generated.
      expect(
        source,
        isNot(contains("features/host_setup")),
        reason: '${file.path} depends on the feature it is composed by',
      );
    }
  });

  test('nothing here spells a Host path itself', () {
    // A literal path is a second definition of the contract — and the one that
    // will not be regenerated when the document changes. The generated file is
    // where paths belong, and it builds them from the document.
    for (final file in files) {
      final source = file.readAsStringSync();
      if (file.path.endsWith('management_v1.dart')) continue;
      expect(
        source,
        isNot(contains("'/api/")),
        reason: '${file.path} contains a literal API path',
      );
    }
  });

  test('the generated types stay generated', () {
    final generated = File('lib/src/generated/management_v1.dart');
    expect(generated.existsSync(), isTrue);
    // The header is what a person reads before editing it; the drift gate in
    // the Admin test suite is what stops them.
    expect(generated.readAsStringSync(), contains('Do not edit by hand'));
  });
}
