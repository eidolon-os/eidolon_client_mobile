import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'voice_enrollment_recorder.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'voice_recording_dialog.dart';

typedef VoiceprintCall = Future<Map<String, dynamic>> Function({
  String method,
  String suffix,
  Map<String, dynamic>? body,
});

class VoiceprintPage extends StatefulWidget {
  const VoiceprintPage(
      {super.key, required this.companionName, required this.call});
  final String companionName;
  final VoiceprintCall call;
  @override
  State<VoiceprintPage> createState() => _VoiceprintPageState();
}

class _VoiceprintPageState extends State<VoiceprintPage> {
  VoicePolicyView? _policy;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => _act(() async {
        final p = VoicePolicyView.fromJson(await widget.call());
        if (mounted) setState(() => _policy = p);
      });

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            e is ManagementRequestException ? e.message : '主机暂时无法完成声纹操作，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(String method, String suffix,
          [Map<String, dynamic>? body]) =>
      _act(() async {
        final p = VoicePolicyView.fromJson(
            await widget.call(method: method, suffix: suffix, body: body));
        if (mounted) setState(() => _policy = p);
      });

  Future<void> _enroll([SpeakerProfileView? profile]) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) =>
            VoiceEnrollmentPage(call: widget.call, profile: profile)));
    if (mounted) await _load();
  }

  Future<void> _delete(SpeakerProfileView profile) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('删除“${profile.displayName}”的声纹？'),
                content: const Text('此主机所有伙伴都会移除此声音。只想从当前伙伴移除，请使用“移除”。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (yes == true && mounted) {
      await _change(
          'DELETE', '/profiles/${Uri.encodeComponent(profile.profileId)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _policy;
    final allowed = p?.allowedProfileIds ?? <String>[];
    return Scaffold(
        appBar: AppBar(title: const Text('声纹管理')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(widget.companionName,
              style: Theme.of(context).textTheme.headlineSmall),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ...[
            Text(_error!),
            TextButton(onPressed: _busy ? null : _load, child: const Text('重试'))
          ],
          if (p != null) ...[
            Text('已保存的声音（${p.profiles?.length ?? 0}）',
                style: Theme.of(context).textTheme.titleLarge),
            const Text('在这里回放、重录或删除声音；对话开关在伙伴主页。'),
            if (allowed.isEmpty)
              Text(p.mode == 'allowlist' ? '暂无允许的声音，当前不会回应语音' : '尚未添加声音'),
            for (final profile in p.profiles ?? <SpeakerProfileView>[])
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(profile.displayName,
                                style: Theme.of(context).textTheme.titleMedium),
                            Text(allowed.contains(profile.profileId)
                                ? '允许与此伙伴对话'
                                : '已录入，尚未允许与此伙伴对话'),
                            Wrap(children: [
                              if (profile.recordingAvailable == true)
                                TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => showDialog<void>(
                                            context: context,
                                            builder: (_) =>
                                                VoiceRecordingDialog(
                                              name: profile.displayName,
                                              load: () => widget.call(
                                                  suffix:
                                                      '/profiles/${Uri.encodeComponent(profile.profileId)}/recording'),
                                            ),
                                          ),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('回放录入声音'),
                                )
                              else
                                const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('暂无录音，重新录入后可回放')),
                              TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _change(
                                          allowed.contains(profile.profileId)
                                              ? 'DELETE'
                                              : 'PUT',
                                          '/bindings/${Uri.encodeComponent(profile.profileId)}'),
                                  child: Text(
                                      allowed.contains(profile.profileId)
                                          ? '移除'
                                          : '允许')),
                              TextButton(
                                  onPressed:
                                      _busy ? null : () => _enroll(profile),
                                  child: const Text('重新录入')),
                              TextButton(
                                  onPressed:
                                      _busy ? null : () => _delete(profile),
                                  child: const Text('删除声纹')),
                            ]),
                          ]))),
            FilledButton.icon(
                onPressed: _busy ? null : () => _enroll(),
                icon: const Icon(Icons.mic),
                label: const Text('录入新声音')),
            const SizedBox(height: 12),
            const Text('手机录入后，请在平时使用的对话设备上试说。简短的“嗯”“好”可能不足以识别。'),
          ],
        ]));
  }
}

