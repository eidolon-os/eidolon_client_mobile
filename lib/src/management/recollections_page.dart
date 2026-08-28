import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// Ask one Eidolon what it remembers.
///
/// Search is a focused way into the same Owner-governed memory surface. It is
/// kept in management so both the overall Memory front door and a Companion
/// detail page can open it without either feature depending on the other.
class RecollectionsPage extends StatefulWidget {
  const RecollectionsPage({
    super.key,
    required this.companionName,
    required this.onSearch,
  });

  final String companionName;
  final Future<RecollectionsView> Function(String query) onSearch;

  @override
  State<RecollectionsPage> createState() => _RecollectionsPageState();
}

class _RecollectionsPageState extends State<RecollectionsPage> {
  final _question = TextEditingController();
  RecollectionsView? _answer;
  String? _failure;
  bool _asking = false;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final query = _question.text.trim();
    if (query.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _failure = null;
    });
    try {
      final answer = await widget.onSearch(query);
      if (mounted) setState(() => _answer = answer);
    } catch (error) {
      // A failed read is not an empty memory.
      if (mounted) setState(() => _failure = '没能问到：$error');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    return Scaffold(
      key: const Key('recollections-page'),
      appBar: AppBar(title: Text('搜索 ${widget.companionName} 的记忆')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            key: const Key('recollection-question'),
            controller: _question,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _ask(),
            decoration: InputDecoration(
              hintText: '比如「散步」「喜欢吃什么」',
              suffixIcon: IconButton(
                key: const Key('ask-recollections'),
                onPressed: _asking ? null : _ask,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_asking)
            const Center(
              key: Key('recollections-asking'),
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_failure case final failure?)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                key: const Key('recollections-failure'),
                leading: const Icon(Icons.error_outline),
                title: Text(failure),
              ),
            )
          else if (answer == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  '输入一件事，看看它是否记得。记忆内容只从你的主机读取。',
                  key: Key('recollections-idle'),
                ),
              ),
            )
          else if (answer.recollections.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  '关于「${answer.query}」，它还没有记住什么。',
                  key: const Key('recollections-empty'),
                ),
              ),
            )
          else
            ...answer.recollections.map(
              (item) => Card(
                child: ListTile(
                  leading: const Icon(Icons.format_quote),
                  title: Text(item.text ?? ''),
                  subtitle: _day(item.rememberedAt) == null
                      ? null
                      : Text(_day(item.rememberedAt)!),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String? _day(String? value) {
    if (value == null || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    final local = parsed.toLocal();
    return '${local.year}年${local.month}月${local.day}日';
  }
}
