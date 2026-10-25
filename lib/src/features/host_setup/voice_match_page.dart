import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'voice_enrollment_recorder.dart';
import 'voiceprint_call.dart';

/// A temporary measurement against this Companion's current sound list.
/// The recording is never enrolled, persisted or used to change conversation policy.
class VoiceMatchPage extends StatefulWidget {
  const VoiceMatchPage(
      {super.key,
      required this.companionName,
      required this.call,
      this.recorderFactory});
  final String companionName;
  final VoiceprintCall call;
  final VoiceEnrollmentRecorder Function()? recorderFactory;
  @override
  State<VoiceMatchPage> createState() => _VoiceMatchPageState();
}

class _VoiceMatchPageState extends State<VoiceMatchPage>
    with WidgetsBindingObserver {
  VoiceEnrollmentRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _timer, _deadline;
  final _elapsed = Stopwatch();
  BytesBuilder _audio = BytesBuilder(copy: false);
  bool _recording = false, _busy = false;
  int _generation = 0;
  String? _error;
  String _scene = '本人';
  final _results = <({
    String scene,
    int audioMs,
    VoiceMatchTestResult? result,
    String? error,
  })>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _generation++;
      if (_recording) unawaited(_discard('录音已取消，回到页面后可重新测试'));
    }
  }

  void _cancelTimers() {
    _timer?.cancel();
    _deadline?.cancel();
    _elapsed.stop();
  }

  Future<void> _discard(String message) async {
    _generation++;
    _cancelTimers();
    _audio.clear();
    if (mounted) {
      setState(() {
        _recording = false;
        _busy = true;
        _error = message;
      });
    }
    try {
      await _subscription?.cancel();
      _subscription = null;
      await _recorder?.cancel();
    } catch (_) {
      // No upload or retry is performed when capture is cancelled.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _cancelTimers();
    _audio.clear();
    unawaited(_release());
    super.dispose();
  }

  Future<void> _release() async {
    try {
      await _subscription?.cancel();
    } catch (_) {/* Already closed. */}
    try {
      await _recorder?.cancel();
    } catch (_) {/* Already stopped. */}
    await _recorder?.dispose();
  }

  Future<void> _start() async {
    if (_busy || _recording) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final beforeRead = _generation;
      final policy = VoicePolicyView.fromJson(
          await widget.call().timeout(const Duration(seconds: 10)));
      if (!mounted || beforeRead != _generation) return;
      if (policy.allowedProfileIds?.isNotEmpty != true) {
        throw StateError('请返回声纹管理，为此伙伴添加一个已录入的声音');
      }
      if (policy.readiness?.extractionReady != true) {
        throw StateError('声纹服务尚未准备好，请稍后再试');
      }
      _recorder ??=
          widget.recorderFactory?.call() ?? LocalVoiceEnrollmentRecorder();
      if (!await _recorder!.hasPermission()) throw StateError('请在系统设置中允许使用麦克风');
      if (!mounted) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
        throw StateError('请回到应用后重新开始录音');
      }
      // Permission UI may suspend the app; fence capture after permission returns.
      final generation = _generation;
      final stream = await _recorder!.start();
      if (!mounted || generation != _generation) {
        await _recorder!.cancel();
        return;
      }
      _audio = BytesBuilder(copy: false);
      _elapsed
        ..reset()
        ..start();
      setState(() {
        _recording = true;
        _busy = false;
      });
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted && _recording) setState(() {});
      });
      _deadline = Timer(const Duration(seconds: 8), () => unawaited(_finish()));
      _subscription = stream.listen(
          (bytes) {
            if (!_recording) return;
            final remaining = 32000 * 8 - _audio.length;
            _audio.add(
                bytes.length > remaining ? bytes.sublist(0, remaining) : bytes);
            if (_audio.length >= 32000 * 8) unawaited(_finish());
          },
          onError: (_) => unawaited(_discard('录音中断，请重新测试')),
          onDone: () {
            if (_recording) unawaited(_discard('录音中断，请重新测试'));
          });
    } catch (e) {
      if (mounted) setState(() => _error = _message(e, '无法开始录音，请检查麦克风和主机连接'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object e, String fallback) => e is ManagementRequestException
      ? e.reason ?? e.message
      : e is StateError
          ? e.message.toString()
          : fallback;

  Future<void> _finish() async {
    if (!_recording) return;
    final generation = _generation;
    final scene = _scene;
    var audioMs = 0;
    _cancelTimers();
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      await _recorder!.stop();
      await _subscription?.cancel();
      _subscription = null;
      if (!mounted || generation != _generation) return;
      final pcm = _audio.takeBytes();
      audioMs = pcm.length ~/ 32;
      if (pcm.length < 32000 * 3) throw StateError('录音不足 3 秒，请说完一句话后再结束');
      final result = VoiceMatchTestResult.fromJson(await widget
          .call(
              method: 'POST',
              suffix: '/match-test',
              body: VoiceAudioRequest(pcmBase64: base64Encode(pcm)).toJson())
          .timeout(const Duration(seconds: 25)));
      if (!mounted || generation != _generation) return;
      _remember(scene, result.audioMs, result: result);
    } catch (e) {
      if (mounted && generation == _generation) {
        final message = _message(e, '这次测试未取得结果，请检查主机连接后重新试说');
        if (audioMs > 0) {
          _remember(scene, audioMs, error: message);
        } else {
          setState(() => _error = message);
        }
      }
    } finally {
      _audio.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remember(String scene, int audioMs,
      {VoiceMatchTestResult? result, String? error}) {
    setState(() {
      _results.insert(
          0, (scene: scene, audioMs: audioMs, result: result, error: error));
      if (_results.length > 8) _results.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('测试声纹匹配')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(widget.companionName,
            style: Theme.of(context).textTheme.headlineSmall),
        const Text('未校准的相似度测试：分数不是识别准确率，也不代表准入通过。不会改变对话开关。'),
        const SizedBox(height: 16),
        const Text('选择本轮声音来源，分别测试更容易比较。'),
        Wrap(spacing: 8, children: [
          for (final scene in ['本人', '其他人', '仅电视', '本人+电视'])
            ChoiceChip(
                label: Text(scene),
                selected: scene == _scene,
                onSelected: _busy || _recording
                    ? null
                    : (_) => setState(() => _scene = scene))
        ]),
        const SizedBox(height: 12),
        Text(_scene == '仅电视'
            ? '保持本人安静，让电视连续播放人声 3–8 秒。'
            : '请连续说 3–8 秒，例如：“今天的天气很好，我想和你聊聊最近发生的事情。”'),
        const Text('8 秒自动结束并测试。试说音频仅用于本次计算，不保存。'),
        const SizedBox(height: 16),
        if (_recording) ...[
          Text(
              '正在录音 ${(_elapsed.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒 / 8 秒',
              style: Theme.of(context).textTheme.titleLarge),
          LinearProgressIndicator(
              value: (_elapsed.elapsedMilliseconds / 8000).clamp(0, 1)),
        ],
        if (_busy) const LinearProgressIndicator(),
        if (_busy) const Text('正在准备或计算，请稍候…'),
        if (_error != null)
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        FilledButton.icon(
            key: const Key('voice-match-record'),
            onPressed: _busy
                ? null
                : _recording
                    ? _finish
                    : _start,
            icon: Icon(_recording ? Icons.stop : Icons.mic),
            label: Text(_recording ? '结束并测试' : '开始试说')),
        if (_recording)
          TextButton(
              onPressed: () => _discard('本次录音已取消'),
              child: const Text('取消本次录音')),
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text('本页最近测试（离开后清空）'),
          for (final entry in _results)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${entry.scene} · ${(entry.audioMs / 1000).toStringAsFixed(1)} 秒录音',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (entry.error case final error?) ...[
                            const Text('未取得匹配分数'),
                            Text(error,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                            const Text('这不代表声纹不匹配，也不代表电视声音被成功过滤。'),
                          ],
                          if (entry.result case final result?) ...[
                            for (final score in result.scores)
                              Text(
                                  '${score.displayName}: ${score.status == 'scored' ? score.similarity?.toStringAsFixed(3) : '版本不兼容，请重新录入'}'),
                            Text(
                                '提取 ${result.extractionMs.toStringAsFixed(0)} ms · 主机总耗时 ${result.elapsedMs.toStringAsFixed(0)} ms'),
                            Text('模型：${result.modelId}'),
                          ],
                        ]))),
        ],
      ]));
}
