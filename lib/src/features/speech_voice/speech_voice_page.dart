import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../host_setup/voice_recording_player.dart';
import 'owner_voice_page.dart';
import 'speech_voice_repository.dart';
import 'speech_voice_wording.dart';
import 'voice_audition.dart';
import 'voice_clone_page.dart';
import 'voice_design_page.dart';
import 'voice_reference_sources.dart';

/// How one Eidolon sounds: the voice it will use next time and why, the Host's
/// voices to choose from, and the Owner's own voices (§10, §17.9).
///
/// What it says about the voice in use is the Host's resolution, the same one
/// the voice worker runs at the start of a conversation — never worked out here.
class SpeechVoicePage extends StatefulWidget {
  const SpeechVoicePage({
    super.key,
    required this.companionId,
    required this.companionName,
    required this.voices,
    this.companionNames = const {},
    this.playerFactory,
    this.recorderFactory,
    this.filePicker,
  });

  final String companionId;
  final String companionName;
  final SpeechVoices voices;

  /// Who else is on this Host, to say which Eidolons use a voice.
  final Map<String, String> companionNames;
  final VoiceRecordingPlayer Function()? playerFactory;
  final ReferenceRecorder Function()? recorderFactory;
  final AudioFilePicker? filePicker;

  @override
  State<SpeechVoicePage> createState() => _SpeechVoicePageState();
}

