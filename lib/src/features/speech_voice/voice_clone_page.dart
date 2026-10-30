import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../host_setup/voice_recording_player.dart';
import 'speech_voice_repository.dart';
import 'speech_voice_wording.dart';
import 'voice_audition.dart';
import 'voice_design_page.dart' show mintOperationId;
import 'voice_reference_sources.dart';

/// Making a voice from a recording (§17.9 C): who is speaking and their
/// consent, a recording made here or a file chosen, the Host's check of it,
/// then a name — and the provider's review, which can be waited for or not.
///
/// Pops with the submitted voice, or null when nothing usable was made.
class VoiceClonePage extends StatefulWidget {
  const VoiceClonePage({
    super.key,
    required this.voices,
    required this.limits,
    this.processor,
    this.playerFactory,
    this.recorderFactory,
    this.filePicker,
  });

  final SpeechVoices voices;
  final VoiceLimitsView limits;

  /// Who the recording is sent to, named in the disclosure.
  final String? processor;
  final VoiceRecordingPlayer Function()? playerFactory;
  final ReferenceRecorder Function()? recorderFactory;
  final AudioFilePicker? filePicker;

  @override
  State<VoiceClonePage> createState() => _VoiceClonePageState();
}

enum _Step { consent, source, recording, checked, submitted }

/// Which version of the words below the Owner agreed to.
const consentVersion = 'voice-clone-consent/2026-10-30';

const _passage = '今天天气不错，我泡了一壶茶，翻了几页一直想读的书。'
    '窗外偶尔有鸟叫，楼下的孩子在笑。这样安静的下午，让人觉得日子慢下来也挺好。';

