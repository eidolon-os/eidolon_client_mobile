import 'dart:convert';
import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_face_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/workspace_runtime_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real one-pixel JPEG.
///
/// Bytes that merely start with the JPEG marker are enough for the Host, which
/// only decides whether it will store them — but not for this test, which puts
/// them on screen, and a screen has to decode what it is given.
final _face = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtY'
    'XUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASst'
    'LTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4'
    '+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAA'
    'AAAAAAAAAAP/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAA'
    'AAAAAwT/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCQA1r/2Q==',
);

WorkspaceRuntime _runtime() => WorkspaceRuntime.fromJson({
  'contract_version': '1',
  'operation_id': '2f0c6f5c-0c4f-4b0e-9a6b-0d9a3a5f7e11',
  'state': 'ready',
  'owner': {
    'owner_id': 'owner_primary',
    'display_name': 'Manson',
    'lifecycle_state': 'active',
  },
  'primary_companion': {
    'companion_id': 'companion_primary',
    'display_name': '小忆',
    'lifecycle_state': 'active',
  },
  'persona': {
    'genome_id': 'genome_origin',
    'version': 1,
    'lifecycle_state': 'committed',
    'schema_version': 'eidolon.persona_genome',
    'genome_hash': 'sha256:${'a' * 64}',
    'realizer_version': '1',
  },
  'memory_workspace': {
    'realm_id': 'realm_primary',
    'lifecycle_state': 'active',
  },
});

Future<void> _open(
  WidgetTester tester, {
  Uint8List? face,
  VoidCallback? onChangeFace,
  VoidCallback? onClearFace,
}) => tester.pumpWidget(
  MaterialApp(
    home: CompanionPage(
      runtime: _runtime(),
      devices: const MountedDeviceInventory(devices: []),
      onRename: () {},
      onOpenHistory: () {},
      face: face,
      onChangeFace: onChangeFace,
      onClearFace: onClearFace,
    ),
  ),
);

void main() {
  testWidgets('an Eidolon without a face is offered one', (tester) async {
    await _open(tester, onChangeFace: () {});
    expect(find.text('给它一张脸'), findsOneWidget);
    // Nothing to take away yet, so the way to take it away is not offered.
    expect(find.byKey(const Key('companion-clear-face')), findsNothing);
  });

  testWidgets('a face is shown, and can be changed or taken back', (
    tester,
  ) async {
    var changed = 0;
    var cleared = 0;
    await _open(
      tester,
      face: _face,
      onChangeFace: () => changed += 1,
      onClearFace: () => cleared += 1,
    );

    expect(find.text('换一张脸'), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion-face')));
    expect(changed, 1);
    await tester.tap(find.byKey(const Key('companion-clear-face')));
    expect(cleared, 1);
  });

  testWidgets('a Host that cannot be told a face offers nothing to press', (
    tester,
  ) async {
    await _open(tester, face: _face);
    expect(find.byKey(const Key('companion-change-face')), findsNothing);
    expect(find.byKey(const Key('companion-clear-face')), findsNothing);
  });

  group('what the Host says about a face', () {
    test('a held copy is recognised as current by its hash, not by having one', () {
      const state = CompanionFaceState(
        companionId: 'companion_primary',
        hasFace: true,
        sha256: 'abc',
      );

      expect(state.matches('abc'), isTrue);
      // Holding *a* face is not holding *this* face — which is the whole
      // reason the Host answers with a hash instead of a boolean.
      expect(state.matches('def'), isFalse);
      expect(state.matches(null), isFalse);
    });

    test('no face means no copy is current, whatever is held', () {
      const state = CompanionFaceState(
        companionId: 'companion_primary',
        hasFace: false,
      );

      expect(state.matches('abc'), isFalse);
    });

    test('an answer that is not a v1 face state is refused', () {
      expect(
        () => CompanionFaceState.fromJson({'companion_id': 'c', 'has_face': 1}),
        throwsFormatException,
      );
      expect(
        () => CompanionFaceState.fromJson({'has_face': true}),
        throwsFormatException,
      );
    });
  });
}
