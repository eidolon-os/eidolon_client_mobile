import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../host_setup/voice_recording_player.dart';

/// Preview owns playback only; Host synthesis continues safely after navigation.
class VoicePreviewPanel extends StatefulWidget {
  const VoicePreviewPanel(
      {super.key,
      required this.request,
      required this.audio,
      this.createPlayer});
  final Future<VoicePreviewStatus> Function(VoicePreviewRequest) request;
  final Future<Uint8List> Function(String) audio;
  final VoiceRecordingPlayer Function()? createPlayer;
  @override
  State<VoicePreviewPanel> createState() => _VoicePreviewPanelState();
}

class _VoicePreviewPanelState extends State<VoicePreviewPanel> {
  late final VoiceRecordingPlayer _player;
  StreamSubscription<void>? _completed;
  Uint8List? _sample;
  bool _busy = false, _playing = false;
  String? _notice;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _player = widget.createPlayer?.call() ?? LocalVoiceRecordingPlayer();
    _completed = _player.completed.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A pushed route leaves this widget mounted. Stop here as well as dispose,
    // so an in-flight preview cannot begin behind the editor or another page.
    if (ModalRoute.of(context)?.isCurrent == false && (_busy || _playing)) {
      unawaited(_stop());
    }
  }

  Future<void> _preview({bool regenerate = false}) async {
    if (_busy) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _player.stop();
      if (!mounted || epoch != _epoch) return;
      setState(() => _playing = false);
      if (_sample == null || regenerate) {
        final request = VoicePreviewRequest(
            regenerate: regenerate,
            requestId:
                'preview-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}');
        VoicePreviewStatus status;
        final deadline = DateTime.now().add(const Duration(seconds: 75));
        do {
          status = await widget.request(request);
          if (!mounted || epoch != _epoch) return;
          if (status.state != 'generating') break;
          setState(() => _notice = '正在生成试听…');
          await Future<void>.delayed(const Duration(milliseconds: 700));
          if (!mounted || epoch != _epoch) return;
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('preview');
          }
        } while (true);
        if (status.state != 'ready') throw StateError('preview failed');
        final audio = await widget.audio(status.key);
        if (!mounted || epoch != _epoch) return;
        _sample = audio;
      }
      await _player.play(_sample!);
      if (mounted && epoch == _epoch) {
        setState(() {
          _playing = true;
          _notice = null;
        });
      }
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _notice =
            _sample == null ? '暂时无法试听，请重试。' : '未能完成试听，已有声音已保留，可再次播放。');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    ++_epoch;
    await _player.stop();
    if (mounted) {
      setState(() {
        _busy = false;
        _playing = false;
        _notice = null;
      });
    }
  }

  @override
  void dispose() {
    ++_epoch;
    _sample = null;
    unawaited(_completed?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('试听当前声音'),
            const Text('使用主机当前配置的声音，只在手机播放，不会开始聊天。'),
            if (_notice != null) Text(_notice!),
            Wrap(spacing: 12, children: [
              FilledButton.tonal(
                  onPressed: _busy || _playing ? _stop : _preview,
                  child: Text(_busy
                      ? '取消试听'
                      : _playing
                          ? '停止播放'
                          : '试听')),
              TextButton(
                  onPressed: _busy || _playing
                      ? null
                      : () => _preview(regenerate: true),
                  child: const Text('重新生成')),
            ]),
          ])));
}
