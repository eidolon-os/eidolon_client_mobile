import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'companion_roster_page.dart';
import 'management_client.dart';

/// Loads the roster and shows one of three honest answers.
///
/// Kept apart from [CompanionRosterPage] so the page stays a pure function of
/// what the Host said, and so the three states a network read actually has are
/// visible in one place:
///
/// - waiting;
/// - the Host answered, and the roster is shown even if it is empty;
/// - the Host refused, and *what* it said is shown rather than an empty list.
///
/// The last one is the reason this class exists. A failed read rendered as an
/// empty roster tells a person they have no Eidolons, which is a lie in the one
/// situation where they most need the truth.
class CompanionRosterScreen extends StatefulWidget {
  const CompanionRosterScreen({super.key, required this.load});

  /// Asks the Host for one page. Given a cursor when asking for a later one.
  final Future<CompanionRosterView> Function({String? cursor}) load;

  @override
  State<CompanionRosterScreen> createState() => _CompanionRosterScreenState();
}

class _CompanionRosterScreenState extends State<CompanionRosterScreen> {
  CompanionRosterView? _roster;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read({String? cursor}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.load(cursor: cursor);
      if (!mounted) return;
      setState(() {
        // Pages are appended rather than replacing what is on screen: asking
        // for more must not make what a person was already reading disappear.
        _roster = cursor == null || _roster == null
            ? page
            : CompanionRosterView(
                contractVersion: page.contractVersion,
                defaultCompanionId: page.defaultCompanionId,
                companions: [..._roster!.companions, ...page.companions],
                nextCursor: page.nextCursor,
              );
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
    final roster = _roster;
    if (roster != null) {
      return Stack(
        children: [
          CompanionRosterPage(
            roster: roster,
            onLoadMore:
                roster.nextCursor == null ? null : () => _read(cursor: roster.nextCursor),
          ),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(key: Key('roster-loading-more')),
            ),
        ],
      );
    }
    return Scaffold(
      key: const Key('companion-roster-screen'),
      appBar: AppBar(title: const Text('你的 Eidolon')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('roster-loading'))
            : Padding(
                key: const Key('roster-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException).hostHasNoOwner
                          // A Host nobody owns yet. Not "you have none": there
                          // is no Owner to have any, and the way forward is
                          // setup rather than a create button.
                          ? '这台主机还没有主人，先完成设置'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('roster-retry'),
                      onPressed: () => _read(),
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
