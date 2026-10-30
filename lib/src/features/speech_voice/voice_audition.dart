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
    // A player reports a file it cannot open here, not from play(): without
    // this the error would go unhandled and the ▶ would stay a ■.
    _completed = _player.completed
        .listen((_) => _finish(), onError: (Object _) => _finish(failed: true));
  }

  final Future<Uint8List> Function(String key) _load;
  final VoiceRecordingPlayer _player;
  late final StreamSubscription<void> _completed;
  final _failures = StreamController<String>.broadcast();
  String? _loading, _playing;
  int _turn = 0;
  bool _disposed = false;

  String? get loading => _loading;
  String? get playing => _playing;

  /// The voice that could not be heard, whether the Host could not make the
  /// sample or the phone could not play it.
  Stream<String> get failures => _failures.stream;

  /// Play [key], or stop it if it is what is playing.
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
        _loading = null;
        _playing = key;
        _finish(failed: true);
      }
    }
  }

  void _finish({bool failed = false}) {
    if (_disposed) return;
    final key = _playing;
    _playing = null;
    notifyListeners();
    if (failed && key != null) _failures.add(key);
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
    unawaited(_failures.close());
    unawaited(_player.dispose());
    super.dispose();
  }
}

/// ▶ for one voice: a spinner while the Host makes the sample, ■ while it
/// plays, and a word when it could not be heard.
class AuditionButton extends StatefulWidget {
  const AuditionButton(
      {super.key, required this.audition, required this.voiceKey, this.wav});

  final VoiceAudition audition;
  final String voiceKey;

  /// Bytes already in hand, such as the window of a recording being checked.
  final Uint8List? wav;

  @override
  State<AuditionButton> createState() => _AuditionButtonState();
}

class _AuditionButtonState extends State<AuditionButton> {
  StreamSubscription<String>? _failures;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(AuditionButton old) {
    super.didUpdateWidget(old);
    if (old.audition != widget.audition) _listen();
  }

  void _listen() {
    unawaited(_failures?.cancel());
    _failures = widget.audition.failures.listen((key) {
      if (key != widget.voiceKey || !mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时听不了这个声音，请稍后再试')));
    });
  }

  @override
  void dispose() {
    unawaited(_failures?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.audition,
        builder: (context, _) {
          final audition = widget.audition;
          if (audition.loading == widget.voiceKey) {
            return const SizedBox.square(
                dimension: 48,
                child: Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(strokeWidth: 2)));
          }
          final playing = audition.playing == widget.voiceKey;
          return IconButton(
            key: Key('audition-${widget.voiceKey}'),
            tooltip: playing ? '停止' : '试听',
            icon: Icon(playing
                ? Icons.stop_circle_outlined
                : Icons.play_circle_outline),
            onPressed: () => audition.toggle(widget.voiceKey, wav: widget.wav),
          );
        },
      );
}
