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
          companion: _companion(),
          devices: const MountedDeviceInventory(devices: []),
          onRename: () {},
          onOpenPersona: () {},
          face: face,
          onChangeFace: onChangeFace,
          onClearFace: onClearFace,
        ),
      ),
    );

/// The Eidolon this page is about.
HostCompanion _companion({String name = '小忆', String id = 'companion_primary'}) =>
    HostCompanion.fromView(
      CompanionSummaryView.fromJson({
        'companion_id': id,
        'display_name': name,
        'kind': 'conversational',
        'lifecycle_state': 'active',
        'revision': 4,
        'created_at': '2026-08-01T00:00:00+00:00',
        'updated_at': '2026-08-01T00:00:00+00:00',
        'running': true,
        'last_active_at': '2026-08-26T09:30:00+00:00',
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

    expect(find.text('更换伙伴头像'), findsOneWidget);
    // The avatar is now a preview. Editing is a labelled action in settings.
    await tester.ensureVisible(find.byKey(const Key('companion-change-face')));
    await tester.tap(find.byKey(const Key('companion-change-face')));
    expect(changed, 1);
    await tester.ensureVisible(find.byKey(const Key('companion-clear-face')));
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