class VoiceEnrollmentPage extends StatefulWidget {
  const VoiceEnrollmentPage(
      {super.key, required this.call, this.profile, this.recorderFactory});
  final VoiceEnrollmentRecorder Function()? recorderFactory;
  final VoiceprintCall call;
  final SpeakerProfileView? profile;
  @override
  State<VoiceEnrollmentPage> createState() => _VoiceEnrollmentPageState();
}

class _VoiceEnrollmentPageState extends State<VoiceEnrollmentPage>
    with WidgetsBindingObserver {
  final _name = TextEditingController();
  final _operation = 'mobile_${DateTime.now().microsecondsSinceEpoch}';
  VoiceEnrollmentRecorder? _recorder;
  SpeakerProfileView? _saved;
  String? _feedback;
  bool _leaving = false;
  StreamSubscription<Uint8List>? _subscription;
  BytesBuilder _audio = BytesBuilder(copy: false);
  EnrollmentView? _enrollment;
  Uint8List? _pending;
  String? _error;
  bool _recording = false, _busy = false, _done = false;
  int _samples = 0;
  int _lifecycleGeneration = 0;
  static const _sentences = [
    '今天的天气很好，我想和你聊聊最近发生的事情。',
    '周末我准备出去走走，也想听听你有什么好建议。',
    '请记住我的声音，以后我们可以一起分享生活中的故事。',
    '这是一次新的试说，请确认你现在能认出我的声音。',
  ];

  @override
  void initState() {
    super.initState();
    _name.text = widget.profile?.displayName ?? '';
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _lifecycleGeneration++;
      if (_recording) unawaited(_discardRecording());
    }
  }

  Future<void> _discardRecording() async {
    await _subscription?.cancel();
    _subscription = null;
    await _recorder?.cancel();
    _audio = BytesBuilder(copy: false);
    if (mounted) setState(() => _recording = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleGeneration++;
    unawaited(_subscription?.cancel());
    unawaited(_recorder?.dispose());
    final e = _enrollment;
    if (e != null && !_done) {
      unawaited(widget
          .call(method: 'DELETE', suffix: '/enrollments/${e.enrollmentId}')
          .catchError((_) => <String, dynamic>{}));
    }
    _pending = null;
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请填写称呼');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _recorder ??=
          widget.recorderFactory?.call() ?? LocalVoiceEnrollmentRecorder();
      if (!await _recorder!.hasPermission()) {
        throw StateError('请在系统设置中允许使用麦克风');
      }
      if (!mounted) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
        throw StateError('请回到应用后重新开始录音');
      }
      // The permission sheet itself can suspend the app. Fence later work only
      // after that sheet has returned, so first-time permission is not a silent no-op.
      final generation = _lifecycleGeneration;
      _enrollment ??= EnrollmentView.fromJson(await widget.call(
          method: 'POST',
          suffix: '/enrollments',
          body: EnrollmentCreate(
                  operationId: _operation,
                  displayName: _name.text.trim(),
                  profileId: widget.profile?.profileId)
              .toJson()));
      if (!mounted) return;
      if (generation != _lifecycleGeneration) {
        throw StateError('录音准备已中断，请重新开始');
      }
      final stream = await _recorder!.start();
      if (!mounted || generation != _lifecycleGeneration) {
        await _recorder!.cancel();
        return;
      }
      _audio = BytesBuilder(copy: false);
      setState(() {
        _recording = true;
        _busy = false;
      });
      _subscription = stream.listen((bytes) {
        if (!_recording) return;
        _audio.add(bytes);
        setState(() {});
        if (_audio.length >= 32000 * 8) unawaited(_stop());
      }, onError: (_) {
        unawaited(_discardRecording());
        if (mounted) setState(() => _error = '录音中断，请重试');
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            e is StateError ? e.message.toString() : '无法开始录入，请检查麦克风和主机连接');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      await _recorder!.stop();
      await _subscription?.cancel();
      _subscription = null;
      _pending = _audio.takeBytes();
      if (_pending!.length < 32000 * 3) {
        _pending = null;
        if (mounted) setState(() => _error = '请说完整句子，至少录制 3 秒');
        return;
      }
      if (mounted) await _submit();
    } catch (_) {
      _pending = null;
      if (mounted) setState(() => _error = '无法完成录音，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final pcm = _pending;
    final e = _enrollment;
    if (pcm == null || e == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final trial = _samples == 3;
      final response = await widget.call(
          method: trial ? 'POST' : 'PUT',
          suffix:
              '/enrollments/${e.enrollmentId}/${trial ? 'complete' : 'samples/$_samples'}',
          body: VoiceAudioRequest(pcmBase64: base64Encode(pcm)).toJson());
      if (!mounted) return;
      _pending = null;
      if (trial) {
        setState(() {
          _saved = SpeakerProfileView.fromJson(response);
          _done = true;
        });
      } else {
        _enrollment = EnrollmentView.fromJson(response);
        setState(() {
          _samples = _enrollment!.acceptedSamples;
          _feedback =
              '第 $_samples 段录音已通过。${_samples == 3 ? "还差最后一次试说，完成后才会保存声纹。" : "请继续录制下一段，声纹尚未保存。"}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (e is ManagementRequestException &&
          (e.statusCode == 422 || e.statusCode == 409)) {
        _pending = null;
      }
      setState(() =>
          _error = e is ManagementRequestException ? e.message : '提交失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    if (_busy) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在检查录音，请等待结果后再返回')));
      return;
    }
    _leaving = true;
    try {
      if (_recording) await _discardRecording();
      if (!mounted) return;
      if (!_done && _enrollment != null) {
        final discard = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('声纹尚未保存'),
                  content: Text(
                      '已通过 $_samples 段录音。现在离开会放弃本次录入，${widget.profile == null ? "不会新增声纹。" : "原有声纹保持不变。"}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('继续录入')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('放弃并返回')),
                  ],
                ));
        if (discard != true || !mounted) return;
      }
      if (mounted) Navigator.pop(context);
    } finally {
      _leaving = false;
    }
  }

  Widget _success() => Scaffold(
        appBar: AppBar(title: const Text('录入完成')),
        body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.check_circle, size: 64, color: Colors.green),
                const Text('声纹已保存',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24)),
                Text('“${_saved!.displayName}”已加入这个伙伴允许的声音。',
                    textAlign: TextAlign.center),
                const Text('可在「伙伴主页 → 管理声纹」中查看、回放和删除。是否启用声纹限制，可在伙伴主页设置。'),
                if (_saved!.recordingAvailable == true)
                  TextButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('回放录入声音'),
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => VoiceRecordingDialog(
                              name: _saved!.displayName,
                              load: () => widget.call(
                                  suffix:
                                      '/profiles/${Uri.encodeComponent(_saved!.profileId)}/recording'),
                            )),
                  ),
                FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成，查看声纹')),
              ],
            )),
      );

  @override
  Widget build(BuildContext context) {
    if (_done) return _success();
    return PopScope(
        canPop: _enrollment == null && !_busy && !_recording,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) unawaited(_leave());
        },
        child: Scaffold(
            appBar: AppBar(title: Text('第 ${_samples + 1} 步，共 4 步')),
            body: ListView(padding: const EdgeInsets.all(24), children: [
              TextField(
                  controller: _name,
                  enabled: _enrollment == null && !_busy,
                  decoration: const InputDecoration(
                      labelText: '称呼', hintText: '例如：我、妈妈')),
              const SizedBox(height: 24),
              const Text('先录制 3 段声音，再完成 1 次试说。四步全部通过后才会保存。'),
              if (_feedback != null)
                Text(_feedback!,
                    key: const Key('voice-enrollment-feedback'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              const Text('请在安静环境中，以平时说话的声音读出下面的句子。每段约 4–6 秒。'),
              const SizedBox(height: 20),
              Text(_sentences[_samples.clamp(0, 3)],
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              if (_recording)
                Text('正在录音 ${(_audio.length / 32000).toStringAsFixed(1)} 秒'),
              if (_busy) ...[
                const LinearProgressIndicator(),
                Text(_pending != null ? '正在检查声音，请稍候…' : '正在准备录音…')
              ],
              if (_error != null)
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 16),
              FilledButton.icon(
                  key: const Key('voice-enrollment-record'),
                  onPressed: _busy
                      ? null
                      : (_recording
                          ? _stop
                          : (_pending != null ? _submit : _start)),
                  icon: Icon(_recording ? Icons.stop : Icons.mic),
                  label: Text(_recording
                      ? '结束并检查'
                      : (_pending != null
                          ? '重试提交'
                          : (_samples == 3
                              ? '录制最后一次试说'
                              : '录制第 ${_samples + 1} 段')))),
              const SizedBox(height: 16),
              const Text(
                  '验证成功后才会保存。最后一次试说录音会保存在主机，供你回放辨认，删除声纹时一起删除。离开页面会取消未完成的录入；重新录入失败不会替换原有声纹。'),
            ])));
  }
}
