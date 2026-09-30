import 'dart:async';

import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';

/// 纠错：ask it to forget something, see what that means, and see it happen.
///
/// The whole shape of this screen is the steps. A person types words; the Host
/// says which entries those words matched; only then is there a button, and
/// pressing it asks once more, because what follows cannot be undone. The
/// button confirms *the entries shown* — the token carries them — so what
/// happens is what was read, not what the words match a minute later.
///
/// What it refuses to do:
///
/// - **It never offers a button without a token**, and never after the token
///   has expired. "Nothing matched" and "too much matched" come back without
///   one and are said in their own words.
/// - **It does not present a permanent change as a reversible one.** Forgetting
///   is a deletion; the screen says so before and at the moment of deciding.
/// - **It does not soften an inexact match.** When the Host is guessing, the
///   entries are shown with that said out loud.
/// - **It does not claim the change is done.** The Host applies it in the
///   background and usually answers `accepted`; this asks again until the Host
///   says `applied` or `failed`, instead of leaving 「正在生效」 on screen with
///   nothing behind it.
/// - **It does not print the Host's exception.** Refusals are worded by
///   [refusalText]; a refusal this phone cannot help with disables the button
///   instead of inviting another try.
class ForgetSheet extends StatefulWidget {
  const ForgetSheet({
    super.key,
    required this.preview,
    required this.confirm,
    this.progress,
    this.initialTarget = '',
    this.now,
    this.pollDelays = defaultPollDelays,
  });

  final Future<ForgetProposalView> Function(String target) preview;
  final Future<ForgetResultView> Function(String confirmationToken) confirm;

  /// Where a confirmed change has got to. Null on a Host too old to say, in
  /// which case the screen says the change was accepted and nothing more.
  final Future<ForgetProgressView> Function(String requestId)? progress;

  /// Prefilled when the person arrived from something they were looking at.
  final String initialTarget;

  /// Injected in tests so expiry is a fact rather than the clock.
  final DateTime Function()? now;

  /// How long to wait before each progress read. About a minute in all: long
  /// enough for a Host under load, short enough that a stuck change is said.
  final List<Duration> pollDelays;

  static const List<Duration> defaultPollDelays = [
    Duration(seconds: 1),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 13),
    Duration(seconds: 21),
  ];

  @override
  State<ForgetSheet> createState() => _ForgetSheetState();
}

/// Where a confirmed forget is, from this screen's point of view.
enum _Progress { working, applied, failed, unknown }

class _ForgetSheetState extends State<ForgetSheet> {
  late final TextEditingController _target =
      TextEditingController(text: widget.initialTarget);
  ForgetProposalView? _proposal;
  ForgetResultView? _result;
  _Progress? _progress;
  Object? _error;
  bool _busy = false;
  bool _expired = false;
  Timer? _expiry;
  int _generation = 0;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void dispose() {
    _expiry?.cancel();
    _generation++;
    _target.dispose();
    super.dispose();
  }

  /// A refusal no amount of trying from this phone can change.
  bool get _blocked {
    final error = _error;
    if (error is! ManagementRequestException) return false;
    if (error.someoneElseChangedIt || error.kind == 'invalid') return false;
    return !canRetry(error);
  }

  void _watchExpiry(ForgetProposalView proposal) {
    _expiry?.cancel();
    _expired = false;
    final expiresAt = proposal.expiresAt;
    if (expiresAt == null || proposal.confirmationToken == null) return;
    final deadline = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    final left = deadline.difference(_now());
    if (left <= Duration.zero) {
      _expired = true;
      return;
    }
    _expiry = Timer(left, () {
      if (mounted) setState(() => _expired = true);
    });
  }