class _VoiceClonePageState extends State<VoiceClonePage>
    with WidgetsBindingObserver {
  late final VoiceAudition _audition = VoiceAudition(
      load: widget.voices.preview, player: widget.playerFactory?.call());
  final _label = TextEditingController();
  final _name = TextEditingController();
  _Step _step = _Step.consent;
  bool _self = true, _agreed = false, _reEnroll = true;

  /// True for a recording made here, which carries the consent sentence.
  bool _spoken = true;
  ReferenceRecorder? _recorder;
  StreamSubscription<Uint8List>? _capture;
  final _pcm = BytesBuilder(copy: false);
  Timer? _tick;
  double _level = 0;

  Uint8List? _file;
  ReferenceCheckView? _check;
  int? _windowStart;
  String? _operationId;
  OwnerVoiceView? _voice;
  Timer? _review;
  bool _busy = false;
  String? _failure;

  int get _minMs => widget.limits.recordingMinMs ?? 10000;
  int get _maxMs => widget.limits.recordingMaxMs ?? 25000;
  int get _maxBytes => widget.limits.uploadMaxBytes ?? 10 * 1024 * 1024;

  String get _who => _label.text.trim();
  String get _statement => '我是$_who，我同意用我的声音为 Eidolon 生成一个声音。';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A recording never continues behind the person's back.
    if (state != AppLifecycleState.resumed && _step == _Step.recording) {
      unawaited(_abandonRecording('录音在离开 App 时停止了，请重新录'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _review?.cancel();
    unawaited(_capture?.cancel());
    unawaited(_recorder?.dispose());
    _audition.dispose();
    _label.dispose();
    _name.dispose();
    super.dispose();
  }

  void _fail(Object error) {
    if (mounted) setState(() => _failure = voiceFailure(error));
  }

  // --------------------------------------------------------------- recording

  Future<void> _record() async {
    setState(() {
      _failure = null;
      _busy = true;
    });
    try {
      final recorder = _recorder ??=
          widget.recorderFactory?.call() ?? MicrophoneReferenceRecorder();
      if (!await recorder.hasPermission()) {
        throw StateError('请在系统设置里允许使用麦克风');
      }
      final stream = await recorder.start();
      if (!mounted) return;
      _pcm.clear();
      _capture = stream.listen((chunk) {
        _pcm.add(chunk);
        _level = _loudness(chunk);
      }, onError: (Object _) => _abandonRecording('录音中断了，请重新录'));
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        if (_recordedMs >= _maxMs) {
          unawaited(_finishRecording());
        } else {
          setState(() {});
        }
      });
      setState(() {
        _spoken = true;
        _step = _Step.recording;
      });
    } catch (error) {
      if (mounted) {
        setState(() =>
            _failure = error is StateError ? error.message : '没能开始录音，请检查麦克风');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// How long the recording is: what was captured, not how long the screen
  /// has been open.
  int get _recordedMs => _pcm.length * 1000 ~/ (referenceSampleRate * 2);

  Future<void> _stopCapture() async {
    _tick?.cancel();
    // Nothing more is delivered once cancel is called; waiting for it to
    // finish tearing down would only delay the check.
    unawaited(_capture?.cancel());
    _capture = null;
    await _recorder?.stop();
  }

  Future<void> _abandonRecording(String why) async {
    await _stopCapture();
    _pcm.clear();
    if (mounted) {
      setState(() {
        _step = _Step.source;
        _failure = why;
      });
    }
  }

  Future<void> _finishRecording() async {
    if (_step != _Step.recording || _busy) return;
    setState(() => _busy = true);
    await _stopCapture();
    final wav = pcm16Wav(_pcm.takeBytes(), sampleRate: referenceSampleRate);
    await _measure(wav);
  }

  /// 0–1, from the loudest sample in a chunk: enough to show the person their
  /// voice is reaching the phone.
  static double _loudness(Uint8List chunk) {
    final samples = ByteData.sublistView(chunk);
    var peak = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      peak = max(peak, samples.getInt16(i, Endian.little).abs());
    }
    return min(1, peak / 32768 * 1.5);
  }

  // -------------------------------------------------------------------- file

  Future<void> _chooseFile() async {
    setState(() => _failure = null);
    final picked = await (widget.filePicker ?? const SystemAudioFilePicker())
        .pick()
        .catchError((Object _) => null);
    if (picked == null || !mounted) return;
    if (picked.size > _maxBytes) {
      setState(() => _failure = referenceProblem('too_large'));
      return;
    }
    setState(() {
      _busy = true;
      _spoken = false;
    });
    try {
      final file = _file = await picked.read();
      await _measure(file);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = referenceProblem('unreadable');
        });
      }
    }
  }

  // ------------------------------------------------------------------- check

  Future<void> _measure(Uint8List audio, {int? startMs}) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    await _audition.stop();
    try {
      final check = await widget.voices.check(audio, startMs: startMs);
      if (!mounted) return;
      setState(() {
        _check = check;
        _windowStart = check.windowStartMs;
        _operationId = null;
        _step = _Step.checked;
        if (_name.text.isEmpty) {
          _name.text = _self ? '我的声音' : '$_who的声音';
        }
      });
    } catch (error) {
      _fail(error);
      if (mounted && _step == _Step.recording) {
        setState(() => _step = _Step.source);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ submit

  Future<void> _submit() async {
    final check = _check;
    final audio = check?.audioBase64;
    final name = _name.text.trim();
    if (check == null || audio == null || name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final voice = await widget.voices.clone(VoiceCloneBody(
        operationId: _operationId ??= mintOperationId('clone'),
        name: name,
        audioBase64: audio,
        consent: VoiceConsentBody(
          method: _spoken ? 'spoken' : 'attested',
          subject: _self ? 'self' : 'other',
          subjectLabel: _who,
          consentVersion: consentVersion,
          statement: _spoken ? _statement : null,
          allowReEnrollment: _reEnroll,
        ),
      ));
      if (!mounted) return;
      setState(() {
        _voice = voice;
        _step = _Step.submitted;
      });
      _followReview();
    } catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The provider reviews a clone; the Host advances it in the background, and
  /// this only reads where it has got to while somebody is looking.
  void _followReview() {
    _review?.cancel();
    if (_voice?.status != 'preparing') return;
    _review = Timer.periodic(const Duration(seconds: 3), (timer) async {
      final voice = _voice;
      if (voice == null) return timer.cancel();
      try {
        final now = await widget.voices.ownerVoice(voice.voiceAssetId);
        if (!mounted) return;
        setState(() => _voice = now);
        if (now.status != 'preparing') timer.cancel();
      } catch (_) {
        // The next tick asks again; the Host keeps advancing it regardless.
      }
    });
  }

  Future<void> _again() async {
    final failed = _voice;
    _review?.cancel();
    setState(() {
      _voice = null;
      _check = null;
      _file = null;
      _operationId = null;
      _step = _Step.source;
    });
    // A voice the provider would not make is of no use to keep in the list.
    if (failed != null) {
      unawaited(widget.voices.delete(failed).catchError((Object _) {}));
    }
  }

  void _leave() =>
      Navigator.of(context).pop(_voice?.status == 'rejected' ? null : _voice);

  // ------------------------------------------------------------------- views

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: _step != _Step.recording,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_abandonRecording('录音已取消'));
        },
        child: Scaffold(
          key: const Key('voice-clone-page'),
          appBar: AppBar(title: const Text('用录音复刻一个声音')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_busy) const LinearProgressIndicator(),
              ...switch (_step) {
                _Step.consent => _consentView(),
                _Step.source => _sourceView(),
                _Step.recording => _recordingView(),
                _Step.checked => _checkedView(),
                _Step.submitted => _submittedView(),
              },
              if (_failure case final failure?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(failure,
                      key: const Key('voice-clone-failure'),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      );

  List<Widget> _consentView() {
    final processor = widget.processor;
    return [
      const Text('复刻会生成一个和录音人一样的声音。用的是谁的声音，就要谁本人同意。'),
      const SizedBox(height: 12),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('我自己')),
          ButtonSegment(value: false, label: Text('家人或朋友')),
        ],
        selected: {_self},
        onSelectionChanged: (value) => setState(() => _self = value.single),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('voice-clone-who'),
        controller: _label,
        maxLength: 32,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: _self ? '你的称呼' : '录音人的称呼（本人已同意）',
          border: const OutlineInputBorder(),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '录音会发送到${processor == null ? '这台主机使用的云端语音服务' : '云端语音服务（$processor）'}'
            '生成声音，服务商会保存这段参考音频，直到你删除这个声音。'
            '原始录音也保存在这台主机上，用于以后更换语音服务时重新生成，可以随时删除。',
            key: const Key('voice-clone-disclosure'),
          ),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('以后更换语音服务时，允许用原始录音重新生成'),
        value: _reEnroll,
        onChanged: (value) => setState(() => _reEnroll = value),
      ),
      CheckboxListTile(
        key: const Key('voice-clone-agree'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(_self ? '我已了解，同意用我的声音生成声音' : '我已了解，录音人本人同意用他的声音生成声音'),
        value: _agreed,
        onChanged: (value) => setState(() => _agreed = value == true),
      ),
      FilledButton(
        key: const Key('voice-clone-continue'),
        onPressed: _agreed && _who.isNotEmpty
            ? () => setState(() => _step = _Step.source)
            : null,
        child: const Text('继续'),
      ),
    ];
  }

  List<Widget> _sourceView() => [
        Card(
          child: ListTile(
            key: const Key('voice-clone-record'),
            leading: const Icon(Icons.mic_none_outlined),
            title: const Text('现场录音'),
            subtitle: Text('找个安静的地方，读出屏幕上的一段话，'
                '${_minMs ~/ 1000}～${_maxMs ~/ 1000} 秒'),
            onTap: _busy ? null : _record,
          ),
        ),
        Card(
          child: ListTile(
            key: const Key('voice-clone-file'),
            leading: const Icon(Icons.audio_file_outlined),
            title: const Text('选择音频文件'),
            subtitle: Text('WAV、MP3、M4A/AAC 或 FLAC，不超过 '
                '${_maxBytes ~/ (1024 * 1024)} MB。文件里只能有这一个人在说话，没有背景音乐'),
            onTap: _busy ? null : _chooseFile,
          ),
        ),
      ];

  List<Widget> _recordingView() {
    final elapsed = _recordedMs;
    final canStop = elapsed >= _minMs && !_busy;
    final text = Theme.of(context).textTheme;
    return [
      Text('请读出下面的话', style: text.titleMedium),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('$_statement\n\n$_passage',
              key: const Key('voice-clone-script'), style: text.bodyLarge),
        ),
      ),
      const SizedBox(height: 12),
      LinearProgressIndicator(
          key: const Key('voice-clone-level'), value: _busy ? null : _level),
      const SizedBox(height: 8),
      Text('${(elapsed / 1000).toStringAsFixed(0)} 秒 / 最长 ${_maxMs ~/ 1000} 秒',
          key: const Key('voice-clone-elapsed')),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton(
            onPressed: _busy ? null : () => _abandonRecording('已经放弃这段录音'),
            child: const Text('重录')),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            key: const Key('voice-clone-stop'),
            onPressed: canStop ? _finishRecording : null,
            child: Text(canStop
                ? '录好了'
                : _busy
                    ? '正在检查…'
                    : '至少录 ${_minMs ~/ 1000} 秒'),
          ),
        ),
      ]),
    ];
  }

  List<Widget> _checkedView() {
    final check = _check!;
    final wav = check.audioBase64 == null
        ? null
        : Uint8List.fromList(base64Decode(check.audioBase64!));
    final file = _file;
    final room = check.durationMs - check.windowMs;
    return [
      Card(
        child: ListTile(
          key: const Key('voice-clone-check'),
          leading: Icon(
              check.accepted ? Icons.check_circle : Icons.error_outline,
              color: check.accepted
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error),
          title: Text(check.accepted ? '这段录音可以用' : '这段录音不能用'),
          subtitle: Text(check.accepted
              ? '会用第 ${check.windowStartMs ~/ 1000}～'
                  '${(check.windowStartMs + check.windowMs) ~/ 1000} 秒'
              : check.problems.map(referenceProblem).join('\n')),
          trailing: wav == null
              ? null
              : AuditionButton(
                  audition: _audition, voiceKey: 'reference', wav: wav),
        ),
      ),
      if (!_spoken && file != null && room > 0) ...[
        const SizedBox(height: 8),
        const Text('换一段：拖动选择要用的部分'),
        Slider(
          key: const Key('voice-clone-window'),
          value: (_windowStart ?? 0).clamp(0, room).toDouble(),
          max: room.toDouble(),
          divisions: max(1, room ~/ 1000),
          label: '从第 ${(_windowStart ?? 0) ~/ 1000} 秒开始',
          onChanged: _busy
              ? null
              : (value) => setState(() => _windowStart = value.round()),
          onChangeEnd:
              _busy ? null : (value) => _measure(file, startMs: value.round()),
        ),
      ],
      const SizedBox(height: 12),
      if (check.accepted) ...[
        TextField(
          key: const Key('voice-clone-name'),
          controller: _name,
          maxLength: 64,
          decoration: const InputDecoration(
              labelText: '给这个声音起个名字', border: OutlineInputBorder()),
        ),
        FilledButton(
          key: const Key('voice-clone-submit'),
          onPressed: _busy ? null : _submit,
          child: const Text('提交生成'),
        ),
      ],
      TextButton(
        onPressed: _busy ? null : () => setState(() => _step = _Step.source),
        child: Text(_spoken ? '重新录' : '换一个文件'),
      ),
    ];
  }

  List<Widget> _submittedView() {
    final voice = _voice!;
    return switch (voice.status) {
      'ready' => [
          ListTile(
            key: const Key('voice-clone-ready'),
            leading: const Icon(Icons.check_circle_outline),
            title: Text('「${voice.name}」可以用了'),
            trailing:
                AuditionButton(audition: _audition, voiceKey: voice.voiceKey),
          ),
          FilledButton(onPressed: _leave, child: const Text('完成')),
        ],
      'rejected' => [
          ListTile(
            key: const Key('voice-clone-rejected'),
            leading: Icon(Icons.error_outline,
                color: Theme.of(context).colorScheme.error),
            title: const Text('没能生成这个声音'),
            subtitle: Text(voice.statusDetail ?? '服务商没有通过这段录音'),
          ),
          FilledButton(onPressed: _again, child: const Text('重新录')),
          TextButton(onPressed: _leave, child: const Text('离开')),
        ],
      _ => [
          const ListTile(
            key: Key('voice-clone-preparing'),
            leading: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('已提交，服务商正在审核'),
            subtitle: Text('可以在这里等，也可以先离开，之后在「我的声音」里看状态。'),
          ),
          OutlinedButton(onPressed: _leave, child: const Text('先离开')),
        ],
    };
  }
}
