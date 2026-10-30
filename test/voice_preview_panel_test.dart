import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/voice_preview/voice_preview_panel.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_recording_player.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';

class Player implements VoiceRecordingPlayer {
  int plays = 0, stops = 0;
  bool disposed = false;
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> play(Uint8List pcm) async {
    plays++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  testWidgets(
      'lazy preview replays cache and preserves it after failed regeneration',
      (tester) async {
    final player = Player();
    final requests = <VoicePreviewRequest>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VoicePreviewPanel(
                createPlayer: () => player,
                request: (request) async {
                  requests.add(request);
                  return VoicePreviewStatus(
                      key: 'a' * 64,
                      state: request.regenerate == true ? 'failed' : 'ready',
                      audioAvailable: true,
                      voice: 'configured');
                },
                audio: (_) async => Uint8List(48000)))));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.tap(find.text('试听'));
    await tester.pumpAndSettle();
    expect(player.plays, 1);
    await tester.tap(find.text('停止播放'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已有声音已保留'), findsOneWidget);
    await tester.tap(find.text('试听'));
    await tester.pumpAndSettle();
    expect(player.plays, 2);
    expect(requests.length, 2);
    await tester.pumpWidget(const SizedBox());
    expect(player.disposed, isTrue);
  });

  testWidgets('leaving while generation is pending prevents late playback',
      (tester) async {
    final player = Player();
    final pending = Completer<VoicePreviewStatus>();
    var downloads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VoicePreviewPanel(
                createPlayer: () => player,
                request: (_) => pending.future,
                audio: (_) async {
                  downloads++;
                  return Uint8List(48000);
                }))));
    await tester.tap(find.text('试听'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(VoicePreviewStatus(
        key: 'a' * 64,
        state: 'ready',
        audioAvailable: true,
        voice: 'configured'));
    await tester.pumpAndSettle();
    expect(player.plays, 0);
    expect(downloads, 0);
    expect(player.disposed, isTrue);
  });
  testWidgets(
      'pushing another route suppresses late playback while panel stays mounted',
      (tester) async {
    final player = Player();
    final pending = Completer<VoicePreviewStatus>();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
            body: VoicePreviewPanel(
                createPlayer: () => player,
                request: (_) => pending.future,
                audio: (_) async => Uint8List(48000)))));
    await tester.tap(find.text('试听'));
    await tester.pump();
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('团队编辑')))));
    await tester.pumpAndSettle();
    pending.complete(VoicePreviewStatus(
        key: 'a' * 64,
        state: 'ready',
        audioAvailable: true,
        voice: 'configured'));
    await tester.pumpAndSettle();
    expect(player.plays, 0);
    expect(player.disposed, isFalse);
  });
}
