import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// 对话历史 — when this Eidolon and I talked.
///
/// A list of occasions, not a search and not a feed. Each row is a time and, if
/// anything named it, a title — the words are behind it, one conversation at a
/// time, because a page of transcripts is every word anyone ever said to a Host.
///
/// What the page must not do is imply it holds the conversation. A row with a
/// timestamp and nothing else reads like a broken transcript; a row that says
/// "打开看说了什么" reads like what it is.
class ConversationsPage extends StatelessWidget {
  const ConversationsPage({
    super.key,
    required this.conversations,
    this.onOpen,
    this.onLoadMore,
  });

  /// The occasions this screen has accumulated, newest first as the Host answers.
  ///
  /// A plain list rather than the wire page: assembling a contract type to carry
  /// screen state would make the generated model a view model, and the two have
  /// different reasons to change.
  final List<ConversationView> conversations;

  /// Null leaves rows unopenable rather than opening a screen that cannot fill
  /// itself.
  final void Function(ConversationView conversation)? onOpen;

  /// Non-null when the Host said there is another page.
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('conversations-page'),
      appBar: AppBar(title: const Text('对话历史')),
      body: conversations.isEmpty
          ? const Center(
              key: Key('conversations-empty'),
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有说过话'),
              ),
            )
          : ListView.separated(
              key: const Key('conversations-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: conversations.length + (onLoadMore == null ? 0 : 1),
              separatorBuilder: (_, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == conversations.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      key: const Key('conversations-load-more'),
                      onPressed: onLoadMore,
                      child: const Text('看更早的'),
                    ),
                  );
                }
                final conversation = conversations[index];
                return ListTile(
                  key: Key('conversation-${conversation.conversationId}'),
                  title: Text(
                    (conversation.title ?? '').isEmpty
                        // Nothing named it, and this page does not name it
                        // either: a title invented here would be a screen
                        // summarising someone's conversation for them.
                        ? '没有标题的一次'
                        : conversation.title!,
                  ),
                  subtitle: Text(_when(conversation)),
                  trailing: onOpen == null
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: onOpen == null ? null : () => onOpen!(conversation),
                );
              },
            ),
    );
  }
}

/// When it happened, and whether it is over.
///
/// An open conversation says so rather than showing its last-updated time as if
/// it were an ending — "还在继续" is the difference between a record and a thing
/// that is still happening.
String _when(ConversationView conversation) {
  final started = _moment(conversation.startedAt);
  final ended = _moment(conversation.endedAt);
  final label = started == null
      ? (conversation.startedAt ?? '')
      : _stamp(started);
  return ended == null ? '$label · 还在继续' : label;
}

DateTime? _moment(String? value) =>
    value == null || value.isEmpty ? null : DateTime.tryParse(value);

String _stamp(DateTime moment) {
  final local = moment.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
