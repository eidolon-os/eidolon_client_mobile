import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_channel_calibration_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_enrollment_recorder.dart';

/// The Host recorder's shape: nothing streams, the PCM arrives on stop.
class FakeRecorder implements VoiceEnrollmentRecorder {
  FakeRecorder({this.failStart = false});
  final bool failStart;
  final audio = StreamController<Uint8List>.broadcast();
  final pcm = Uint8List.fromList(List.filled(256000, 7));
  int starts = 0, stops = 0, cancels = 0;
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    if (failStart) throw StateError('无法连接主机录音，请检查网络');
    return audio.stream;
  }

  @override
  Future<Uint8List?> stop() async {
    stops++;
    return pcm;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async => audio.close();
}

Map<String, dynamic> _batch(String id, int samples) => {
      'batch_id': id,
      'channel': 'mobile',
      'samples': samples,
      'first_captured_at': 1793500000.0,
      'last_captured_at': 1793500600.0,
    };

class FakeHost {
  FakeHost({this.refuse = const {}});

  /// Upload attempts (1-based) the Host refuses as too short.
  final Set<int> refuse;
  final calls = <String>[];
  final uploads = <Map<String, dynamic>>[];
  var batches = [_batch('replay-1', 3), _batch('replay-2', 5)];
  int attempts = 0;

  Future<Map<String, dynamic>> call(
      {String method = 'GET',
      String suffix = '',
      Map<String, dynamic>? body}) async {
    calls.add('$method $suffix');
    if (suffix == '/readiness') {
      return {'state': 'ready', 'extraction_ready': true};
    }
    if (suffix == '/channel-calibration/samples') {
      if (refuse.contains(++attempts)) {
        throw const ManagementRequestException('有效语音太短，请连续说完一句话后重录',
            statusCode: 422);
      }
      uploads.add(body!);
      return {'sample_id': 's${uploads.length}'};
    }
    if (method == 'DELETE') {
      final id = Uri.decodeComponent(suffix.split('/').last);
      batches = batches.where((b) => b['batch_id'] != id).toList();
    }
    return {'batches': batches};
  }
}

Future<void> _open(WidgetTester tester, FakeHost host, FakeRecorder recorder,
    {int maxSegments = 700, List<bool>? screen}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: VoiceChannelCalibrationPage(
          call: host.call,
          recorderFactory: () => recorder,
          keepScreenOn: (on) async => screen?.add(on),
          maxSegments: maxSegments)));
  await tester.pumpAndSettle();
}

final _toggle = find.byKey(const Key('calibration-toggle'));

