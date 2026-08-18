import 'package:flutter/material.dart';

import 'recollection_models.dart';

/// Ask an Eidolon what it remembers.
///
/// A question and what came back, and nothing else. The screen begins empty on
/// purpose: there is no "everything it remembers" to list, and a page that
/// opened with a sample of someone's life would be choosing what to show them
/// about themselves.
class RecollectionsPage extends StatefulWidget {
  const RecollectionsPage({
    super.key,
    required this.companionName,
    required this.onSearch,
  });

  final String companionName;
  final Future<Recollections> Function(String query) onSearch;

  @override
  State<RecollectionsPage> createState() => _RecollectionsPageState();
}

class _RecollectionsPageState extends State<RecollectionsPage> {
  final _question = TextEditingController();
  Recollections? _answer;
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
      // Never an empty result on failure: "it does not remember that" and "it
      // could not be asked" are different things to be told about yourself.
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
      appBar: AppBar(title: Text('${widget.companionName}记得什么')),
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
                  '问点什么,看看它记得。它记住的东西一直留在这台主机上。',
                  key: Key('recollections-idle'),
                ),
              ),
            )
          else if (answer.items.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  '关于「${answer.query}」,它还没有记住什么。',
                  key: const Key('recollections-empty'),
                ),
              ),
            )
          else
            ...answer.items.map(
              (item) => Card(
                child: ListTile(
                  leading: const Icon(Icons.format_quote),
                  title: Text(item.text),
                  subtitle: item.rememberedAt == null
                      ? null
                      : Text(_day(item.rememberedAt!)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The day it was remembered, in this phone's own time.
  String _day(DateTime value) {
    final local = value.toLocal();
    return '${local.year}年${local.month}月${local.day}日';
  }
}
