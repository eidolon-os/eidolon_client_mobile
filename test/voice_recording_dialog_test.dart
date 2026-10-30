import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_recording_dialog.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/voice_recording_player.dart';

class FakePlayer implements VoiceRecordingPlayer {
  final events = StreamController<void>.broadcast();
  int plays = 0, stops = 0, disposals = 0;
  Uint8List? seen;
  @override
  Stream<void> get completed => events.stream;
  @override
  Future<void> play(Uint8List pcm) async {
    plays++;
    seen = pcm;
  }

  @override
  Future<void> playWav(Uint8List wav) async {
    plays++;
    seen = wav;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await events.close();
  }
}

void main() {
  test('WAV wraps original PCM with matching format and bounds', () {
    final pcm = Uint8List.fromList(List.filled(64000, 7));
    final wav = voiceRecordingWav(pcm);
    final header = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.take(4)), 'RIFF');
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
    expect(() => voiceRecordingWav(Uint8List(1)), throwsFormatException);
  });
  testWidgets('playback uses saved audio and stops when leaving',
      (tester) async {
    final player = FakePlayer();
    await tester.pumpWidget(MaterialApp(
        home: VoiceRecordingDialog(
      name: '妈妈',
      playerFactory: () => player,
      load: () async => {'pcm_base64': base64Encode(Uint8List(64000))},
    )));
    await tester.pumpAndSettle();
    expect(player.plays, 0);
    await tester.tap(find.text('播放录音'));
    await tester.pumpAndSettle();
    expect(player.seen!.length, 64000);
    expect(find.text('停止播放'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(player.stops, 1);
    expect(player.disposals, 1);
  });
  testWidgets('closing during load never starts background playback',
      (tester) async {
    final load = Completer<Map<String, dynamic>>();
    final player = FakePlayer();
    await tester.pumpWidget(MaterialApp(
        home: VoiceRecordingDialog(
      name: '甲',
      playerFactory: () => player,
      load: () => load.future,
    )));
    await tester.pumpWidget(const SizedBox());
    load.complete({'pcm_base64': base64Encode(Uint8List(64000))});
    await tester.pumpAndSettle();
    expect(player.plays, 0);
    expect(tester.takeException(), isNull);
  });
}
