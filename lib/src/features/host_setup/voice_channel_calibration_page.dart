import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../../platform/platform_bridge.dart';
import 'voice_enrollment_recorder.dart';
import 'voiceprint_call.dart';

/// 声纹环境校准 (design §8.2, 1c-a).
///
/// A computer speaker replays public speech next to the phone. Each segment is
/// recorded through the registration recorder — same microphone options, same
/// Host media path — and extracted by Admin like a registration sample, so this
/// household's phone channel gains impostor evidence it otherwise lacks. The
/// voices are public speakers, never household members; the Host keeps the
/// embeddings only, never the audio.
class VoiceChannelCalibrationPage extends StatefulWidget {
  const VoiceChannelCalibrationPage(
      {super.key,
      required this.call,
      this.recorderFactory,
      this.keepScreenOn,
      this.segment = const Duration(seconds: 8),
      this.maxSegments = 700});
  final VoiceprintCall call;
  final VoiceEnrollmentRecorder Function()? recorderFactory;

  /// The run outlasts any screen timeout; a locked phone would end it.
  final Future<void> Function(bool on)? keepScreenOn;

  /// Back-to-back recording length; a little longer than a registration read.
  final Duration segment;

  /// About an hour and a half of replay, more than the corpus being played.
  final int maxSegments;
  @override
  State<VoiceChannelCalibrationPage> createState() =>
      _VoiceChannelCalibrationPageState();
}

