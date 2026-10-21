import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import 'voice_recording_player.dart';

class VoiceRecordingDialog extends StatefulWidget {
  const VoiceRecordingDialog({
    super.key,
    required this.name,
    required this.load,
    this.playerFactory,
  });
  final String name;
  final Future<Map<String, dynamic>> Function() load;
  final VoiceRecordingPlayer Function()? playerFactory;

  @override
  State<VoiceRecordingDialog> createState() => _VoiceRecordingDialogState();
}

class _VoiceRecordingDialogState extends State<VoiceRecordingDialog>
    with WidgetsBindingObserver {
  VoiceRecordingPlayer? _player;
  StreamSubscription<void>? _completion;
  Uint8List? _pcm;
  bool _loading = true, _playing = false, _busy = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = VoiceAudioRequest.fromJson(await widget.load());
      final pcm = base64Decode(response.pcmBase64);
      voiceRecordingWav(
          pcm); // Validate before handing data to a platform decoder.
      if (mounted) setState(() => _pcm = pcm);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取录音，请检查主机连接后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_playing) {
        await _player?.stop();
        if (mounted) setState(() => _playing = false);
      } else {
        if (_player == null) {
          _player = widget.playerFactory?.call() ?? LocalVoiceRecordingPlayer();
          _completion = _player!.completed.listen((_) {
            if (mounted) setState(() => _playing = false);
          });
        }
        await _player!.play(_pcm!);
        if (!mounted || generation != _generation) {
          await _player?.stop();
          return;
        }
        setState(() => _playing = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = '无法播放录音，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _generation++;
      unawaited(_player?.stop().catchError((_) {}));
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    unawaited(_completion?.cancel());
    final player = _player;
    if (player != null) {
      unawaited(player
          .stop()
          .catchError((_) {})
          .whenComplete(player.dispose)
          .catchError((_) {}));
    }
    _pcm = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.name}的录入声音'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('这是最近一次录入成功时的试说录音，可用于辨认声音。'),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (!_loading && _pcm != null)
            FilledButton.icon(
              onPressed: _busy ? null : _toggle,
              icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
              label: Text(_playing ? '停止播放' : '播放录音'),
            ),
          if (!_loading && _pcm == null)
            TextButton(onPressed: _load, child: const Text('重试')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭'))
        ],
      );
}
