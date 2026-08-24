import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// 那次说了什么 — one conversation, as it was said.
///
/// Read forward, which is the one thing this page reverses: the Host answers
/// newest turn first because "看更早的" is the gesture, and a person reads a
/// conversation from its beginning. So each page is flipped for display and the
/// button adds older turns above.
///
/// What it shows is what was said and nothing about how the answer was reached —
/// the Host does not send tool traffic — so there is no place here where a
/// screen has to decide what counts as the conversation.
class TranscriptPage extends StatelessWidget {
  const TranscriptPage({
    super.key,
    required this.turns,
    this.title,
    this.onLoadEarlier,
    this.busy = false,
  });

  /// Oldest first: the caller reverses what the Host sent and accumulates pages.
  final List<TranscriptTurnView> turns;

  final String? title;

  /// Non-null while the Host says there are earlier turns.
  final VoidCallback? onLoadEarlier;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('transcript-page'),
      appBar: AppBar(title: Text((title ?? '').isEmpty ? '那次说了什么' : title!)),
      body: turns.isEmpty
          ? const Center(
              key: Key('transcript-empty'),
              child: Padding(
                padding: EdgeInsets.all(24),
                // A conversation someone opened and said nothing in is a real
                // state, not a fault.
                child: Text('这次没有说什么'),
              ),
            )
          : ListView(
              key: const Key('transcript-list'),
              padding: const EdgeInsets.all(16),
              children: [
                if (onLoadEarlier != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: OutlinedButton(
                      key: const Key('transcript-load-earlier'),
                      onPressed: busy ? null : onLoadEarlier,
                      child: const Text('看更早的'),
                    ),
                  ),
                for (final turn in turns) ..._turn(context, turn),
              ],
            ),
    );
  }

  List<Widget> _turn(BuildContext context, TranscriptTurnView turn) => [
        for (final message in turn.messages)
          Align(
            key: Key('message-${turn.turnId}-${turn.messages.indexOf(message)}'),
            alignment: message.role == 'user'
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              decoration: BoxDecoration(
                color: message.role == 'user'
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(message.text ?? ''),
            ),
          ),
        // Said once per turn rather than per message, and only when it is true:
        // a turn with no end is what a dropped connection looks like afterwards,
        // and it is worth seeing rather than smoothing over.
        if (turn.finishedAt == null)
          Padding(
            key: Key('turn-unfinished-${turn.turnId}'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '这一轮没有说完',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ];
}
