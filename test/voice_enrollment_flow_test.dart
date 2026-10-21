import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voiceprint_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_enrollment_recorder.dart';

class FakeRecorder implements VoiceEnrollmentRecorder {
  FakeRecorder({this.permission});
  final Future<bool> Function()? permission;
  final audio = StreamController<Uint8List>.broadcast();
  int starts = 0, stops = 0, cancels = 0;
  @override
  Future<bool> hasPermission() async =>
      permission == null ? true : await permission!();
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async => audio.close();
}

void main() {
  for (final savedBeforeFailure in [false, true]) {
    testWidgets('four steps recover unknown save: saved=$savedBeforeFailure',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final recorder = FakeRecorder();
      var accepted = 0;
      var completionAttempts = 0;
      var saved = false;
      final profile = {
        'profile_id': 'p',
        'display_name': '我',
        'revision': 1,
        'enrollment_id': 'e',
        'recording_available': true,
      };
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(
          home: VoiceEnrollmentPage(
        recorderFactory: () => recorder,
        call: ({method = 'GET', suffix = '', body}) async {
          if (suffix == '/readiness') {
            return {
              'state': 'ready',
              'extraction_ready': true,
              'admission_ready': false
            };
          }
          calls.add('$method $suffix');
          if (suffix.endsWith('/complete') && completionAttempts++ == 0) {
            saved = savedBeforeFailure;
            throw Exception('network interruption');
          }
          if (suffix.endsWith('/complete')) {
            return {
              'profile_id': 'p',
              'display_name': '我',
              'revision': 1,
              'enrollment_id': 'e',
              'recording_available': true
            };
          }
          if (suffix.isEmpty) {
            return {
              'companion_id': 'c',
              'profiles': [profile],
              'allowed_profile_ids': []
            };
          }
          if (method == 'PUT') accepted++;
          return {
            'enrollment_id': 'e',
            'profile_id': 'p',
            'state': saved ? 'ready' : 'collecting',
            'accepted_samples': accepted,
            'expires_at': 9999999999.0
          };
        },
      )));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '我');
      expect(find.textContaining('共 4 步'), findsOneWidget);
      for (var step = 0; step < 4; step++) {
        await tester.tap(find.byKey(const Key('voice-enrollment-record')));
        await tester.pumpAndSettle();
        recorder.audio.add(Uint8List(128000));
        await tester.pump();
        await tester.tap(find.byKey(const Key('voice-enrollment-record')));
        // Stream cancellation may finish in Dart's real async zone.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        if (step < 3) {
          expect(
              find.textContaining('第 ${step + 1} 段录音质量检查通过'), findsOneWidget);
        }
      }
      expect(find.text('声纹已保存'), findsNothing);
      expect(find.text('重试提交'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-enrollment-record')));
      await tester.pumpAndSettle();
      expect(find.text('声纹已保存'), findsOneWidget);
      expect(find.text('回放录入声音'), findsOneWidget);
      expect(calls.where((v) => v.contains('/bindings/')), isEmpty);
      expect(find.byKey(const Key('voice-enrollment-record')), findsNothing);
      expect(calls.where((v) => v.endsWith('/complete')).length,
          savedBeforeFailure ? 1 : 2);
      expect(calls, contains('GET /enrollments/e'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls.where((v) => v.startsWith('DELETE')), isEmpty);
    });
  }
  testWidgets('leaving an unfinished enrollment requires an explicit discard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recorder = FakeRecorder();
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  child: const Text('打开录入'),
                  onPressed: () =>
                      Navigator.of(context).push<void>(MaterialPageRoute(
                          builder: (_) => VoiceEnrollmentPage(
                                recorderFactory: () => recorder,
                                call: (
                                    {method = 'GET', suffix = '', body}) async {
                                  if (suffix == '/readiness') {
                                    return {
                                      'state': 'ready',
                                      'extraction_ready': true,
                                      'admission_ready': false
                                    };
                                  }
                                  calls.add(method);
                                  return {
                                    'enrollment_id': 'e',
                                    'profile_id': 'p',
                                    'state': 'collecting',
                                    'accepted_samples': method == 'PUT' ? 1 : 0,
                                    'expires_at': 9999999999.0
                                  };
                                },
                              ))),
                ))));
    await tester.tap(find.text('打开录入'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我');
    await tester.tap(find.byKey(const Key('voice-enrollment-record')));
    await tester.pumpAndSettle();
    recorder.audio.add(Uint8List(128000));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-enrollment-record')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('声纹尚未保存'), findsOneWidget);
    expect(calls, ['POST', 'PUT']);
    await tester.tap(find.text('继续录入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 1 段录音质量检查通过'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃并返回'));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE');
    expect(find.text('打开录入'), findsOneWidget);
  });
  testWidgets(
      'first permission sheet does not silently cancel the recording start',
      (tester) async {
    final recorder = FakeRecorder(permission: () async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return true;
    });
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: VoiceEnrollmentPage(
      recorderFactory: () => recorder,
      call: ({method = 'GET', suffix = '', body}) async =>
          suffix == '/readiness'
              ? {
                  'state': 'ready',
                  'extraction_ready': true,
                  'admission_ready': false
                }
              : {
                  'enrollment_id': 'e',
                  'profile_id': 'p',
                  'state': 'collecting',
                  'accepted_samples': 0,
                  'expires_at': 9999999999.0
                },
    )));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我');
    await tester.tap(find.byKey(const Key('voice-enrollment-record')));
    await tester.pumpAndSettle();
    expect(find.text('结束并检查'), findsOneWidget);
    expect(find.textContaining('正在录音'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  testWidgets(
      'unready service never opens microphone; readiness can be retried',
      (tester) async {
    final recorder = FakeRecorder();
    var ready = false;
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: VoiceEnrollmentPage(
      recorderFactory: () => recorder,
      call: ({method = 'GET', suffix = '', body}) async {
        if (suffix == '/readiness') {
          return {
            'state': ready ? 'ready' : 'loading',
            'extraction_ready': ready,
            'admission_ready': false
          };
        }
        return {
          'enrollment_id': 'e',
          'profile_id': 'p',
          'state': 'collecting',
          'accepted_samples': 0,
          'expires_at': 9999999999.0
        };
      },
    )));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我');
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('voice-enrollment-record')))
            .onPressed,
        isNull);
    expect(recorder.starts, 0);
    ready = true;
    await tester.tap(find.text('重试准备'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-enrollment-record')));
    await tester.pumpAndSettle();
    expect(recorder.starts, 1);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(recorder.cancels, 1);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('正在录音'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing audio frames stop at the recording deadline',
      (tester) async {
    final recorder = FakeRecorder();
    final writes = <String>[];
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: VoiceEnrollmentPage(
      recorderFactory: () => recorder,
      call: ({method = 'GET', suffix = '', body}) async {
        if (suffix == '/readiness') {
          return {
            'state': 'ready',
            'extraction_ready': true,
            'admission_ready': false
          };
        }
        writes.add(method);
        return {
          'enrollment_id': 'e',
          'profile_id': 'p',
          'state': 'collecting',
          'accepted_samples': 0,
          'expires_at': 9999999999.0
        };
      },
    )));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我');
    await tester.tap(find.byKey(const Key('voice-enrollment-record')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 9));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(recorder.stops, 1);
    expect(find.text('请说完整句子，至少录制 3 秒'), findsOneWidget);
    expect(writes, ['POST']);
    await tester.pumpWidget(const SizedBox());
  });
}
