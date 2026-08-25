import 'dart:convert';
import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/companion_page.dart';
import 'package:flutter/material.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/home_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
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


Future<void> _open(
  WidgetTester tester, {
  Uint8List? face,
  VoidCallback? onChangeFace,
  VoidCallback? onClearFace,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: CompanionPage(
          home: _home(),
          devices: const MountedDeviceInventory(devices: []),
          onRename: () {},
          onOpenHistory: () {},
          face: face,
          onChangeFace: onChangeFace,
          onClearFace: onClearFace,
        ),
      ),
    );

/// What the Host now answers when a screen opens: words a person can act on,
/// with the identifiers underneath.
HostHome _home({String name = '小忆', String? companionId = 'companion_primary'}) =>
    HostHome.fromView(
      HomeView.fromJson({
        'contract_version': '1',
        'owner_display_name': 'Manson',
        'owner_revision': 3,
        'answering': companionId == null
            ? null
            : {
                'companion_id': companionId,
                'display_name': name,
                'lifecycle_state': 'active',
                'revision': 4,
                'has_face': false,
                'persona_chapter': '第 1 章 · 它刚来的样子',
                'memory': '还没记下什么',
                'persona_genome_id': 'genome_origin',
              },
        'companions': {'total': 1, 'ready': 1, 'waiting': 0, 'put_away': 0},
        'devices': {'total': 0, 'ready': 0, 'waiting': 0, 'put_away': 0},
        'machine_attention': <String>[],
        'unavailable': <String, String>{},
      }),
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

  // The hash-comparison model that used to live here is gone with the
  // two-call read: this app no longer decides whether its copy is current, it
  // sends what it holds and the Host answers 304. That exchange is covered in
  // ``companion_face_client_test.dart``.
}
