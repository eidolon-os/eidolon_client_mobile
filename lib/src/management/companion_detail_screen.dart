import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'lifecycle_sheet.dart';
import 'management_client.dart';
import '../protocol/companion_contract.dart';

/// One Eidolon, opened from the roster.
///
/// It has exactly one thing to press, and only when the Host says it can do it:
/// putting this Eidolon away, or bringing it back. Renaming still is not here,
/// because a control that is greyed out promises something this Host cannot do
/// yet, and one that appears to work while nothing happens behind it is worse.
///
/// It carries `revision` without displaying it. The number means nothing to a
/// person, but a write from this screen presents it, and having it already read
/// is the difference between one round trip and two — the second of which could
/// see a different value.
class CompanionDetailScreen extends StatefulWidget {
  const CompanionDetailScreen({
    super.key,
    required this.companionId,
    required this.load,
    this.setLifecycle,
    this.others = const [],
  });

  final String companionId;
  final Future<CompanionDetailView> Function(String companionId) load;

  /// Puts this Eidolon away or brings it back. Null leaves the screen with
  /// nothing to press, which is what a Host that cannot do this yet deserves to
  /// look like.
  final Future<CompanionLifecycleView> Function(
    String companionId,
    String lifecycleState,
    String? replacementCompanionId,
  )? setLifecycle;

  /// This Owner's other Eidolons, for the successor question — asked only if
  /// the Host says it needs asking.
  final List<CompanionSummaryView> others;

  @override
  State<CompanionDetailScreen> createState() => _CompanionDetailScreenState();
}

class _CompanionDetailScreenState extends State<CompanionDetailScreen> {
  CompanionDetailView? _companion;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final companion = await widget.load(widget.companionId);
      if (!mounted) return;
      setState(() {
        _companion = companion;
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
    final companion = _companion;
    final name = (companion?.displayName ?? '').isNotEmpty
        ? companion!.displayName!
        : '还没有名字的 Eidolon';
    return Scaffold(
      key: const Key('companion-detail-screen'),
      appBar: AppBar(title: Text(_busy && companion == null ? '打开中' : name)),
      body: _body(companion),
    );
  }

  Widget _body(CompanionDetailView? companion) {
    if (companion == null) {
      return Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('detail-loading'))
            : Padding(
                key: const Key('detail-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // 404 here is "not one of yours", which is also the
                      // answer when the id never existed. Saying more would
                      // turn this screen into a way to test identifiers.
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException)
                                      .statusCode ==
                                  404
                          ? '这台主机上没有这个 Eidolon'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('detail-retry'),
                      onPressed: _read,
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 26,
                      child: Icon(Icons.face_retouching_natural),
                    ),
                    const SizedBox(width: 14),
                    if (companion.isDefault)
                      const Chip(
                        key: Key('detail-default-badge'),
                        label: Text('默认'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(companionLifecycleSentence(companion.lifecycleState)),
                const SizedBox(height: 6),
                Text(
                  _kindSentence(companion.kind),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        if (widget.setLifecycle != null &&
            (companion.lifecycleState == 'active' ||
                companion.lifecycleState == 'archived')) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const Key('detail-lifecycle'),
              onPressed: () => _openLifecycleSheet(companion),
              child: Text(
                companion.lifecycleState == 'active' ? '收起来' : '让它回来',
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Only ``active`` and ``archived`` offer the action. ``retiring`` is a step
  /// the Host is walking through and ``deleting`` is not something this screen
  /// interrupts; either way the honest thing is a screen with nothing to press,
  /// not a button that will be refused.
  Future<void> _openLifecycleSheet(CompanionDetailView companion) async {
    final change = widget.setLifecycle;
    if (change == null) return;
    final moved = await showModalBottomSheet<CompanionLifecycleView>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CompanionLifecycleSheet(
        companion: companion,
        others: widget.others
            .where((row) =>
                row.companionId != companion.companionId &&
                row.lifecycleState == 'active')
            .toList(),
        setLifecycle: (state, replacement) =>
            change(companion.companionId, state, replacement),
      ),
    );
    if (moved == null || !mounted) return;
    // Read back rather than patching what is on screen: this screen shows a
    // Companion, and the answer to a lifecycle change describes a move, not a
    // Companion. Painting one from the other is how the two drift.
    await _read();
  }
}

/// A kind is the Host's to grow, so an unfamiliar one is described as such
/// rather than shown raw or assumed ordinary.
String _kindSentence(String kind) => switch (kind) {
      'standard' => '你日常对话的 Eidolon',
      'guard' => '守卫用途的 Eidolon',
      _ => '这台 Host 上的另一类 Eidolon',
    };
