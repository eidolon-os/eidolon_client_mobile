import 'dart:async';

import 'package:flutter/material.dart';

import 'speech_voice_repository.dart';
import 'speech_voice_wording.dart';

/// 「声音」 on an Eidolon's page, saying which voice it will use next time.
///
/// Reads its own line, and again after the voice page closes, so the sentence
/// under it is always the Host's latest answer rather than one the page that
/// holds it would have to remember to refresh.
class SpeechVoiceTile extends StatefulWidget {
  const SpeechVoiceTile({
    super.key,
    required this.companionId,
    required this.voices,
    required this.onOpen,
  });

  final String companionId;
  final SpeechVoices voices;
  final Future<void> Function() onOpen;

  @override
  State<SpeechVoiceTile> createState() => _SpeechVoiceTileState();
}

class _SpeechVoiceTileState extends State<SpeechVoiceTile> {
  String? _line;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final current = await widget.voices.companionVoice(widget.companionId);
      // The catalog only matters to say why a Host offers no choice.
      final catalog = current.effective?.reason == 'host_fixed_voice'
          ? await widget.voices.catalog()
          : null;
      if (mounted) {
        setState(() => _line = voiceLine(current, catalog: catalog));
      }
    } catch (_) {
      // The row still opens; the page says what went wrong.
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
        key: const Key('companion-voice'),
        leading: const Icon(Icons.record_voice_over_outlined),
        title: const Text('声音'),
        subtitle: Text(_line ?? '选择它说话的声音，或用你自己做的声音'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await widget.onOpen();
          await _read();
        },
      );
}
