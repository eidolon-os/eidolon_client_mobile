import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../host_setup/voice_recording_player.dart';
import 'owner_voice_page.dart';
import 'speech_voice_repository.dart';
import 'speech_voice_wording.dart';
import 'voice_audition.dart';

/// Making a voice from words (§17.9 B): describe it, choose what it says as a
/// sample, generate, listen, then keep it or try again.
///
/// Pops with the kept voice. A generated voice that was not kept is a draft the
/// Host deletes on its own within a day; this page deletes it sooner when it
/// can — on 换一个, and on leaving after saying so.
class VoiceDesignPage extends StatefulWidget {
  const VoiceDesignPage({
    super.key,
    required this.companionName,
    required this.voices,
    required this.limits,
    this.playerFactory,
  });

  final String companionName;
  final SpeechVoices voices;
  final VoiceLimitsView limits;
  final VoiceRecordingPlayer Function()? playerFactory;

  @override
  State<VoiceDesignPage> createState() => _VoiceDesignPageState();
}

/// The dimensions the provider's own guidance asks a description to cover,
/// offered as taps so nobody has to know them.
const _dimensions = <(String, List<String>)>[
  ('性别', ['女声', '男声']),
  ('年龄', ['儿童', '青少年', '青年', '中年', '老年']),
  ('音调', ['音调低沉', '音调适中', '音调偏高']),
  ('语速', ['语速偏慢', '语速适中', '语速偏快']),
  ('情感', ['开朗', '沉稳', '温柔', '活泼', '严肃']),
  ('特点', ['磁性', '清脆', '沙哑', '甜美', '浑厚']),
];

const _examples = [
  '温柔知性的年轻女声，语速平缓，像睡前给人讲故事。',
  '爽朗的中年男声，声音浑厚有磁性，说话带着笑意。',
  '活泼的小女孩，声音清脆，语速稍快，对什么都很好奇。',
];

String mintOperationId(String what) =>
    'mobile_${what}_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';

class _VoiceDesignPageState extends State<VoiceDesignPage> {
  final _picked = <String, String>{};
  final _free = TextEditingController();
  final _freeFocus = FocusNode();
  late final _sample = TextEditingController(
      text: '你好，我是${widget.companionName}，很高兴认识你。以后想聊什么，随时叫我。');
  late final VoiceAudition _audition = VoiceAudition(
      load: widget.voices.preview, player: widget.playerFactory?.call());
  OwnerVoiceView? _draft;

  /// Kept across a failed attempt so pressing 生成 again after a lost answer
  /// asks for the same voice; dropped as soon as what is being asked changes.
  String? _operationId;
  bool _generating = false, _saving = false;
  String? _failure;

  int get _promptMax => widget.limits.promptMaxChars ?? 500;
  int get _sampleMin => widget.limits.previewTextMinChars ?? 15;
  int get _sampleMax => widget.limits.previewTextMaxChars ?? 200;

  String get _prompt {
    final picked = [
      for (final (dimension, _) in _dimensions)
        if (_picked[dimension] case final choice?) choice,
    ].join('，');
    final free = _free.text.trim();
    if (picked.isEmpty) return free;
    return free.isEmpty ? '$picked。' : '$picked。$free';
  }

  String? get _problem {
    final prompt = _prompt;
    if (prompt.isEmpty) return '先选几个特点，或者写一句描述';
    if (prompt.length > _promptMax) return '描述最多 $_promptMax 个字';
    final sample = _sample.text.trim().length;
    if (sample < _sampleMin || sample > _sampleMax) {
      return '试听的话需要 $_sampleMin～$_sampleMax 个字';
    }
    return null;
  }

  void _changed() => setState(() => _operationId = null);

