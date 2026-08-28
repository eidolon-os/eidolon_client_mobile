import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'conversations_page.dart';
import 'refusal_notice.dart';
import 'transcript_page.dart';

/// Loads the occasions, and opens one.
///
/// Two loads with different shapes, which is why they are one screen rather than
/// two: the list accumulates pages downwards (older occasions), and a transcript
/// accumulates upwards (earlier turns, reversed for reading). Holding both here
/// keeps each page a pure function of what the Host said.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({
    super.key,
    required this.load,
    this.loadTranscript,
  });

  final Future<ConversationPageView> Function(String? cursor) load;

  /// Null leaves rows unopenable rather than opening an empty transcript.
  final Future<TranscriptView> Function(String conversationId, String? cursor)?
  loadTranscript;

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  final List<ConversationView> _conversations = [];
  String? _cursor;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read({String? cursor}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.load(cursor);
      if (!mounted) return;
      setState(() {
        if (cursor == null) _conversations.clear();
        _conversations.addAll(page.conversations);
        _cursor = page.nextCursor;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  Future<void> _open(ConversationView conversation) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _TranscriptScreen(
            conversationId: conversation.conversationId,
            heading: conversationTimeLabel(conversation),
            load: widget.loadTranscript!,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_conversations.isNotEmpty || (!_busy && _error == null)) {
      return ConversationsPage(
        conversations: _conversations,
        onOpen: widget.loadTranscript == null ? null : _open,
        onLoadMore: _busy || _cursor == null
            ? null
            : () => _read(cursor: _cursor),
      );
    }
    return Scaffold(
      key: const Key('conversations-screen'),
      appBar: AppBar(title: const Text('对话历史')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('conversations-loading'))
            : RefusalNotice(
                key: const Key('conversations-error'),
                error: _error!,
                subject: '对话记录',
                onRetry: () => _read(),
                retryKey: const Key('conversations-retry'),
              ),
      ),
    );
  }
}

class _TranscriptScreen extends StatefulWidget {
  const _TranscriptScreen({
    required this.conversationId,
    required this.heading,
    required this.load,
  });

  final String conversationId;
  final String heading;
  final Future<TranscriptView> Function(String conversationId, String? cursor)
  load;

  @override
  State<_TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends State<_TranscriptScreen> {
  /// Oldest first, which is the order a conversation is read in. The Host answers
  /// newest first because "看更早的" is the gesture, so each page is reversed
  /// before it is put in front of this one.
  final List<TranscriptTurnView> _turns = [];
  String? _cursor;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read({String? cursor}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.load(widget.conversationId, cursor);
      if (!mounted) return;
      setState(() {
        _turns.insertAll(0, page.turns.reversed);
        _cursor = page.nextCursor;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_turns.isNotEmpty || (!_busy && _error == null)) {
      return TranscriptPage(
        turns: _turns,
        title: widget.heading,
        busy: _busy,
        onLoadEarlier: _cursor == null ? null : () => _read(cursor: _cursor),
      );
    }
    return Scaffold(
      key: const Key('transcript-screen'),
      // Loading, content and refusal are three states of the same occasion;
      // changing its heading when a read fails would make the error look like
      // a different destination.
      appBar: AppBar(title: Text(widget.heading)),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('transcript-loading'))
            : RefusalNotice(
                key: const Key('transcript-error'),
                error: _error!,
                subject: '这次对话',
                onRetry: () => _read(),
                retryKey: const Key('transcript-retry'),
              ),
      ),
    );
  }
}
