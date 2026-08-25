import 'dart:math';

import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'companion_detail_screen.dart';
import 'companion_authoring_page.dart';
import 'companion_roster_page.dart';
import 'management_client.dart';
import 'refusal_notice.dart';

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
    this.setCompanionLifecycle,
    this.loadCompanionFace,
    this.renameCompanion,
    this.createCompanion,
    this.loadPersonaTemplate,
    this.newOperationId,
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

  /// Puts one away, or brings it back. Passed through to the detail screen,
  /// which is where a person is looking at the single Eidolon they mean. Null
  /// on a Host that cannot do it yet, and the button is then absent rather than
  /// disabled.
  final Future<CompanionLifecycleView> Function(
    String companionId,
    String lifecycleState,
    String? replacementCompanionId,
  )? setCompanionLifecycle;

  /// What one of them looks like, read when its own screen opens.
  final Future<CompanionFacePicture> Function(String companionId)?
      loadCompanionFace;

  /// Calls one of them something else.
  final Future<String> Function(String companionId, String displayName)?
      renameCompanion;

  /// Adds one. Given an operation id this screen holds, not one per attempt.
  ///
  /// The persona is what the person wrote on the authoring page, or null when
  /// they left it as the Host had it — null is not the same request as a copy of
  /// the template, and the difference is what keeps a retry a replay.
  final Future<CreatedCompanion> Function(
    String operationId,
    String displayName,
    PersonaAuthoring? persona,
  )? createCompanion;

  /// What the Host would write if the authoring form came back untouched.
  ///
  /// Read when the person asks to add one, not when this screen opens: it is
  /// only needed on the way into the form, and a roster that failed to load
  /// because of it would be a list nobody can read for the sake of a button.
  final Future<PersonaAuthoring> Function()? loadPersonaTemplate;

  /// Injected so a test can pin the id; a real screen mints a random one.
  final String Function()? newOperationId;

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
  String? _notice;

  /// Held across retries, exactly like the device-removal request id: the whole
  /// point of the operation id is that a second attempt is the *same* attempt.
  /// Cleared only once the Host has answered for it, one way or the other.
  String? _pendingOperationId;
  final Random _random = Random.secure();

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

  /// Ask for another Eidolon: who it is, then the ask itself.
  ///
  /// This used to be a dialog with one box in it, which is why every Eidolon
  /// this Host made was the same person under a different name. The form opens
  /// on what the Host would write by itself, so it can be walked past in three
  /// taps — the cost of saying more is on whoever wants to say more.
  ///
  /// The operation id is minted here and **kept across a failure**, so pressing
  /// 创建 again after a lost answer addresses the same Eidolon. It is also held
  /// across the form: someone who backs out and starts again is still asking for
  /// the one thing they asked for.
  Future<void> _add() async {
    final create = widget.createCompanion;
    final loadTemplate = widget.loadPersonaTemplate;
    if (create == null || loadTemplate == null) return;

    setState(() {
      _refusal = null;
      _notice = null;
    });

    final PersonaAuthoring template;
    try {
      template = await loadTemplate();
    } catch (error) {
      if (!mounted) return;
      // No form rather than a form full of guesses: a starting point this
      // client invented would describe an Eidolon the Host will not create.
      setState(() => _refusal = _refusalSentence(error));
      return;
    }
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _AuthoringRoute(
          template: template,
          create: (displayName, persona) async {
            final operationId = _pendingOperationId ??= _newOperationId();
            final created = await create(operationId, displayName, persona);
            // Answered, so this operation is finished — a later "add" is a new
            // one.
            _pendingOperationId = null;
            return created;
          },
          refusalSentence: _refusalSentence,
          onCreated: (created) {
            if (!mounted) return;
            setState(() {
              _notice = created.memoryReady
                  ? '${created.displayName} 已经在这台主机上了'
                  : '${created.displayName} 已经建好，记忆还在启动';
            });
          },
        ),
      ),
    );
    if (!mounted) return;
    await _read();
  }

  String _newOperationId() {
    if (widget.newOperationId != null) return widget.newOperationId!();
    // A version-4 UUID, because the Host's operation id is one. Built from
    // Random.secure like every other identifier this app mints.
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
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
                : (companion) => Navigator.of(context)
                    .push<void>(
                      MaterialPageRoute(
                        builder: (_) => CompanionDetailScreen(
                          companionId: companion.companionId,
                          load: widget.openCompanion!,
                          // Both names are read, because both are answers to
                          // real questions: a Host may be able to put one away
                          // and not bring one back. A flag nothing checks is a
                          // claim nobody verifies.
                          canPutAway: _context != null &&
                              hostCan(_context!, 'companion.archive'),
                          canBringBack: _context != null &&
                              hostCan(_context!, 'companion.restore'),
                          setLifecycle: widget.setCompanionLifecycle,
                          loadFace: widget.loadCompanionFace,
                          rename: widget.renameCompanion,
                          canRename: _context != null &&
                              hostCan(_context!, 'companion.rename'),
                          // The rows this screen already has. The successor
                          // question is asked from what the person is looking
                          // at, not from a second read that could disagree
                          // with it.
                          others: roster.companions,
                        ),
                      ),
                    )
                    .then((_) => _read()),
            onLoadMore: roster.nextCursor == null
                ? null
                : () => _read(cursor: roster.nextCursor),
            onMakeDefault: widget.setDefaultCompanion == null ||
                    _context == null ||
                    !hostCan(_context!, 'companion.set_default')
                ? null
                : _makeDefault,
            busyCompanionId: _changing,
            refusal: _refusal,
            notice: _notice,
            onAdd: widget.createCompanion == null ||
                    _context == null ||
                    !hostCan(_context!, 'companion.create')
                ? null
                : _add,
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
            : RefusalNotice(
                key: const Key('roster-error'),
                error: _error!,
                subject: '你的 Eidolon',
                onRetry: () => _read(),
                retryKey: const Key('roster-retry'),
              ),
      ),
    );
  }
}

/// The authoring page plus the one piece of state it cannot own: whether the ask
/// is in flight, and what the Host said if it refused.
///
/// Separate from the page so the page stays a form — it renders what it is given
/// and hands back what was typed. Keeping the request here also means the
/// refusal is shown *on* the form, next to the words that caused it, instead of
/// behind a pop back to the list.
class _AuthoringRoute extends StatefulWidget {
  const _AuthoringRoute({
    required this.template,
    required this.create,
    required this.refusalSentence,
    required this.onCreated,
  });

  final PersonaAuthoring template;
  final Future<CreatedCompanion> Function(
    String displayName,
    PersonaAuthoring? persona,
  ) create;
  final String Function(Object error) refusalSentence;
  final void Function(CreatedCompanion created) onCreated;

  @override
  State<_AuthoringRoute> createState() => _AuthoringRouteState();
}

class _AuthoringRouteState extends State<_AuthoringRoute> {
  bool _busy = false;
  String? _refusal;

  @override
  Widget build(BuildContext context) {
    return CompanionAuthoringPage(
      template: widget.template,
      busy: _busy,
      refusal: _refusal,
      onCreate: (displayName, persona) async {
        setState(() {
          _busy = true;
          _refusal = null;
        });
        try {
          final navigator = Navigator.of(context);
          final created = await widget.create(displayName, persona);
          if (!mounted) return;
          widget.onCreated(created);
          // Captured before the await: the analyzer is right that a context
          // read after one is a different context, and the navigator this
          // route was pushed onto is the one that has to pop it.
          navigator.pop();
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _refusal = widget.refusalSentence(error);
          });
        }
      },
    );
  }
}