  @override
  void dispose() {
    _audition.dispose();
    _free.dispose();
    _freeFocus.dispose();
    _sample.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_generating || _problem != null) return;
    await _audition.stop();
    setState(() {
      _generating = true;
      _failure = null;
    });
    try {
      final previous = _draft;
      if (previous != null) {
        await widget.voices.delete(previous);
        if (mounted) setState(() => _draft = null);
      }
      final operationId = _operationId ??= mintOperationId('design');
      final draft = await widget.voices.design(VoiceDesignBody(
        operationId: operationId,
        name: '${widget.companionName}的声音',
        prompt: _prompt,
        previewText: _sample.text.trim(),
      ));
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _operationId = null;
      });
    } catch (error) {
      if (mounted) setState(() => _failure = voiceFailure(error));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _keep() async {
    final draft = _draft;
    if (draft == null || _saving) return;
    final name = await askVoiceName(context,
        title: '保存为我的声音', initial: '${widget.companionName}的声音');
    if (name == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final kept = await widget.voices.change(
          draft.voiceAssetId,
          OwnerVoiceChange(
              expectedRevision: draft.revision, keep: true, name: name));
      if (!mounted) return;
      _draft = null;
      Navigator.of(context).pop(kept);
    } catch (error) {
      if (mounted) setState(() => _failure = voiceFailure(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    final draft = _draft;
    if (draft == null) return;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('不保存这个声音？'),
        content: const Text('未保存的声音会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑')),
          FilledButton(
              key: const Key('voice-design-discard'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除并离开')),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    _draft = null;
    // Best effort: a draft nobody keeps is deleted by the Host within a day.
    unawaited(widget.voices.delete(draft).catchError((Object _) {}));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _generating || _saving;
    final problem = _problem;
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: _draft == null && !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !busy) unawaited(_leave());
      },
      child: Scaffold(
        key: const Key('voice-design-page'),
        appBar: AppBar(title: const Text('用文字设计一个声音')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text('1  描述这个声音', style: text.titleMedium),
            const SizedBox(height: 4),
            const Text('描述声音的特征，不要写模仿某个名人。'),
            for (final (dimension, choices) in _dimensions) ...[
              const SizedBox(height: 8),
              Text(dimension, style: text.labelLarge),
              Wrap(spacing: 8, children: [
                for (final choice in choices)
                  ChoiceChip(
                    label: Text(choice),
                    selected: _picked[dimension] == choice,
                    onSelected: busy
                        ? null
                        : (on) {
                            if (on) {
                              _picked[dimension] = choice;
                            } else {
                              _picked.remove(dimension);
                            }
                            _changed();
                          },
                  ),
              ]),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('voice-design-prompt'),
              controller: _free,
              focusNode: _freeFocus,
              enabled: !busy,
              minLines: 2,
              maxLines: 5,
              onChanged: (_) => _changed(),
              decoration: InputDecoration(
                labelText: '再多说一点（可选）',
                helperText: '描述共 ${_prompt.length}/$_promptMax 字',
                border: const OutlineInputBorder(),
              ),
            ),
            Wrap(spacing: 8, children: [
              for (final example in _examples)
                ActionChip(
                  label: Text(example, overflow: TextOverflow.ellipsis),
                  onPressed: busy
                      ? null
                      : () {
                          _free.text = example;
                          _changed();
                        },
                ),
            ]),
            const SizedBox(height: 20),
            Text('2  试听时说的话', style: text.titleMedium),
            const SizedBox(height: 8),
            TextField(
              key: const Key('voice-design-sample'),
              controller: _sample,
              enabled: !busy,
              minLines: 2,
              maxLines: 4,
              maxLength: _sampleMax,
              onChanged: (_) => _changed(),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Text('3  生成', style: text.titleMedium),
            const SizedBox(height: 8),
            if (_draft case final draft?)
              Card(
                key: const Key('voice-design-draft'),
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.graphic_eq),
                    title: const Text('已经生成，先听听看'),
                    subtitle: const Text('没保存的声音 24 小时后会自动删除'),
                    trailing: AuditionButton(
                        audition: _audition, voiceKey: draft.voiceKey),
                  ),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: 4,
                    children: [
                      TextButton(
                          onPressed:
                              busy ? null : () => _freeFocus.requestFocus(),
                          child: const Text('改描述')),
                      TextButton(
                          key: const Key('voice-design-again'),
                          onPressed: busy ? null : _generate,
                          child: const Text('换一个')),
                      FilledButton(
                          key: const Key('voice-design-keep'),
                          onPressed: busy ? null : _keep,
                          child: const Text('保存为我的声音')),
                    ],
                  ),
                ]),
              )
            else
              FilledButton.icon(
                key: const Key('voice-design-generate'),
                onPressed: busy || problem != null ? null : _generate,
                icon: _generating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(_generating ? '正在生成…' : '生成'),
              ),
            if (_draft == null && problem != null && !busy)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(problem, style: text.bodySmall),
              ),
            if (_failure case final failure?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(failure,
                    key: const Key('voice-design-failure'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}