  Future<void> _preview() async {
    final target = _target.text.trim();
    if (target.isEmpty || _busy) return;
    _generation++;
    _expiry?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      // A new question invalidates the previous answer. Leaving the old
      // proposal on screen would let someone confirm a set that belonged to
      // words they have since changed.
      _proposal = null;
      _result = null;
      _progress = null;
      _expired = false;
    });
    try {
      final proposal = await widget.preview(target);
      if (!mounted) return;
      setState(() {
        _proposal = proposal;
        _watchExpiry(proposal);
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

  Future<void> _decide(ForgetProposalView proposal, String token) async {
    if (_busy || _expired) return;
    final count = proposal.entries.length;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('forget-decision'),
        title: Text('忘掉这 $count 条？'),
        content: const Text('忘掉后不能恢复，你的伙伴以后也不会再想起这些。'),
        actions: [
          TextButton(
            key: const Key('forget-decision-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('先不'),
          ),
          FilledButton(
            key: const Key('forget-decision-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('忘掉'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted || _busy || _proposal != proposal) return;
    final expiresAt = proposal.expiresAt;
    if (_expired || (expiresAt != null &&
        _now().millisecondsSinceEpoch >= expiresAt * 1000)) {
      setState(() => _expired = true);
      return;
    }
    await _confirm(token);
  }

  Future<void> _confirm(String token) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.confirm(token);
      if (!mounted) return;
      _expiry?.cancel();
      setState(() {
        _result = result;
        // The proposal is spent: its token names a change that now exists, and
        // offering the button again would only ask about that same change.
        _proposal = null;
        _progress = _progressOf(result.status);
        _busy = false;
      });
      if (_progress == _Progress.working) unawaited(_follow(result.requestId));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  static _Progress _progressOf(String status) => switch (status) {
        'applied' => _Progress.applied,
        'failed' => _Progress.failed,
        _ => _Progress.working,
      };

  /// Asks where the change got to until the Host says it finished.
  ///
  /// Ends in [_Progress.unknown] when the Host stops answering or keeps
  /// saying "working" past the last delay — said as such, with a way to ask
  /// again, because the change can still finish on its own.
  Future<void> _follow(String requestId) async {
    final read = widget.progress;
    if (read == null) {
      setState(() => _progress = _Progress.unknown);
      return;
    }
    final generation = ++_generation;
    if (_progress != _Progress.working) {
      setState(() => _progress = _Progress.working);
    }
    for (final delay in widget.pollDelays) {
      await Future<void>.delayed(delay);
      if (!mounted || generation != _generation) return;
      try {
        final progress = await read(requestId);
        if (!mounted || generation != _generation) return;
        final next = _progressOf(progress.status);
        if (next != _Progress.working) {
          setState(() => _progress = next);
          return;
        }
      } catch (error) {
        if (!mounted || generation != _generation) return;
        if (!canRetry(error)) break;
      }
    }
    if (mounted && generation == _generation) {
      setState(() => _progress = _Progress.unknown);
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
          Text(
            '说出想让它忘掉的事。会先在你所有伙伴的记忆里查找，列出找到的内容；'
            '确认后才会删除，删除后不能恢复。',
            key: const Key('forget-explainer'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
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
            onPressed: _busy || _blocked ? null : _preview,
            child: const Text('先看看会忘掉什么'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _Refusal(error: _error!),
          ],
          if (_result case final result?) ...[
            const SizedBox(height: 20),
            _Outcome(
              result: result,
              progress: _progress ?? _Progress.working,
              onAskAgain: () => _follow(result.requestId),
            ),
          ],
          if (_proposal case final proposal?) ...[
            const SizedBox(height: 20),
            _Proposal(
              proposal: proposal,
              busy: _busy,
              expired: _expired,
              onDecide: _decide,
            ),
          ],
        ],
      ),
    );
  }
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    final style = TextStyle(color: Theme.of(context).colorScheme.error);
    // Expired, forged, or from another Host: all mean this preview can no
    // longer be acted on, and the next step is the same.
    if (error is ManagementRequestException && error.someoneElseChangedIt) {
      return Text(
        '这次预览已经失效，请重新看一遍再决定',
        key: const Key('forget-error'),
        style: style,
      );
    }
    final detail = refusalDetail(error);
    return Column(
      key: const Key('forget-error'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('没有完成：${refusalText(error, subject: '记忆纠错')}', style: style),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _Proposal extends StatelessWidget {
  const _Proposal({
    required this.proposal,
    required this.busy,
    required this.expired,
    required this.onDecide,
  });

  final ForgetProposalView proposal;
  final bool busy;
  final bool expired;
  final Future<void> Function(ForgetProposalView proposal, String token) onDecide;

  @override
  Widget build(BuildContext context) {
    final token = proposal.confirmationToken;
    if (token == null || proposal.status != 'preview') {
      // No token, no button. The two reasons are different things to say.
      return Text(
        key: const Key('forget-nothing-to-do'),
        proposal.status == 'too_broad'
            ? '这么说会牵连太多，说得再具体一点'
            : '没有找到和「${proposal.target}」有关的记忆',
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
        if (expired)
          const Padding(
            key: Key('forget-expired'),
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text('这次预览已经过期，请重新看一遍再决定'),
          ),
        FilledButton.tonal(
          key: const Key('forget-confirm-button'),
          onPressed: busy || expired ? null : () => onDecide(proposal, token),
          child: Text('忘掉这 ${entries.length} 条'),
        ),
      ],
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.result,
    required this.progress,
    required this.onAskAgain,
  });

  final ForgetResultView result;
  final _Progress progress;
  final VoidCallback onAskAgain;

  @override
  Widget build(BuildContext context) {
    final count = result.entryCount;
    switch (progress) {
      case _Progress.applied:
        return Text(
          key: const Key('forget-result'),
          '已经忘掉 $count 条，它以后不会再想起这些',
        );
      case _Progress.failed:
        return Text(
          key: const Key('forget-result'),
          '没有忘掉：主机没能完成这次删除。重新看一遍再试一次',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );
      case _Progress.working:
        return Row(
          key: const Key('forget-result'),
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('正在忘掉 $count 条…')),
          ],
        );
      case _Progress.unknown:
        return Column(
          key: const Key('forget-result'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('主机已经收下这次忘掉的 $count 条，还在处理。它会自己完成，不需要你再做什么。'),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('forget-ask-again'),
              onPressed: onAskAgain,
              child: const Text('再查一次进度'),
            ),
          ],
        );
    }
  }
}
