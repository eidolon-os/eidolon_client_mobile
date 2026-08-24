import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'companion_detail_screen.dart';
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
  const CompanionRosterScreen({
    super.key,
    required this.load,
    this.openCompanion,
    this.loadContext,
    this.setDefaultCompanion,
  });

  /// Asks the Host for one page. Given a cursor when asking for a later one.
  final Future<CompanionRosterView> Function({String? cursor}) load;

  /// Reads one Eidolon. Null leaves the rows unopenable rather than opening
  /// something that cannot load.
  final Future<CompanionDetailView> Function(String companionId)? openCompanion;

  /// Read once when this screen opens, for two things it cannot infer:
  /// whether this Host can change the default at all, and which Owner revision
  /// the person is looking at.
  final Future<ManagementContextView> Function()? loadContext;

  /// Performs the change. Given the revision this screen was showing, not a
  /// freshly-read one — a compare-and-swap against a value read a millisecond
  /// earlier protects nothing.
  final Future<CompanionDetailOutcome> Function(
    String companionId,
    int expectedRevision,
  )? setDefaultCompanion;

  @override
  State<CompanionRosterScreen> createState() => _CompanionRosterScreenState();
}

class _CompanionRosterScreenState extends State<CompanionRosterScreen> {
  CompanionRosterView? _roster;
  ManagementContextView? _context;
  Object? _error;
  bool _busy = true;
  String? _changing;
  String? _refusal;

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
      // Asked for together on a first read, because a roster drawn before the
      // Host said what it can do would either hide an action it allows or
      // offer one it does not.
      final context = cursor == null && widget.loadContext != null
          ? await widget.loadContext!()
          : _context;
      final page = await widget.load(cursor: cursor);
      if (!mounted) return;
      setState(() {
        _context = context;
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

  /// Ask the Host to move the pointer, then believe only the Host.
  ///
  /// The whole page is re-read on success rather than patched locally: the
  /// Owner revision has moved, and a screen holding the old one would refuse
  /// the person's next change for a reason that is this screen's fault.
  Future<void> _makeDefault(CompanionSummaryView companion) async {
    final change = widget.setDefaultCompanion;
    final revision = _context?.owner.revision;
    if (change == null || revision == null) return;
    setState(() {
      _changing = companion.companionId;
      _refusal = null;
    });
    try {
      await change(companion.companionId, revision);
      if (!mounted) return;
      setState(() => _changing = null);
      await _read();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _changing = null;
        _refusal = _refusalSentence(error);
      });
      // A stale view is the one refusal that is answered by looking again, and
      // the person should not have to press anything to get that.
      if (error is ManagementRequestException && error.someoneElseChangedIt) {
        await _read();
      }
    }
  }

  /// Keyed on the status, which is contract — not on the Host's own sentence,
  /// which is written for an operator reading a log.
  static String _refusalSentence(Object error) {
    if (error is! ManagementRequestException) return '$error';
    if (error.someoneElseChangedIt) {
      return '别的地方刚改过默认，已经重新读取';
    }
    if (error.statusCode == 400) {
      return '这台主机不允许把它设为默认';
    }
    if (error.statusCode == 404) {
      return '这台主机上没有这个 Eidolon';
    }
    return '没有改成：$error';
  }

  @override
  Widget build(BuildContext context) {
    final roster = _roster;
    if (roster != null) {
      return Stack(
        children: [
          CompanionRosterPage(
            roster: roster,
            onOpen: widget.openCompanion == null
                ? null
                : (companion) => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => CompanionDetailScreen(
                          companionId: companion.companionId,
                          load: widget.openCompanion!,
                        ),
                      ),
                    ),
            onLoadMore:
                roster.nextCursor == null ? null : () => _read(cursor: roster.nextCursor),
            onMakeDefault: widget.setDefaultCompanion == null ||
                    _context == null ||
                    !hostCan(_context!, 'companion.set_default')
                ? null
                : _makeDefault,
            busyCompanionId: _changing,
            refusal: _refusal,
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
