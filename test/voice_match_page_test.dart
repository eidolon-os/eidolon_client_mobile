import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_match_page.dart';
import 'voice_enrollment_flow_test.dart' show FakeRecorder;

void main() {
  final policy = <String, dynamic>{
    'person_id': 'person',
    'profiles': [{'person_id':'person','profile_id':'p','revision':1,'enrollment_id':'e'}],
    'readiness': {
      'state': 'ready',
      'extraction_ready': true,
      'admission_ready': false
    }
  };
  final result = <String, dynamic>{
    'person_id': 'person',
    'person_revision': 1,
    'audio_ms': 4000,
    'extraction_ms': 80,
    'elapsed_ms': 120,
    'model_id': 'campplus',
    'weights_hash': 'a' * 64,
    'preprocessing_version': 'v1',
    'validation_state': 'unvalidated',
    'scores': [
      {
        'person_id': 'person', 'profile_id': 'p',
        'revision': 1,
        'status': 'scored',
        'similarity': 0.72
      }
    ]
  };

  testWidgets(
      'real match shows numeric result without enrollment or enabling policy',
      (tester) async {
    final recorder = FakeRecorder();
    final posts = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: VoiceMatchPage(
            personId: 'person', personName: '伙伴',
            recorderFactory: () => recorder,
            call: ({method = 'GET', suffix = '', body}) async {
              if (method == 'GET') return policy;
              posts.add(suffix);
              expect(body!.keys, ['pcm_base64']);
              return result;
            })));
    await tester.tap(find.text('开始试说'));
    await tester.pumpAndSettle();
    recorder.audio.add(Uint8List(128000));
    await tester.pump();
    await tester.tap(find.text('结束并测试'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(posts, ['/persons/person/match-test']);
    expect(find.text('伙伴: 0.720'), findsOneWidget);
    expect(find.textContaining('提取 80 ms'), findsOneWidget);
    expect(find.textContaining('分数不是识别准确率'), findsOneWidget);
  });

  for (final scenario in [
    'short',
    'background',
    'permission',
    'empty',
    'unready',
    'stream'
  ]) {
    testWidgets('$scenario does not upload audio', (tester) async {
      final recorder =
          FakeRecorder(permission: () async => scenario != 'permission');
      var posts = 0;
      await tester.pumpWidget(MaterialApp(
          home: VoiceMatchPage(
              personId: 'person', personName: '伙伴',
              recorderFactory: () => recorder,
              call: ({method = 'GET', suffix = '', body}) async {
                if (method == 'POST') {
                  posts++;
                  return result;
                }
                return {
                  ...policy,
                  if (scenario == 'empty') 'allowed_profile_ids': <String>[],
                  if (scenario == 'unready')
                    'readiness': {'state': 'loading', 'extraction_ready': false}
                };
              })));
      await tester.tap(find.text('开始试说'));
      await tester.pumpAndSettle();
      if (['short', 'background', 'stream'].contains(scenario)) {
        recorder.audio.add(Uint8List(32000));
        await tester.pump();
        if (scenario == 'short') await tester.tap(find.text('结束并测试'));
        if (scenario == 'stream') {
          recorder.audio.addError(StateError('device lost'));
        }
        if (scenario == 'background') {
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.paused);
        }
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      expect(posts, 0);
      if (scenario == 'background') {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
      'HTTP quality refusal is readable and retained after another test',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const reason = '有效语音太短，请连续说完一句话后重录';
    var posts = 0;
    final transport = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer controller');
      if (request.method == 'GET') {
        return http.Response(jsonEncode(policy), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      expect(request.url.path, endsWith('/voiceprints/persons/person/match-test'));
      posts++;
      return posts == 1
          ? http.Response(
              jsonEncode({
                'detail': {
                  'kind': 'invalid',
                  'reason': reason,
                  'retryable': false
                }
              }),
              422,
              headers: {'content-type': 'application/json; charset=utf-8'})
          : http.Response(jsonEncode(result), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
    });
    addTearDown(transport.close);
    final client = ManagementClient(httpClient: transport);
    final recorder = FakeRecorder();
    await tester.pumpWidget(MaterialApp(
        home: VoiceMatchPage(
      personId: 'person', personName: '伙伴',
      recorderFactory: () => recorder,
      call: ({method = 'GET', suffix = '', body}) => client.voiceprintRequest(
          Uri.parse('https://host/'),
          accessToken: 'controller',

          method: method,
          suffix: suffix,
          body: body),
    )));
    await tester.tap(find.text('仅电视'));
    for (var round = 0; round < 2; round++) {
      if (round == 1) await tester.tap(find.text('本人'));
      await tester.tap(find.text('开始试说'));
      await tester.pumpAndSettle();
      recorder.audio.add(Uint8List(128000));
      await tester.pump();
      await tester.tap(find.text('结束并测试'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text(reason), findsOneWidget,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join(' | '));
      expect(find.text('管理声纹被拒绝'), findsNothing);
      expect(find.text('未取得匹配分数'), findsOneWidget);
      expect(find.text('仅电视 · 4.0 秒录音'), findsOneWidget);
    }
    expect(posts, 2);
    expect(find.text('伙伴: 0.720'), findsOneWidget);
  });

  testWidgets('leaving during permission does not start capture',
      (tester) async {
    final permission = Completer<bool>();
    final recorder = FakeRecorder(permission: () => permission.future);
    await tester.pumpWidget(MaterialApp(
        home: VoiceMatchPage(
            personId: 'person', personName: '伙伴',
            recorderFactory: () => recorder,
            call: ({method = 'GET', suffix = '', body}) async => policy)));
    await tester.tap(find.text('开始试说'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    permission.complete(true);
    await tester.pumpAndSettle();
    expect(recorder.starts, 0);
  });
}