void main() {
  testWidgets('records back-to-back segments into one batch until stopped',
      (tester) async {
    final host = FakeHost();
    final recorder = FakeRecorder();
    await _open(tester, host, recorder);
    expect(find.textContaining('不录家人的声音'), findsOneWidget);
    expect(find.textContaining('不保存录音'), findsOneWidget);

    await tester.tap(_toggle);
    await tester.pump();
    expect(recorder.starts, 1);
    expect(find.text('停止'), findsOneWidget);
    // Nothing is uploaded before a segment has run its full length.
    await tester.pump(const Duration(seconds: 7));
    expect(host.uploads, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(host.uploads, hasLength(1));
    expect(recorder.starts, 2);
    await tester.pump(const Duration(seconds: 8));
    expect(host.uploads, hasLength(2));
    expect(find.textContaining('已上传 2 段 · 失败 0 段 · 已用时'), findsOneWidget);

    // Stop part-way through the third segment: that capture is cancelled.
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(recorder.starts, 3);
    expect(recorder.stops, 2);
    expect(recorder.cancels, greaterThanOrEqualTo(1));
    expect(host.uploads, hasLength(2));
    expect(find.text('开始校准'), findsOneWidget);
    expect(find.text('已停止。本批次已上传 2 段。'), findsOneWidget);

    final batch = host.uploads.first['batch_id'] as String;
    expect(batch, startsWith('replay-'));
    expect(host.uploads.map((u) => u['batch_id']), everyElement(batch));
    expect(
        host.uploads.first.keys, unorderedEquals(['batch_id', 'pcm_base64']));
    expect(host.uploads.first['pcm_base64'], base64Encode(recorder.pcm));
    // The readiness gate came first; the batch list was read again at the end.
    expect(host.calls.where((c) => c == 'GET /readiness'), hasLength(1));
    expect(host.calls.last, 'GET /channel-calibration');

    // Nothing keeps running after Stop.
    await tester.pump(const Duration(seconds: 30));
    expect(recorder.starts, 3);
    expect(host.uploads, hasLength(2));
  });

  testWidgets('a refused segment is counted and the loop goes on',
      (tester) async {
    final host = FakeHost(refuse: {1});
    final recorder = FakeRecorder();
    await _open(tester, host, recorder);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(host.uploads, isEmpty);
    expect(find.textContaining('已上传 0 段 · 失败 1 段'), findsOneWidget);
    expect(find.textContaining('最近一次失败：有效语音太短'), findsOneWidget);
    // A refusal does not pause the run: the next segment is already recording.
    expect(recorder.starts, 2);
    await tester.pump(const Duration(seconds: 8));
    expect(host.uploads, hasLength(1));
    expect(find.textContaining('已上传 1 段 · 失败 1 段'), findsOneWidget);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(find.text('开始校准'), findsOneWidget);
  });

  testWidgets('the run ends by itself at the segment budget', (tester) async {
    final host = FakeHost();
    final recorder = FakeRecorder();
    await _open(tester, host, recorder, maxSegments: 2);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    expect(host.uploads, hasLength(2));
    expect(recorder.starts, 2);
    expect(find.text('已录满 2 段，校准结束。'), findsOneWidget);
    expect(find.text('开始校准'), findsOneWidget);
  });

  testWidgets('a Host that cannot record stops the run instead of spinning',
      (tester) async {
    final host = FakeHost();
    final recorder = FakeRecorder(failStart: true);
    await _open(tester, host, recorder);
    await tester.tap(_toggle);
    await tester.pump();
    expect(recorder.starts, 1);
    // Failed connections are spaced out, not retried in a tight loop.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(recorder.starts, 1);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    await tester.pump();
    expect(recorder.starts, 20);
    expect(host.uploads, isEmpty);
    expect(find.textContaining('连续 20 段没有成功，已自动停止'), findsOneWidget);
    expect(find.text('开始校准'), findsOneWidget);
  });

  testWidgets('leaving the foreground stops the run', (tester) async {
    final host = FakeHost();
    final recorder = FakeRecorder();
    await _open(tester, host, recorder);
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(host.uploads, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.pump();
    await tester.pump();
    expect(find.text('应用离开了前台，校准已停止，回到应用后可重新开始。本批次已上传 1 段。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(host.uploads, hasLength(1));
  });

  testWidgets('batches are listed with counts and deleted one by one',
      (tester) async {
    final host = FakeHost();
    await _open(tester, host, FakeRecorder());
    expect(find.byKey(const ValueKey('calibration-batch-replay-1')),
        findsOneWidget);
    expect(find.textContaining('3 段'), findsOneWidget);
    expect(find.textContaining('5 段'), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('calibration-batch-replay-1')),
        matching: find.byTooltip('删除批次')));
    await tester.pumpAndSettle();
    expect(find.text('删除这批校准样本？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(
        host.calls, contains('DELETE /channel-calibration/batches/replay-1'));
    expect(
        find.byKey(const ValueKey('calibration-batch-replay-1')), findsNothing);
    expect(find.byKey(const ValueKey('calibration-batch-replay-2')),
        findsOneWidget);

    host.batches = [];
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('还没有校准样本'), findsOneWidget);
  });

  testWidgets('user management opens the calibration page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final host = FakeHost();
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async => {'persons': []},
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          suffix.isEmpty ? {'profiles': []} : host.call(suffix: suffix),
    )));
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('voice-channel-calibration'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('开始校准'), findsOneWidget);
    expect(host.calls, ['GET /channel-calibration']);
  });

  testWidgets('keeps the screen on for exactly the length of a run',
      (tester) async {
    final screen = <bool>[];
    await _open(tester, FakeHost(), FakeRecorder(), screen: screen);
    expect(screen, isEmpty);
    await tester.tap(_toggle);
    await tester.pump();
    expect(screen, [true]);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(_toggle);
    await tester.pump();
    await tester.pump();
    expect(screen, [true, false]);
  });
}
