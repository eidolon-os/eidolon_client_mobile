import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'conversations_page.dart';
import 'management_client.dart';
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

  Future<void> _open(ConversationView conversation) => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _TranscriptScreen(
            conversationId: conversation.conversationId,
            title: conversation.title ?? '',
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
        onLoadMore:
            _busy || _cursor == null ? null : () => _read(cursor: _cursor),
      );
    }
    return Scaffold(
      key: const Key('conversations-screen'),
      appBar: AppBar(title: const Text('说过的话')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('conversations-loading'))
            : Padding(
                key: const Key('conversations-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Never an empty list on failure: "we have not talked" and
                    // "I could not ask" are different things to be told.
                    Text('$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('conversations-retry'),
                      onPressed: () => _read(),
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _TranscriptScreen extends StatefulWidget {
  const _TranscriptScreen({
    required this.conversationId,
    required this.title,
    required this.load,
  });

  final String conversationId;
  final String title;
  final Future<TranscriptView> Function(String conversationId, String? cursor) load;

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
        title: widget.title,
        busy: _busy,
        onLoadEarlier: _cursor == null ? null : () => _read(cursor: _cursor),
      );
    }
    return Scaffold(
      key: const Key('transcript-screen'),
      appBar: AppBar(title: const Text('那次说了什么')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('transcript-loading'))
            : Padding(
                key: const Key('transcript-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException).statusCode == 404
                          // The conversation is gone, or was never this Owner's.
                          // Both arrive as the same answer on purpose.
                          ? '找不到这次对话了'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('transcript-retry'),
                      onPressed: () => _read(),
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