class _VoiceChannelCalibrationPageState
    extends State<VoiceChannelCalibrationPage> with WidgetsBindingObserver {
  // A run that keeps failing has lost its Host or its speaker; say so and stop
  // instead of spinning through the segment budget.
  static const _maxConsecutiveFailures = 20;
  static const _pcmBytesPerSecond = 32000;

  VoiceEnrollmentRecorder? _recorder;
  int _generation = 0;
  bool _running = false, _stopRequested = false;
  String? _phase, _batchId, _lastFailure, _notice, _stopNotice;
  int _uploaded = 0, _failed = 0;
  final _elapsed = Stopwatch();
  Timer? _ticker;
  Completer<void>? _segmentWake;

  List<ChannelCalibrationBatch>? _batches;
  bool _loadingBatches = false;
  String? _batchError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadBatches());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A backgrounded app cannot hold the microphone; recording silence would
    // only fill the run with failures. A pulled-down shade is not a reason.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _stop('应用离开了前台，校准已停止，回到应用后可重新开始。');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _ticker?.cancel();
    if (_running) _holdScreen(false);
    _wake();
    final recorder = _recorder;
    if (recorder != null) {
      unawaited(() async {
        try {
          await recorder.cancel();
        } catch (_) {/* Already stopped. */}
        await recorder.dispose();
      }());
    }
    super.dispose();
  }

  bool _live(int generation) =>
      mounted && generation == _generation && !_stopRequested;

  void _wake() {
    final wake = _segmentWake;
    _segmentWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _holdScreen(bool on) {
    unawaited(() async {
      try {
        await (widget.keepScreenOn ?? const PlatformBridge().keepScreenOn)(on);
      } catch (_) {
        /* The run still works for as long as the screen stays on. */
      }
    }());
  }

  void _setPhase(String phase) {
    if (mounted) setState(() => _phase = phase);
  }

  String _describe(Object error) => error is ManagementRequestException
      ? error.message
      : error is StateError
          ? error.message
          : '录音或上传未完成，请检查主机连接';

  Future<void> _loadBatches() async {
    if (!mounted) return;
    setState(() => _loadingBatches = true);
    try {
      final collection = ChannelCalibrationCollection.fromJson(
          await widget.call(suffix: '/channel-calibration'));
      if (mounted) {
        setState(() {
          _batches = collection.batches ?? [];
          _batchError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _batchError =
            e is ManagementRequestException ? e.message : '暂时无法读取校准批次，请重试');
      }
    } finally {
      if (mounted) setState(() => _loadingBatches = false);
    }
  }

  Future<void> _deleteBatch(ChannelCalibrationBatch batch) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('删除这批校准样本？'),
              content:
                  Text('将删除批次 ${batch.batchId} 的 ${batch.samples} 段样本，无法恢复。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除')),
              ],
            ));
    if (yes != true || !mounted) return;
    setState(() => _loadingBatches = true);
    try {
      final collection = ChannelCalibrationCollection.fromJson(await widget.call(
          method: 'DELETE',
          suffix:
              '/channel-calibration/batches/${Uri.encodeComponent(batch.batchId)}'));
      if (mounted) {
        setState(() {
          _batches = collection.batches ?? [];
          _batchError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _batchError =
            e is ManagementRequestException ? e.message : '删除未确认，请刷新后查看');
      }
    } finally {
      if (mounted) setState(() => _loadingBatches = false);
    }
  }

  Future<void> _start() async {
    if (_running) return;
    final generation = ++_generation;
    final batch = 'replay-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _running = true;
      _stopRequested = false;
      _batchId = batch;
      _uploaded = 0;
      _failed = 0;
      _lastFailure = null;
      _notice = null;
      _stopNotice = null;
      _phase = '正在检查主机…';
    });
    _holdScreen(true);
    _elapsed
      ..reset()
      ..start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    String? ending;
    try {
      final ready = SpeakerExtractionReadiness.fromJson(await widget
          .call(suffix: '/readiness')
          .timeout(const Duration(seconds: 10)));
      if (!ready.extractionReady) {
        throw StateError('声纹服务正在准备或暂不可用，请稍后再试');
      }
      if (!_live(generation)) return;
      _recorder ??= widget.recorderFactory?.call() ??
          LiveKitVoiceEnrollmentRecorder(widget.call);
      if (!await _recorder!.hasPermission()) {
        throw StateError('请在系统设置中允许使用麦克风');
      }
      var consecutive = 0;
      while (_live(generation)) {
        if (_uploaded + _failed >= widget.maxSegments) {
          ending = '已录满 ${widget.maxSegments} 段，校准结束。';
          break;
        }
        if (consecutive >= _maxConsecutiveFailures) {
          ending = '连续 $consecutive 段没有成功，已自动停止。请确认电脑仍在播放、主机在线后重新开始。';
          break;
        }
        _setPhase('正在连接录音…');
        final Uint8List? pcm;
        try {
          pcm = await _capture(generation);
        } catch (e) {
          if (!_live(generation)) break;
          consecutive++;
          _countFailure(e);
          await _backOff(generation);
          continue;
        }
        if (pcm == null) break;
        if (pcm.isEmpty) {
          consecutive++;
          _countFailure(StateError('没有收到录音'));
          continue;
        }
        _setPhase('正在上传第 ${_uploaded + _failed + 1} 段…');
        try {
          await widget.call(
              method: 'POST',
              suffix: '/channel-calibration/samples',
              body: ChannelCalibrationUpload(
                      batchId: batch, pcmBase64: base64Encode(pcm))
                  .toJson());
          // Stored even if Stop was pressed meanwhile; the count says so.
          consecutive = 0;
          if (mounted) setState(() => _uploaded++);
        } catch (e) {
          consecutive++;
          _countFailure(e);
          // A refused recording (too little speech) is ordinary between
          // speakers: go straight on. Anything else gets a moment first.
          if (!(e is ManagementRequestException && e.statusCode == 422)) {
            await _backOff(generation);
          }
        }
      }
    } catch (e) {
      if (generation == _generation) ending = _describe(e);
    } finally {
      if (generation == _generation) {
        _ticker?.cancel();
        _ticker = null;
        _elapsed.stop();
        _holdScreen(false);
        _wake();
        if (mounted) {
          setState(() {
            _running = false;
            _stopRequested = false;
            _phase = null;
            // Counted after the last in-flight upload, not when Stop was pressed.
            _notice = ending ?? '${_stopNotice ?? '已停止。'}本批次已上传 $_uploaded 段。';
          });
        }
        unawaited(_loadBatches());
      }
    }
  }

  void _countFailure(Object error) {
    if (!mounted) return;
    setState(() {
      _failed++;
      _lastFailure = _describe(error);
    });
  }

  Future<void> _backOff(int generation) async {
    if (!_live(generation)) return;
    final wake = Completer<void>();
    _segmentWake = wake;
    final timer = Timer(const Duration(seconds: 2), () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    if (identical(_segmentWake, wake)) _segmentWake = null;
  }

  /// One segment: null when the run was stopped while it was being recorded.
  Future<Uint8List?> _capture(int generation) async {
    final recorder = _recorder!;
    final stream = await recorder.start();
    if (!_live(generation)) {
      await recorder.cancel();
      return null;
    }
    _setPhase('正在录音第 ${_uploaded + _failed + 1} 段…');
    // An incremental recorder streams PCM; the Host recorder returns it on stop.
    final limit = _pcmBytesPerSecond * widget.segment.inMilliseconds ~/ 1000;
    final audio = BytesBuilder(copy: false);
    final wake = Completer<void>();
    _segmentWake = wake;
    var interrupted = false;
    final subscription = stream.listen((bytes) {
      final remaining = limit - audio.length;
      if (remaining <= 0) return;
      audio.add(bytes.length > remaining ? bytes.sublist(0, remaining) : bytes);
      if (audio.length >= limit && !wake.isCompleted) wake.complete();
    }, onError: (Object _) {
      interrupted = true;
      if (!wake.isCompleted) wake.complete();
    });
    final timer = Timer(widget.segment, () {
      if (!wake.isCompleted) wake.complete();
    });
    try {
      await wake.future;
      timer.cancel();
      if (identical(_segmentWake, wake)) _segmentWake = null;
      if (!_live(generation) || interrupted) {
        await recorder.cancel();
        if (interrupted && _live(generation)) throw StateError('录音中断');
        return null;
      }
      final pcm = await recorder.stop();
      if (!_live(generation)) return null;
      return pcm ?? audio.takeBytes();
    } finally {
      timer.cancel();
      unawaited(subscription.cancel());
    }
  }

  void _stop([String? notice]) {
    if (!_running || _stopRequested) return;
    setState(() {
      _stopRequested = true;
      _phase = '正在停止…';
      _stopNotice = notice;
    });
    _wake();
    final recorder = _recorder;
    if (recorder != null) {
      unawaited(recorder.cancel().catchError((Object _) {}));
    }
  }

  Future<void> _leave() async {
    final stop = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('校准正在进行'),
              content: const Text('离开会停止录音。已上传的样本会保留。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续校准')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('停止并返回')),
              ],
            ));
    if (stop != true || !mounted) return;
    _stop();
    Navigator.pop(context);
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _duration(Duration value) {
    final minutes = _two(value.inMinutes.remainder(60));
    final seconds = _two(value.inSeconds.remainder(60));
    return value.inHours > 0
        ? '${value.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  static String _time(double epochSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).round())
        .toLocal();
    return '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final batches = _batches;
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('声纹环境校准')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Text(
              '把手机放在电脑音箱旁，由电脑回放公开的朗读录音，录音期间请保持房间安静。这里只录公开说话人的声音，不录家人的声音；主机只保存声纹特征，不保存录音。'),
          const SizedBox(height: 8),
          Text('校准期间请保持本页在前台、屏幕常亮。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          if (_running) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            if (_phase != null) Text(_phase!),
          ],
          if (_running || (_batchId != null && _uploaded + _failed > 0)) ...[
            Text(
                '已上传 $_uploaded 段 · 失败 $_failed 段 · 已用时 ${_duration(_elapsed.elapsed)}',
                key: const Key('calibration-progress'),
                style: theme.textTheme.titleMedium),
            if (_batchId != null)
              Text('批次 $_batchId', style: theme.textTheme.bodySmall),
            if (_lastFailure != null)
              Text('最近一次失败：$_lastFailure',
                  style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_notice != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_notice!, key: const Key('calibration-notice'))),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('calibration-toggle'),
            onPressed:
                _running ? (_stopRequested ? null : () => _stop()) : _start,
            icon: Icon(_running ? Icons.stop : Icons.mic),
            label: Text(_running ? (_stopRequested ? '正在停止…' : '停止') : '开始校准'),
          ),
          const SizedBox(height: 28),
          Row(children: [
            Expanded(
                child: Text('已保存的校准批次', style: theme.textTheme.titleLarge)),
            IconButton(
                tooltip: '刷新',
                onPressed: _loadingBatches ? null : _loadBatches,
                icon: const Icon(Icons.refresh)),
          ]),
          if (_loadingBatches) const LinearProgressIndicator(),
          if (_batchError != null)
            Text(_batchError!,
                style: TextStyle(color: theme.colorScheme.error)),
          if (batches != null && batches.isEmpty) const Text('还没有校准样本'),
          for (final batch in batches ?? <ChannelCalibrationBatch>[])
            Card(
              key: ValueKey('calibration-batch-${batch.batchId}'),
              child: ListTile(
                title: Text(
                    '${_time(batch.firstCapturedAt)} · ${batch.samples} 段'),
                subtitle: Text('批次 ${batch.batchId} · 信道 ${batch.channel}'),
                trailing: IconButton(
                  tooltip: '删除批次',
                  onPressed: _running || _loadingBatches
                      ? null
                      : () => _deleteBatch(batch),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
