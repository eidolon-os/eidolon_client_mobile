import 'dart:convert';
import 'package:flutter/material.dart';
import '../generated/management_v1.dart';

typedef PreviewPersona = Future<PersonaPreviewResponse> Function(
    PersonaPreviewRequest draft);

class PersonaPreviewPanel extends StatefulWidget {
  const PersonaPreviewPanel(
      {super.key, required this.draft, required this.preview});
  final PersonaPreviewRequest draft;
  final PreviewPersona preview;
  @override
  State<PersonaPreviewPanel> createState() => _PersonaPreviewPanelState();
}

class _PersonaPreviewPanelState extends State<PersonaPreviewPanel> {
  final _text = TextEditingController(text: '今天有点累。');
  int _generation = 0;
  bool _busy = false;
  String? _reply;
  String? _error;

  void _invalidate() {
    _generation++;
    _busy = false;
    _reply = null;
    _error = null;
  }

  @override
  void didUpdateWidget(covariant PersonaPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.draft.toJson()) !=
        jsonEncode(widget.draft.toJson())) {
      _invalidate();
    }
  }

  @override
  void dispose() {
    _generation++;
    _text.dispose();
    super.dispose();
  }

  Future<void> _try() async {
    final generation = ++_generation;
    final request = PersonaPreviewRequest.fromJson(
        {...widget.draft.toJson(), 'text': _text.text.trim()});
    setState(() {
      _busy = true;
      _error = null;
      _reply = null;
    });
    try {
      final result = await widget.preview(request);
      if (!mounted || generation != _generation) return;
      setState(() {
        _reply = result.reply;
        _error = result.truncated == true ? '回复未完整生成，可以再试一次。' : null;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = '试聊暂时不可用，可以重试或继续保存设定。');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('用当前设定试聊'),
        const Text('每次试聊独立进行，不保存记忆。'),
        TextField(
            key: const Key('persona-preview-input'),
            controller: _text,
            maxLength: 2000,
            onChanged: (_) => setState(_invalidate)),
        TextButton(
            onPressed: _busy || _text.text.trim().isEmpty ? null : _try,
            child: Text(_busy ? '正在回复…' : '试聊')),
        if (_reply != null)
          Text(_reply!, key: const Key('persona-preview-reply')),
        if (_error != null) Text(_error!),
      ]);
}
