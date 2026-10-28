import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/person_face_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/face_picker.dart';

// Valid one-pixel PNG; no real biometric fixture is stored in the test suite.
final photo = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=');

class Picker implements FacePicker {
  @override
  Future<Uint8List?> pickFace() async => photo;
}

void main() {
  testWidgets(
      'photo can be added replaced and deleted without enabling recognition',
      (tester) async {
    var revision = 0;
    var hasImage = false;
    final expected = <int>[];
    await tester.pumpWidget(MaterialApp(
        home: PersonFacePage(
            name: '甲',
            active: true,
            picker: Picker(),
            call: ({method = 'GET', suffix = '', body}) async {
              if (method == 'PUT') {
                expected.add(body!['expected_revision'] as int);
                expect(
                    body.keys.toSet(), {'expected_revision', 'image_base64'});
                revision++;
                hasImage = true;
              }
              if (method == 'DELETE') {
                expect(suffix, '?expected_revision=2');
                revision++;
                hasImage = false;
              }
              if (suffix == '/image')
                return {
                  'revision': revision,
                  'image_base64': base64Encode(photo)
                };
              return {
                'person_id': 'p',
                'revision': revision,
                'has_image': hasImage,
                'recognition_state': 'not_configured'
              };
            })));
    await tester.pumpAndSettle();
    expect(find.text('尚未添加照片'), findsOneWidget);
    await tester.tap(find.text('添加照片'));
    await tester.pumpAndSettle();
    expect(find.text('照片已保存 · 识别尚未启用'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.ensureVisible(find.text('更换照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更换照片'));
    await tester.pumpAndSettle();
    expect(expected, [0, 1]);
    await tester.ensureVisible(find.text('删除照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('尚未添加照片'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('inactive person cannot add photo', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: PersonFacePage(
            name: '甲',
            active: false,
            picker: Picker(),
            call: ({method = 'GET', suffix = '', body}) async =>
                {'revision': 0, 'has_image': false})));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
  });
}