class _SpeechVoicePageState extends State<SpeechVoicePage> {
  late final VoiceAudition _audition = VoiceAudition(
      load: widget.voices.preview, player: widget.playerFactory?.call());
  CompanionSpeechVoiceView? _current;
  SpeechVoiceCatalogView? _catalog;
  List<OwnerVoiceView> _mine = const [];
  String? _failure;
  bool _loading = true, _saving = false;
  bool _showMine = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _audition.dispose();
    super.dispose();
  }

  /// The catalog and the Owner's voices are worth showing without each other;
  /// only the Companion's own voice is required to draw the page.
  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = _current == null;
      _failure = null;
    });
    final voices = widget.voices;
    final catalog = (refresh ? voices.refresh() : voices.catalog())
        .then<SpeechVoiceCatalogView?>((value) => value,
            onError: (Object _) => null);
    final mine = voices.ownerVoices().then<List<OwnerVoiceView>?>(
        (value) => value,
        onError: (Object _) => null);
    try {
      final current = await voices.companionVoice(widget.companionId);
      final results = (await catalog, await mine);
      if (!mounted) return;
      setState(() {
        _current = current;
        _catalog = results.$1;
        _mine = (results.$2 ?? _mine)
            .where((voice) => voice.state == 'active')
            .toList(growable: false);
      });
    } catch (error) {
      if (mounted) setState(() => _failure = voiceFailure(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _choose(String? voiceKey) async {
    final current = _current;
    if (current == null || _saving || voiceKey == current.selectedVoiceKey) {
      return;
    }
    setState(() => _saving = true);
    try {
      final chosen = await widget.voices
          .choose(widget.companionId, voiceKey, current.revision);
      if (!mounted) return;
      setState(() => _current = chosen);
      _say('下次和${widget.companionName}对话时生效');
    } on ManagementRequestException catch (error) {
      if (error.someoneElseChangedIt) {
        await _load();
        _say('这个伙伴的声音刚被改过，已经重新读取');
      } else {
        _say(voiceFailure(error));
      }
    } catch (error) {
      _say(voiceFailure(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _create() async {
    final catalog = _catalog;
    final enrollment = catalog?.enrollment;
    final limit = catalog?.limits.ownerVoices;
    final full = limit != null && _mine.length >= limit;
    String? held(bool supported) => full
        ? '已经有 $limit 个声音，删掉一个再创建'
        : supported
            ? null
            : '这台主机的语音服务不支持';
    final designHeld = held(enrollment?.design == true);
    final cloneHeld = held(enrollment?.clone == true);
    final way = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('voice-create-design'),
            leading: const Icon(Icons.edit_note_outlined),
            title: const Text('用文字设计一个声音'),
            subtitle: Text(designHeld ?? '描述你想要的声音，生成后先试听再保存'),
            enabled: designHeld == null,
            onTap: () => Navigator.pop(context, 'design'),
          ),
          ListTile(
            key: const Key('voice-create-clone'),
            leading: const Icon(Icons.mic_none_outlined),
            title: const Text('用录音复刻一个声音'),
            subtitle: Text(cloneHeld ?? '录一段话或选一个音频文件，生成一样的声音'),
            enabled: cloneHeld == null,
            onTap: () => Navigator.pop(context, 'clone'),
          ),
        ]),
      ),
    );
    if (!mounted || way == null || catalog == null) return;
    final made = await Navigator.of(context).push<OwnerVoiceView>(
      MaterialPageRoute(
        builder: (_) => way == 'design'
            ? VoiceDesignPage(
                companionName: widget.companionName,
                voices: widget.voices,
                limits: catalog.limits,
                playerFactory: widget.playerFactory)
            : VoiceClonePage(
                voices: widget.voices,
                limits: catalog.limits,
                processor: catalog.enrollment.processor,
                playerFactory: widget.playerFactory,
                recorderFactory: widget.recorderFactory,
                filePicker: widget.filePicker),
      ),
    );
    await _load();
    if (made == null || !mounted) return;
    setState(() => _showMine = true);
    final ready = made.status == 'ready';
    final use = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('现在给${widget.companionName}用这个声音吗？'),
        content: Text(ready
            ? '「${made.name}」已经可以用了。'
            : '「${made.name}」还在准备，准备好之前${widget.companionName}会先用主机默认的声音。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('先不用')),
          FilledButton(
              key: const Key('voice-use-new'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('使用')),
        ],
      ),
    );
    if (use == true) await _choose(made.voiceKey);
  }

  Future<void> _openOwnerVoice(OwnerVoiceView voice) async {
    await _audition.stop();
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => OwnerVoicePage(
            voice: voice,
            voices: widget.voices,
            companionNames: widget.companionNames,
            playerFactory: widget.playerFactory)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      key: const Key('speech-voice-page'),
      appBar: AppBar(title: Text('${widget.companionName}的声音')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : current == null
              ? _Unreadable(failure: _failure, retry: _load)
              : RefreshIndicator(
                  onRefresh: () => _load(refresh: true),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (_saving) const LinearProgressIndicator(),
                      _Head(
                          current: current,
                          catalog: _catalog,
                          audition: _audition),
                      ..._notices(current),
                      const SizedBox(height: 12),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('系统声音')),
                          ButtonSegment(value: true, label: Text('我的声音')),
                        ],
                        selected: {_showMine},
                        onSelectionChanged: (value) =>
                            setState(() => _showMine = value.single),
                      ),
                      const SizedBox(height: 8),
                      if (_showMine)
                        ..._mineList(current)
                      else
                        ..._systemList(current),
                    ],
                  ),
                ),
    );
  }

  /// What the person should know before choosing: a voice standing in for the
  /// one chosen, or a list that cannot be fully trusted right now.
  List<Widget> _notices(CompanionSpeechVoiceView current) {
    final notices = <Widget>[];
    final effective = current.effective;
    final chosen = current.selectedName;
    if (effective != null && chosen != null) {
      if (effective.reason == 'mapped') {
        notices.add(_Notice(
          key: const Key('voice-mapped'),
          text: '你选的「$chosen」在这台主机上不可用，正在用相近的「${effective.displayName}」。',
          action: effective.voiceKey == null
              ? null
              : TextButton(
                  onPressed: () => _choose(effective.voiceKey),
                  child: Text('就用${effective.displayName}')),
        ));
      } else if (effective.reason == 'no_equivalent') {
        notices.add(_Notice(
            key: const Key('voice-no-equivalent'),
            text: '你选的「$chosen」在这台主机上不可用，也没有相近的声音，正在用主机默认。可以重新选一个。'));
      }
    }
    final catalog = _catalog;
    if (catalog == null || catalog.state == 'degraded') {
      notices.add(_Notice(
        key: const Key('voice-catalog-unavailable'),
        text: '暂时拿不到声音列表，现在只能用主机默认。',
        action: TextButton(
            onPressed: () => _load(refresh: true), child: const Text('重试')),
      ));
    } else if (catalog.state == 'stale') {
      notices.add(const _Notice(
          key: Key('voice-catalog-stale'), text: '列表可能不是最新，下拉可以刷新。'));
    }
    return notices;
  }

  List<Widget> _systemList(CompanionSpeechVoiceView current) {
    final catalog = _catalog;
    final options = catalog?.voices ?? const <VoiceOptionView>[];
    final fallback = options.where((voice) => voice.isHostDefault).firstOrNull;
    final followsHost = current.selectedVoiceKey == null ||
        current.selectedVoiceKey == fallback?.voiceKey;
    final tiles = <Widget>[
      Card(
        child: ListTile(
          key: const Key('voice-host-default'),
          leading: _Mark(followsHost),
          title: Text(
              fallback == null ? '主机默认' : '主机默认 · ${fallback.displayName}'),
          subtitle: Text(fallback?.summary ?? '这台主机自己配置的声音'),
          trailing: fallback == null
              ? null
              : AuditionButton(
                  audition: _audition, voiceKey: fallback.voiceKey),
          onTap: _saving ? null : () => _choose(null),
        ),
      ),
    ];
    if (catalog != null && !catalog.hostSelectable) {
      tiles.add(Padding(
        padding: const EdgeInsets.all(12),
        child: Text(catalog.notSelectableReason == 'single_voice'
            ? '这台主机目前只有一个可用的声音。'
            : '这台主机暂不支持更换声音。'),
      ));
      return tiles;
    }
    for (final shelf in voiceShelves) {
      final onShelf = options
          .where((voice) => !voice.isHostDefault && voiceShelf(voice) == shelf)
          .toList(growable: false);
      if (onShelf.isEmpty) continue;
      tiles.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(shelf, style: Theme.of(context).textTheme.titleSmall),
      ));
      tiles.add(Card(
        child: Column(children: [
          for (final voice in onShelf)
            ListTile(
              key: Key('voice-option-${voice.voiceKey}'),
              leading: _Mark(current.selectedVoiceKey == voice.voiceKey),
              title: Text(voice.displayName),
              subtitle: Text([
                if (voice.summary case final summary?) summary,
                if (voice.styleLabels.isNotEmpty) voice.styleLabels.join(' · '),
              ].join('\n')),
              isThreeLine:
                  voice.summary != null && voice.styleLabels.isNotEmpty,
              trailing:
                  AuditionButton(audition: _audition, voiceKey: voice.voiceKey),
              enabled: voice.selectable,
              onTap: _saving || !voice.selectable
                  ? null
                  : () => _choose(voice.voiceKey),
            ),
        ]),
      ));
    }
    return tiles;
  }

  List<Widget> _mineList(CompanionSpeechVoiceView current) => [
        if (_mine.isEmpty)
          const Padding(
            key: Key('owner-voices-empty'),
            padding: EdgeInsets.all(16),
            child: Text('还没有你自己的声音。可以用一段文字描述设计一个，'
                '也可以用一段录音复刻一个，比如你自己或家人的声音。'),
          )
        else
          Card(
            child: Column(children: [
              for (final voice in _mine)
                ListTile(
                  key: Key('owner-voice-${voice.voiceAssetId}'),
                  leading: _Mark(current.selectedVoiceKey == voice.voiceKey),
                  title: Text(voice.name),
                  subtitle: Text([
                    '${voiceMethod(voice.method)} · ${ownerVoiceStatus(voice)}',
                    if (usedByLine(voice) case final line?) line,
                  ].join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (voice.status == 'ready')
                      AuditionButton(
                          audition: _audition, voiceKey: voice.voiceKey),
                    IconButton(
                      key: Key('owner-voice-more-${voice.voiceAssetId}'),
                      tooltip: '详情',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () => _openOwnerVoice(voice),
                    ),
                  ]),
                  onTap: _saving ? null : () => _choose(voice.voiceKey),
                ),
            ]),
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('voice-create'),
          onPressed: _catalog == null ? null : _create,
          icon: const Icon(Icons.add),
          label: const Text('创建新声音'),
        ),
      ];
}

