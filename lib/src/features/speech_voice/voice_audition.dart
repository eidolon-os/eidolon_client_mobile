import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../host_setup/voice_recording_player.dart';

/// One voice heard at a time on a page: which one is being fetched, which one
/// is playing, and the ▶ beside each.
///
/// Fetching waits on the Host's speech service, so a second tap while the first
/// is still on its way replaces it rather than queueing behind it.
class VoiceAudition extends ChangeNotifier {
  VoiceAudition(
      {required Future<Uint8List> Function(String key) load,
      VoiceRecordingPlayer? player})
      : _load = load,
        _player = player ?? LocalVoiceRecordingPlayer() {
    _completed = _player.completed.listen((_) {
      _playing = null;
      notifyListeners();
    });
  }

  final Future<Uint8List> Function(String key) _load;
  final VoiceRecordingPlayer _player;
  late final StreamSubscription<void> _completed;
  String? _loading, _playing;
  int _turn = 0;
  bool _disposed = false;

  String? get loading => _loading;
  String? get playing => _playing;

  /// Play [key], or stop it if it is what is playing. Throws when the Host
  /// could not give the sample; the caller decides how to say so.
  Future<void> toggle(String key, {Uint8List? wav}) async {
    if (_disposed) return;
    final turn = ++_turn;
    final wasPlaying = _playing == key;
    await _player.stop();
    _playing = null;
    _loading = wasPlaying ? null : key;
    notifyListeners();
    if (wasPlaying) return;
    try {
      final audio = wav ?? await _load(key);
      if (_disposed || turn != _turn) return;
      _loading = null;
      _playing = key;
      notifyListeners();
      await _player.playWav(audio);
    } catch (_) {
      if (!_disposed && turn == _turn) {
        _loading = _playing = null;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    _turn++;
    _loading = _playing = null;
    if (!_disposed) notifyListeners();
    await _player.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    _turn++;
    unawaited(_completed.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }
}

/// ▶ for one voice: a spinner while the Host makes the sample, ■ while it plays.
class AuditionButton extends StatelessWidget {
  const AuditionButton(
      {super.key, required this.audition, required this.voiceKey, this.wav});

  final VoiceAudition audition;
  final String voiceKey;

  /// Bytes already in hand, such as the window of a recording being checked.
  final Uint8List? wav;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: audition,
        builder: (context, _) {
          if (audition.loading == voiceKey) {
            return const SizedBox.square(
                dimension: 48,
                child: Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(strokeWidth: 2)));
          }
          final playing = audition.playing == voiceKey;
          return IconButton(
            key: Key('audition-$voiceKey'),
            tooltip: playing ? '停止' : '试听',
            icon: Icon(playing
                ? Icons.stop_circle_outlined
                : Icons.play_circle_outline),
            onPressed: () =>
                audition.toggle(voiceKey, wav: wav).catchError((Object _) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('暂时听不了这个声音，请稍后再试')));
              }
            }),
          );
        },
      );
}
