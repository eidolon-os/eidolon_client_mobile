import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'conversation_history_page.dart';
import 'refusal_notice.dart';

/// Loads a Companion's words as one timeline while keeping Host conversation
/// boundaries private to pagination and authorization.
class ConversationHistoryScreen extends StatefulWidget {
  const ConversationHistoryScreen({
    super.key,
    required this.loadConversations,
    required this.loadTranscript,
  });

  final Future<ConversationPageView> Function(String? cursor) loadConversations;
  final Future<TranscriptView> Function(String conversationId, String? cursor)
      loadTranscript;

  @override
  State<ConversationHistoryScreen> createState() =>
      _ConversationHistoryScreenState();
}

class _ConversationHistoryScreenState extends State<ConversationHistoryScreen> {
  final List<ConversationView> _waitingConversations = [];
  final List<TranscriptTurnView> _turns = [];
  final Set<String> _seenConversationIds = {};
  final Set<String> _seenTurnIds = {};

  String? _conversationCursor;
  String? _activeConversationId;
  String? _turnCursor;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _initialRead();
  }

  Future<void> _initialRead() async {
    _waitingConversations.clear();
    _turns.clear();
    _seenConversationIds.clear();
    _seenTurnIds.clear();
    _conversationCursor = null;
    _activeConversationId = null;
    _turnCursor = null;
    try {
      await _readConversationPage(null);
      await _advanceToEarlierConversation();
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  Future<void> _readConversationPage(String? cursor) async {
    final page = await widget.loadConversations(cursor);
    for (final conversation in page.conversations) {
      if (_seenConversationIds.add(conversation.conversationId)) {
        _waitingConversations.add(conversation);
      }
    }
    _conversationCursor = page.nextCursor;
  }

  /// Select the next internal conversation and keep going past empty ones.
  Future<bool> _advanceToEarlierConversation() async {
    while (true) {
      if (_waitingConversations.isEmpty && _conversationCursor != null) {
        await _readConversationPage(_conversationCursor);
      }
      if (_waitingConversations.isEmpty) {
        _activeConversationId = null;
        _turnCursor = null;
        return false;
      }

      final conversation = _waitingConversations.removeAt(0);
      _activeConversationId = conversation.conversationId;
      final transcript = await widget.loadTranscript(
        conversation.conversationId,
        null,
      );
      _turnCursor = transcript.nextCursor;
      final added = _merge(transcript.turns);
      if (added || _turnCursor != null) return true;
    }
  }

  Future<void> _readEarlier() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_activeConversationId != null && _turnCursor != null) {
        final transcript = await widget.loadTranscript(
          _activeConversationId!,
          _turnCursor,
        );
        _turnCursor = transcript.nextCursor;
        _merge(transcript.turns);
      } else {
        await _advanceToEarlierConversation();
      }
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
      if (_turns.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时没能读到更早的记录，请稍后再试')));
      }
    }
  }

  bool _merge(List<TranscriptTurnView> incoming) {
    var added = false;
    for (final turn in incoming) {
      if (_seenTurnIds.add(turn.turnId)) {
        _turns.add(turn);
        added = true;
      }
    }
    _turns.sort(
      (left, right) =>
          _moment(left.startedAt).compareTo(_moment(right.startedAt)),
    );
    return added;
  }

  bool get _hasEarlier =>
      _turnCursor != null ||
      _waitingConversations.isNotEmpty ||
      _conversationCursor != null;

  @override
  Widget build(BuildContext context) {
    if (_turns.isNotEmpty || (!_busy && _error == null)) {
      return ConversationHistoryPage(
        turns: _turns,
        busy: _busy,
        onLoadEarlier: _hasEarlier ? _readEarlier : null,
      );
    }
    return Scaffold(
      key: const Key('conversation-history-screen'),
      appBar: AppBar(title: const Text('对话记录')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(
                key: Key('conversation-history-loading'),
              )
            : RefusalNotice(
                key: const Key('conversation-history-error'),
                error: _error!,
                subject: '对话记录',
                onRetry: () {
                  setState(() {
                    _busy = true;
                    _error = null;
                  });
                  _initialRead();
                },
                retryKey: const Key('conversation-history-retry'),
              ),
      ),
    );
  }
}

DateTime _moment(String? value) =>
    DateTime.tryParse(value ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