class _Head extends StatelessWidget {
  const _Head(
      {required this.current, required this.catalog, required this.audition});
  final CompanionSpeechVoiceView current;
  final SpeechVoiceCatalogView? catalog;
  final VoiceAudition audition;

  @override
  Widget build(BuildContext context) {
    final effective = current.effective;
    final line = voiceLine(current, catalog: catalog);
    return Card(
      key: const Key('voice-head'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(children: [
          const Icon(Icons.record_voice_over_outlined, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('下次对话会用', style: Theme.of(context).textTheme.labelMedium),
              Text(effective?.displayName ?? '暂时确认不了',
                  style: Theme.of(context).textTheme.titleLarge),
              if (effective != null)
                Text(
                    '${voiceSource(current)}${line == null ? '' : ' · $line'}'),
            ]),
          ),
          if (effective?.voiceKey case final key?)
            AuditionButton(audition: audition, voiceKey: key),
        ]),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text),
            Align(
                alignment: Alignment.centerRight,
                child: action ?? const SizedBox(height: 8)),
          ]),
        ),
      );
}

class _Mark extends StatelessWidget {
  const _Mark(this.chosen);
  final bool chosen;

  @override
  Widget build(BuildContext context) => Icon(
        chosen ? Icons.check_circle : Icons.radio_button_unchecked,
        color: chosen ? Theme.of(context).colorScheme.primary : null,
      );
}

class _Unreadable extends StatelessWidget {
  const _Unreadable({required this.failure, required this.retry});
  final String? failure;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(failure ?? '没能读到这个伙伴的声音设置', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ]),
        ),
      );
}
