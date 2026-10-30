import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../models/when.dart';
import '../host_setup/voice_recording_player.dart';
import 'speech_voice_repository.dart';
import 'speech_voice_wording.dart';
import 'voice_audition.dart';

/// One of the Owner's own voices: what it is, who uses it, and the three things
/// a person can do to it — rename it, drop the recording it was made from, or
/// delete it (§17.9 D).
class OwnerVoicePage extends StatefulWidget {
  const OwnerVoicePage({
    super.key,
    required this.voice,
    required this.voices,
    this.companionNames = const {},
    this.playerFactory,
  });

  final OwnerVoiceView voice;
  final SpeechVoices voices;
  final Map<String, String> companionNames;
  final VoiceRecordingPlayer Function()? playerFactory;

  @override
  State<OwnerVoicePage> createState() => _OwnerVoicePageState();
}

class _OwnerVoicePageState extends State<OwnerVoicePage> {
  late OwnerVoiceView _voice = widget.voice;
  late final VoiceAudition _audition = VoiceAudition(
      load: widget.voices.preview, player: widget.playerFactory?.call());
  bool _busy = false;

  @override
  void dispose() {
    _audition.dispose();
    super.dispose();
  }

  List<String> get _users => [
        for (final id in _voice.usedBy) widget.companionNames[id] ?? '一位伙伴',
      ];

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(voiceFailure(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final name =
        await askVoiceName(context, title: '给这个声音改个名字', initial: _voice.name);
    if (name == null || name == _voice.name) return;
    await _act(() async {
      final changed = await widget.voices.change(_voice.voiceAssetId,
          OwnerVoiceChange(expectedRevision: _voice.revision, name: name));
      if (mounted) setState(() => _voice = changed);
    });
  }

  Future<void> _dropRecording() async {
    final sure = await _confirm(
      title: '删除原始录音？',
      body: '声音本身还能继续用。只是以后这台主机更换语音服务时，没法再用这段录音自动重新生成它，需要重新录。',
      action: '删除录音',
    );
    if (!sure) return;
    await _act(() async {
      final changed = await widget.voices.change(
          _voice.voiceAssetId,
          OwnerVoiceChange(
              expectedRevision: _voice.revision, dropReference: true));
      if (mounted) setState(() => _voice = changed);
    });
  }

  Future<void> _delete() async {
    final users = _users;
    final sure = await _confirm(
      title: '删除「${_voice.name}」？',
      body: users.isEmpty
          ? '删除后不能恢复。'
          : '${users.join('、')}正在用它，删除后会改用主机默认的声音。删除后不能恢复。',
      action: '删除',
    );
    if (!sure) return;
    await _act(() async {
      await widget.voices.delete(_voice);
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<bool> _confirm(
      {required String title,
      required String body,
      required String action}) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              key: const Key('owner-voice-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action)),
        ],
      ),
    );
    return sure == true;
  }

  @override
  Widget build(BuildContext context) {
    final voice = _voice;
    final consent = voice.consent;
    final users = _users;
    return Scaffold(
      key: const Key('owner-voice-page'),
      appBar: AppBar(title: Text(voice.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          Card(
            child: Column(children: [
              ListTile(
                title: Text(voice.name),
                subtitle: Text(
                    '${voiceMethod(voice.method)} · ${ownerVoiceStatus(voice)}'),
                trailing: voice.status == 'ready'
                    ? AuditionButton(
                        audition: _audition, voiceKey: voice.voiceKey)
                    : null,
              ),
              if (voice.status == 'rejected' && voice.statusDetail != null)
                ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(voice.statusDetail!)),
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('创建时间'),
                subtitle: Text(formatWhen(parseInstant(voice.createdAt))),
              ),
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: const Text('谁在用'),
                subtitle: Text(users.isEmpty ? '还没有伙伴在用' : users.join('、')),
              ),
              if (voice.designPrompt case final prompt?)
                ListTile(
                  leading: const Icon(Icons.edit_note_outlined),
                  title: const Text('描述'),
                  subtitle: Text(prompt),
                ),
              if (consent != null)
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('录音人同意'),
                  subtitle: Text(
                      '${consent.subject == 'self' ? '我自己' : consent.subjectLabel ?? '家人或朋友'}'
                      ' · ${formatWhen(parseInstant(consent.acceptedAt))}'),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              ListTile(
                key: const Key('owner-voice-rename'),
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('改名'),
                onTap: _busy ? null : _rename,
              ),
              // A person's recording, kept to remake the voice elsewhere. A
              // designed voice's passage is the Host's own and is not offered.
              if (voice.method == 'clone' && voice.hasReference)
                ListTile(
                  key: const Key('owner-voice-drop-reference'),
                  leading: const Icon(Icons.mic_off_outlined),
                  title: const Text('删除原始录音'),
                  subtitle: const Text('以后更换语音服务时就不能自动重新生成'),
                  onTap: _busy ? null : _dropRecording,
                ),
              ListTile(
                key: const Key('owner-voice-delete'),
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error),
                title: Text('删除这个声音',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: _busy ? null : _delete,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// A name for a voice: asked when saving one and when renaming it.
Future<String?> askVoiceName(BuildContext context,
    {required String title, required String initial}) async {
  final name = await showDialog<String>(
      context: context,
      builder: (_) => _VoiceNameDialog(title: title, initial: initial));
  return name == null || name.isEmpty ? null : name;
}

/// Owns its field, so the field outlives the dialog's closing animation.
class _VoiceNameDialog extends StatefulWidget {
  const _VoiceNameDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_VoiceNameDialog> createState() => _VoiceNameDialogState();
}

class _VoiceNameDialogState extends State<_VoiceNameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const Key('voice-name-field'),
          controller: _name,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: '名字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              key: const Key('voice-name-save'),
              onPressed: () => Navigator.pop(context, _name.text.trim()),
              child: const Text('保存')),
        ],
      );
}
