import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/face_picker.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/person_face_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voiceprint_call.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

// Valid one-pixel PNG; no real biometric fixture is stored in the test suite.
const photo =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=';

class Picker implements FacePicker {
  @override
  Future<Uint8List?> pickFace() async => base64Decode(photo);
}

/// A Host with one saved photo at revision 3. [onRecognition] answers the
/// recognition writes; throwing from it is the Host refusing.
class FakeHost {
  FakeHost({this.enabled = false, this.hasImage = true, this.onRecognition});
  bool enabled;
  bool hasImage;
  final void Function(String method)? onRecognition;
  final writes = <(String, String, Map<String, dynamic>?)>[];

  Map<String, dynamic> get state => {
        'person_id': 'p',
        'revision': hasImage ? 3 : 0,
        'has_image': hasImage,
        'recognition_state': enabled ? 'enabled' : 'not_configured',
        'recognition_consent_version':
            enabled ? faceRecognitionConsentVersion : null,
        'recognition_enabled_at': enabled ? '2026-11-14T08:00:00Z' : null,
      };

  Future<Map<String, dynamic>> call(
      {String method = 'GET',
      String suffix = '',
      Map<String, dynamic>? body}) async {
    if (method == 'GET') {
      return suffix == '/image'
          ? {'revision': 3, 'image_base64': photo}
          : state;
    }
    writes.add((method, suffix, body));
    expect(suffix, '/recognition');
    onRecognition?.call(method);
    enabled = method == 'PUT';
    return state;
  }
}

Future<void> pumpPage(WidgetTester tester, VoiceprintCall call,
    {bool active = true}) async {
  // Tall enough that the lazily built list holds the recognition actions.
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: PersonFacePage(
          name: '甲', active: active, picker: Picker(), call: call)));
  await tester.pumpAndSettle();
}

Future<void> tapOnPage(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

Future<void> consentAndConfirm(WidgetTester tester) async {
  await tapOnPage(tester, '启用人脸识别');
  await tester.tap(find.byKey(const Key('face-recognition-agree')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('同意并启用'));
  await tester.pumpAndSettle();
}

ManagementRequestException refused(int status, String kind,
        {String? code, String? reason}) =>
    ManagementRequestException('管理用户被拒绝',
        statusCode: status,
        refusal: Refusal(kind: kind, code: code, reason: reason));

void main() {
  testWidgets('consent must be ticked before recognition can be enabled',
      (tester) async {
    final host = FakeHost();
    await pumpPage(tester, host.call);
    expect(find.text('照片已保存 · 人脸识别未启用'), findsOneWidget);
    await tapOnPage(tester, '启用人脸识别');
    expect(find.text(faceRecognitionConsentStatement), findsOneWidget);
    final confirm = find.byKey(const Key('face-recognition-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('face-recognition-agree')))
            .value,
        isFalse);
    await tester.tap(find.text('同意并启用'));
    await tester.pumpAndSettle();
    expect(host.writes, isEmpty);
    await tester.tap(find.text('我已征得照片中本人的同意'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(host.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming sends the consent exactly as shown', (tester) async {
    final host = FakeHost();
    await pumpPage(tester, host.call);
    await consentAndConfirm(tester);
    expect(host.writes, hasLength(1));
    final (method, suffix, body) = host.writes.single;
    expect(method, 'PUT');
    expect(suffix, '/recognition');
    expect(body, {
      'expected_revision': 3,
      'consent': {
        'consent_version': 'face-recognition-consent/2026-11-14',
        'statement': '我确认照片中的人已同意：Eidolon 从这张照片提取人脸特征并保存在本机 Host 上，'
            '用于在有摄像头的设备上认出并称呼 TA。识别结果只用于称呼，不是身份验证，'
            '也不会开放个人记忆。删除照片或关闭人脸识别会同时删除人脸特征。',
        'attested': true
      }
    });
    expect(find.text('人脸识别已启用'), findsOneWidget);
    expect(find.text('关闭人脸识别'), findsOneWidget);
    expect(find.text('启用人脸识别'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabled recognition is turned off only after confirmation',
      (tester) async {
    final host = FakeHost(enabled: true);
    await pumpPage(tester, host.call);
    expect(find.text('人脸识别已启用'), findsOneWidget);
    expect(find.text('启用人脸识别'), findsNothing);
    await tapOnPage(tester, '关闭人脸识别');
    expect(find.textContaining('照片保留'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(host.writes, isEmpty);
    await tapOnPage(tester, '关闭人脸识别');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(host.writes.single, ('DELETE', '/recognition', null));
    expect(find.text('照片已保存 · 人脸识别未启用'), findsOneWidget);
    expect(find.text('启用人脸识别'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  final refusals = <String, (ManagementRequestException, String)>{
    'no face': (
      refused(422, 'invalid', code: 'face_photo_rejected', reason: 'no_face'),
      '照片里没有检测到人脸'
    ),
    'multiple faces': (
      refused(422, 'invalid',
          code: 'face_photo_rejected', reason: 'multiple_faces'),
      '照片里有多张人脸，请换一张只有本人的照片'
    ),
    'face too small, reason inside a sentence': (
      refused(422, 'invalid',
          code: 'face_photo_rejected',
          reason: 'photo rejected: face_too_small'),
      '人脸太小，请换一张更近的正面照片'
    ),
    'low confidence, reason as the code': (
      refused(422, 'invalid', code: 'low_confidence'),
      '人脸不够清晰，请换一张照片'
    ),
    'unreadable reason': (
      refused(422, 'invalid', code: 'face_photo_rejected'),
      '照片不适合用于识别'
    ),
    'service not running': (
      refused(503, 'not_running', code: 'face_recognition_unavailable'),
      'Host 的人脸识别服务未运行，暂时无法启用'
    ),
    'photo changed': (refused(409, 'conflict'), '操作未确认，请刷新后重试'),
  };
  for (final entry in refusals.entries) {
    testWidgets('refused enable is explained: ${entry.key}', (tester) async {
      final host = FakeHost(onRecognition: (_) => throw entry.value.$1);
      await pumpPage(tester, host.call);
      await consentAndConfirm(tester);
      expect(host.writes, hasLength(1));
      expect(find.text(entry.value.$2), findsOneWidget);
      expect(find.text('照片已保存 · 人脸识别未启用'), findsOneWidget);
      expect(find.text('启用人脸识别'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('deactivated person cannot enable but can turn recognition off',
      (tester) async {
    final off = FakeHost();
    await pumpPage(tester, off.call, active: false);
    expect(find.text('照片已保存 · 人脸识别未启用'), findsOneWidget);
    expect(find.text('启用人脸识别'), findsNothing);

    final on = FakeHost(enabled: true);
    await tester.pumpWidget(const SizedBox());
    await pumpPage(tester, on.call, active: false);
    await tapOnPage(tester, '关闭人脸识别');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(on.writes.single, ('DELETE', '/recognition', null));
    expect(find.text('启用人脸识别'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no photo means no enable action, with a hint', (tester) async {
    final host = FakeHost(hasImage: false);
    await pumpPage(tester, host.call);
    expect(find.text('启用人脸识别'), findsNothing);
    expect(find.text('请先添加照片，再启用人脸识别。'), findsOneWidget);
    expect(find.textContaining('可拍照'), findsOneWidget);
    expect(find.textContaining('当前尚未启用人脸识别'), findsNothing);
  });
}
