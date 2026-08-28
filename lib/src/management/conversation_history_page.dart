import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// What this Companion and its Owner said, presented as one continuous record.
///
/// Conversation ids remain an authority and pagination boundary on the Host.
/// They are deliberately absent here: a transport context is not necessarily a
/// human idea of "one chat", especially for a standing physical device.
class ConversationHistoryPage extends StatelessWidget {
  const ConversationHistoryPage({
    super.key,
    required this.turns,
    this.onLoadEarlier,
    this.busy = false,
  });

  /// Oldest first, independent of which internal conversation owns each turn.
  final List<TranscriptTurnView> turns;
  final VoidCallback? onLoadEarlier;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('conversation-history-page'),
      appBar: AppBar(title: const Text('对话记录')),
      body: turns.isEmpty
          ? Center(
              key: const Key('conversation-history-empty'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('还没有说过话'),
                    if (onLoadEarlier != null) ...[
                      const SizedBox(height: 16),
                      _loadEarlierButton(),
                    ],
                  ],
                ),
              ),
            )
          : ListView(
              key: const Key('conversation-history-list'),
              padding: const EdgeInsets.all(16),
              children: [
                if (onLoadEarlier != null) _loadEarlierButton(),
                ..._timeline(context),
              ],
            ),
    );
  }

  Widget _loadEarlierButton() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: OutlinedButton(
          key: const Key('conversation-history-load-earlier'),
          onPressed: busy ? null : onLoadEarlier,
          child: Text(busy ? '正在读取…' : '继续看以前'),
        ),
      );

  List<Widget> _timeline(BuildContext context) {
    final children = <Widget>[];
    String? previousDay;
    for (final turn in turns) {
      final day = conversationDayLabel(turn.startedAt);
      if (day != null && day != previousDay) {
        children.add(
          Padding(
            key: Key('conversation-day-$day'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(day, style: Theme.of(context).textTheme.labelMedium),
            ),
          ),
        );
        previousDay = day;
      }
      children.addAll(_turn(context, turn));
    }
    return children;
  }

  List<Widget> _turn(BuildContext context, TranscriptTurnView turn) => [
        for (var index = 0; index < turn.messages.length; index += 1)
          Align(
            key: Key('history-message-${turn.turnId}-$index'),
            alignment: turn.messages[index].role == 'user'
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              decoration: BoxDecoration(
                color: turn.messages[index].role == 'user'
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(turn.messages[index].text ?? ''),
            ),
          ),
        // This is a real turn-level fact, unlike the former conversation-level
        // "还在继续", whose lifecycle had no producer.
        if (turn.finishedAt == null)
          Padding(
            key: Key('history-turn-unfinished-${turn.turnId}'),
            padding: const EdgeInsets.only(bottom: 12),
            child:
                Text('这一轮没有说完', style: Theme.of(context).textTheme.bodySmall),
          ),
      ];
}

String? conversationDayLabel(String? value) {
  if (value == null || value.isEmpty) return null;
  final moment = DateTime.tryParse(value)?.toLocal();
  if (moment == null) return null;
  return '${moment.year}年${moment.month}月${moment.day}日';
}
