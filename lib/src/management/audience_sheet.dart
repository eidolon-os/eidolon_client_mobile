import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';

/// 只让它记得 — choosing which of my Eidolons keeps one memory.
///
/// The gentlest destructive-looking action in the app, and the naming matters
/// because of that: nothing is deleted, nothing becomes unrecallable. The
/// Eidolon I name still remembers this in full; the others stop being told. So
/// the sheet says who *will* remember rather than who will not, and it always
/// offers the way back.
///
/// Two honesty rules it shares with the forget sheet:
///
/// - it does not say 已经 for a request that has only been accepted. The Host
///   publishes durably and applies asynchronously, and a memory that has not
///   moved yet is exactly the thing a person would check;
/// - it offers no choice it cannot act on: with no Companions to name, there is
///   nothing to keep a memory between, and the sheet says so instead of showing
///   an empty list with a button under it.
class AudienceSheet extends StatefulWidget {
  const AudienceSheet({
    super.key,
    required this.entryId,
    required this.companions,
    required this.assign,
    this.currentCompanionId,
  });

  final String entryId;

  /// The Owner's Eidolons, as the roster reported them.
  final List<CompanionSummaryView> companions;

  /// Null [companionId] gives the memory back to every Companion.
  final Future<MemoryAudienceView> Function(String? companionId) assign;

  /// Who holds it now, when the caller knows. Shown as the current choice so a
  /// person can see the state they are changing rather than guessing.
  final String? currentCompanionId;

  @override
  State<AudienceSheet> createState() => _AudienceSheetState();
}

class _AudienceSheetState extends State<AudienceSheet> {
  bool _busy = false;
  String? _message;
  Object? _error;

  Future<void> _choose(String? companionId) async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await widget.assign(companionId);
      if (!mounted) return;
      final name = companionId == null
          ? null
          : _nameOf(companionId) ?? companionId;
      setState(() {
        _busy = false;
        _message = result.status == 'applied'
            ? (name == null ? '所有伙伴都可以记得了' : '现在只有 $name 记得')
            // Durable but not yet applied. "已经" here would be the comfortable
            // lie: the memory a person is about to go and check has not moved.
            : (name == null ? '已受理，正在生效' : '已受理，正在让只有 $name 记得');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  String? _nameOf(String companionId) {
    for (final companion in widget.companions) {
      if (companion.companionId == companionId) {
        final name = companion.displayName ?? '';
        return name.isEmpty ? null : name;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    return Scaffold(
      key: const Key('audience-sheet'),
      appBar: AppBar(title: const Text('谁记得这条')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              // Says what will happen, not what will stop happening.
              '选一个伙伴，这条记忆就只有它记得。别的伙伴不会再被告知，但它本身不会被删掉。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (widget.companions.isEmpty)
            const Padding(
              key: Key('audience-no-companions'),
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('还没有别的伙伴，没有可以「只让它记得」的对象'),
            )
          else ...[
            ListTile(
              key: const Key('audience-everyone'),
              title: const Text('所有伙伴都可以记得'),
              trailing: widget.currentCompanionId == null
                  ? const Icon(Icons.check)
                  : null,
              onTap: _busy ? null : () => _choose(null),
            ),
            const Divider(height: 1),
            for (final companion in widget.companions)
              ListTile(
                key: Key('audience-companion-${companion.companionId}'),
                title: Text(
                  (companion.displayName ?? '').isEmpty
                      ? companion.companionId
                      : companion.displayName!,
                ),
                subtitle: const Text('只让它记得'),
                trailing: widget.currentCompanionId == companion.companionId
                    ? const Icon(Icons.check)
                    : null,
                onTap: _busy ? null : () => _choose(companion.companionId),
              ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: CircularProgressIndicator(key: Key('audience-busy')),
              ),
            ),
          if (message != null)
            Padding(
              key: const Key('audience-result'),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(message),
            ),
          if (_error != null)
            Padding(
              key: const Key('audience-error'),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                _error is ManagementRequestException &&
                        (_error as ManagementRequestException).statusCode == 404
                    // The entry was forgotten between the page being read and
                    // this being tapped. Ordinary, and not a fault to apologise
                    // for — but not a success either.
                    ? '这条记忆已经不在了'
                    : '没能改成：$_error',
              ),
            ),
        ],
      ),
    );
  }
}
