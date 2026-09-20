import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/management/companion_portrait.dart';
import 'package:eidolon_client_mobile/src/management/companion_preset_portrait.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

void main() {
  Widget page(
          {String id = 'one',
          String name = '改过的名字',
          String? artwork = 'five-elements/1/water',
          Uint8List? face,
          CompanionFaceLoader? load}) =>
      MaterialApp(
          home: Scaffold(
              body: CompanionPortrait(
                  companionId: id,
                  name: name,
                  artworkId: artwork,
                  face: face,
                  loadFace: load)));
  testWidgets(
      'persisted artwork survives a rename and unknown versions do not guess',
      (tester) async {
    await tester.pumpWidget(page());
    expect(
        tester
            .widget<CompanionPresetPortrait>(
                find.byType(CompanionPresetPortrait))
            .presetId,
        'water');
    await tester.pumpWidget(page(name: '澄澄', artwork: 'five-elements/9/water'));
    expect(
        tester
            .widget<CompanionPresetPortrait>(
                find.byType(CompanionPresetPortrait))
            .presetId,
        '');
  });
  testWidgets('uploaded face takes precedence over official art',
      (tester) async {
    // Selection policy only; decoding is separately covered by companion_face_test.
    await tester.pumpWidget(page(face: Uint8List(0)));
    expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
    await tester.pumpAndSettle();
  });
  testWidgets('late face reply for A cannot replace B artwork', (tester) async {
    final a = Completer<CompanionFacePicture>();
    Future<CompanionFacePicture> loader({required String companionId}) =>
        companionId == 'one'
            ? a.future
            : Future.value(const CompanionFacePicture.none());
    await tester.pumpWidget(page(load: loader));
    await tester.pumpWidget(
        page(id: 'two', artwork: 'five-elements/1/fire', load: loader));
    await tester.pumpAndSettle();
    a.complete(CompanionFacePicture(bytes: Uint8List(0)));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CompanionPresetPortrait>(
                find.byType(CompanionPresetPortrait))
            .presetId,
        'fire');
  });
}
