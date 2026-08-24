import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';

/// 纠错：ask it to forget something, and see what that means first.
///
/// The whole shape of this screen is the two steps. A person types words; the
/// Host says which entries those words matched; only then is there a button. The
/// button confirms *the entries shown* — the token carries them — so what
/// happens is what was read, not what the words match a minute later.
///
/// What it refuses to do:
///
/// - **It never offers a button without a token.** "Nothing matched" and "too
///   much matched" both come back without one, and both are said in their own
///   words: "你没有告诉过它这件事" and "这么说会牵连太多" lead to different next
///   moves, and an empty list would say neither.
/// - **It does not soften an inexact match.** When the Host is guessing, the
///   entries are shown with that said out loud, because pressing a button on a
///   guess is how someone loses something they meant to keep.
/// - **It does not claim the change is done.** The Host publishes durably and
///   applies asynchronously; this says 已受理 unless the Host said applied.
class ForgetSheet extends StatefulWidget {
  const ForgetSheet({
    super.key,
    required this.preview,
    required this.confirm,
    this.initialTarget = '',
  });

  final Future<ForgetProposalView> Function(String target) preview;
  final Future<ForgetResultView> Function(String confirmationToken) confirm;

  /// Prefilled when the person arrived from something they were looking at.
  final String initialTarget;

  @override
  State<ForgetSheet> createState() => _ForgetSheetState();
}

class _ForgetSheetState extends State<ForgetSheet> {
  late final TextEditingController _target =
      TextEditingController(text: widget.initialTarget);
  ForgetProposalView? _proposal;
  ForgetResultView? _result;
  Object? _error;
  bool _busy = false;

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final target = _target.text.trim();
    if (target.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      // A new question invalidates the previous answer. Leaving the old
      // proposal on screen would let someone confirm a set that belonged to
      // words they have since changed.
      _proposal = null;
      _result = null;
    });
    try {
      final proposal = await widget.preview(target);
      if (!mounted) return;
      setState(() {
        _proposal = proposal;
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

  Future<void> _confirm(String token) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.confirm(token);
      if (!mounted) return;
      setState(() {
        _result = result;
        // The proposal is spent: its token has been used, and offering the
        // button again would ask the Host to act on a decision already made.
        _proposal = null;
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
    return Scaffold(
      key: const Key('forget-sheet'),
      appBar: AppBar(title: const Text('让它忘掉')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            key: const Key('forget-target-field'),
            controller: _target,
            decoration: const InputDecoration(
              labelText: '忘掉什么',
              hintText: '比如「上周那件事」',
            ),
            onSubmitted: (_) => _preview(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('forget-preview-button'),
            onPressed: _busy ? null : _preview,
            child: const Text('先看看会忘掉什么'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              key: const Key('forget-error'),
              _sentence(_error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_result case final result?) ...[
            const SizedBox(height: 20),
            _Result(result: result),
          ],
          if (_proposal case final proposal?) ...[
            const SizedBox(height: 20),
            _Proposal(
              proposal: proposal,
              busy: _busy,
              onConfirm: _confirm,
            ),
          ],
        ],
      ),
    );
  }

  /// Keyed on status where the status is contract; the Host's own sentence is
  /// written for an operator reading a log.
  static String _sentence(Object error) {
    if (error is! ManagementRequestException) return '$error';
    if (error.statusCode == 409) {
      return '这次确认过期了，请重新看一遍再决定';
    }
    return '没有完成：$error';
  }
}

class _Proposal extends StatelessWidget {
  const _Proposal({
    required this.proposal,
    required this.busy,
    required this.onConfirm,
  });

  final ForgetProposalView proposal;
  final bool busy;
  final Future<void> Function(String token) onConfirm;

  @override
  Widget build(BuildContext context) {
    final token = proposal.confirmationToken;
    if (token == null) {
      // No token, no button. The two reasons are different things to say.
      return Text(
        key: const Key('forget-nothing-to-do'),
        proposal.status == 'too_broad'
            ? '这么说会牵连太多，说得再具体一点'
            : '你没有告诉过它这件事',
      );
    }
    final entries = proposal.entries;
    return Column(
      key: const Key('forget-proposal'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('会忘掉这 ${entries.length} 条：',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final entry in entries)
          ListTile(
            key: Key('forget-entry-${entry.entryId}'),
            contentPadding: EdgeInsets.zero,
            title: Text(entry.preview ?? entry.entryId),
            // Said out loud rather than shown as a number: a person deciding
            // whether to delete something needs to know the Host is guessing.
            subtitle: entry.score < 1 ? const Text('不是完全确定的匹配') : null,
          ),
        if (proposal.needsConfirmation)
          const Padding(
            key: Key('forget-inexact-warning'),
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text('不止一条，或者匹配得不够准 —— 确认前请再看一遍'),
          ),
        FilledButton.tonal(
          key: const Key('forget-confirm-button'),
          onPressed: busy ? null : () => onConfirm(token),
          child: Text(proposal.action == 'archive' ? '收起来' : '忘掉'),
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.result});

  final ForgetResultView result;

  @override
  Widget build(BuildContext context) {
    // "applied" is the only status that means it is done. Anything else was
    // accepted and is still on its way, and saying "done" for that would be the
    // comfortable lie.
    final done = result.status == 'applied';
    return Text(
      key: const Key('forget-result'),
      done
          ? '已经忘掉 ${result.entryCount} 条'
          : '已受理 ${result.entryCount} 条，正在生效',
    );
  }
}
