import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'forget_sheet.dart';
import 'memory_copy_screen.dart';
import 'memory_day_screen.dart';
import 'memory_graph_screen.dart';
import 'management_client.dart';
import 'refusal_notice.dart';
import 'memory_library_page.dart';
import 'recollections_page.dart';
import 'memory_labels.dart';

/// Loads the library and shows one of three honest answers.
///
/// Kept apart from [MemoryLibraryPage] for the same reason the roster is: the
/// page stays a pure function of what the Host said, and the states a network
/// read actually has live in one place.
///
/// The one that matters here is the third. A memory that could not be read must
/// not render as a memory with nothing in it — "它还没记下什么" and "我读不到"
/// are different sentences, and only one of them is about the person.
class MemoryLibraryScreen extends StatefulWidget {
  const MemoryLibraryScreen({
    super.key,
    required this.load,
    this.initialCompanionId,
    this.loadForCompanion,
    this.loadGraph,
    this.loadContext,
    this.previewForget,
    this.confirmForget,
    this.forgetProgress,
    this.loadDay,
    this.loadCopy,
    this.loadCompanions,
    this.searchRecollections,
  });

  final Future<MemoryLibraryView> Function() load;

  /// The perspective named by the route that opened this screen.
  ///
  /// A Companion detail page already knows which Eidolon it is about. Passing
  /// that fact in is different from maintaining a second Companion-memory
  /// page: this remains the Owner's one memory experience, initially filtered
  /// to the audience the person chose. Null is the Owner's own memory —
  /// everything any of their Eidolons was told — which is what 「你的记忆」
  /// means, and what the home screen counts.
  final String? initialCompanionId;
  final Future<MemoryLibraryView> Function(String? companionId)?
      loadForCompanion;
  final Future<MemoryGraphView> Function(String? companionId,
      {String? cursor, required bool history})? loadGraph;

  /// Read once, for the one thing this screen cannot infer: whether this Host
  /// can govern memory at all.
  final Future<ManagementContextView> Function()? loadContext;

  final Future<ForgetProposalView> Function(String target)? previewForget;
  final Future<ForgetResultView> Function(String confirmationToken)?
  confirmForget;
  final Future<ForgetProgressView> Function(String requestId)? forgetProgress;

  /// Reads a window of recent entries. Null hides the way in rather than
  /// opening a screen that cannot fill itself.
  final Future<MemoryDayView> Function(
    DateTime since,
    String? companionId,
    String? cursor,
  )? loadDay;

  /// Reads visible records for a full copy or one category, using the same
  /// Host export contract. Null hides both ways in.
  final Future<MemoryCopyView> Function(String? companionId,
      {String? wing, String? room})? loadCopy;

  /// Reads names for selecting the Companion-private view of this Owner Realm.
  final Future<List<CompanionSummaryView>> Function()? loadCompanions;

  /// Searches the memory in view: one Companion's, or with null the Owner's
  /// own. Search belongs here as a way to explore the same library, even
  /// though the answer keeps its own focused screen.
  final Future<RecollectionsView> Function(String? companionId, String query)?
  searchRecollections;

  @override
  State<MemoryLibraryScreen> createState() => _MemoryLibraryScreenState();
}

class _MemoryLibraryScreenState extends State<MemoryLibraryScreen> {
  MemoryLibraryView? _library;
  ManagementContextView? _context;
  List<CompanionSummaryView> _companions = const [];
  String? _selectedCompanionId;
  Object? _error;

  /// A refresh that failed while a library was already on screen. Shown above
  /// it rather than swallowed: a stale page that looks current is the moment a
  /// person stops trusting this screen.
  Object? _refreshError;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _selectedCompanionId = widget.initialCompanionId;
    _read();
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = null;
      _refreshError = null;
    });
    try {
      // Asked for together: a library drawn before the Host said what it can do
      // would either hide an action it allows or offer one it does not.
      final context = widget.loadContext == null
          ? null
          : await widget.loadContext!();
      var companions = const <CompanionSummaryView>[];
      if (widget.loadCompanions != null) {
        try {
          companions = await widget.loadCompanions!();
        } catch (_) {
          // The selector is enrichment. A transient roster failure must not
          // turn readable memory into an error page.
        }
      }
      // No default Companion substituted: without one named this is the
      // Owner's own memory, the same view the home screen counts. It used to
      // fall back to the default Companion, so the two numbers disagreed.
      final selected = _selectedCompanionId;
      final library = widget.loadForCompanion == null
          ? await widget.load()
          : await widget.loadForCompanion!(selected);
      if (!mounted) return;
      setState(() {
        _context = context;
        _companions = companions;
        _library = library;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (_library == null) {
          _error = error;
        } else {
          _refreshError = error;
        }
        _busy = false;
      });
    }
  }

  bool get _canForget =>
      widget.previewForget != null &&
      widget.confirmForget != null &&
      _canGovern;

  bool get _canGovern =>
      _context != null && hostCan(_context!, 'memory.govern');

  /// Opened as its own screen rather than a dialog: what is about to be removed
  /// has to be readable, and a list inside a dialog is where that gets cramped.
  Future<void> _openForget() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ForgetSheet(
          preview: widget.previewForget!,
          confirm: widget.confirmForget!,
          progress: widget.forgetProgress,
        ),
      ),
    );
    if (!mounted) return;
    // Something may be gone now. Re-read rather than patch: the Host says what
    // is remembered, and a stale library after a deletion is exactly the moment
    // a person would stop trusting this screen.
    await _read();
  }

  /// Its own screen: "what happened today" and "what is held overall" are two
  /// questions, and answering both on one page makes each harder to read.
  Future<void> _openToday() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MemoryDayScreen(
            scopeLabel: _scopeLabel,
            load: (since, cursor) =>
                widget.loadDay!(since, _selectedCompanionId, cursor),
          ),
        ),
      );

  /// Its own screen as well, and for a sharper reason than the day page: this
  /// one must not shorten anything, and a page that shares room with a roll-up
  /// is a page under pressure to.
  Future<void> _openCopy() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MemoryCopyScreen(
              scopeLabel: _scopeLabel,
              load: () => widget.loadCopy!(_selectedCompanionId)),
        ),
      );

  Future<void> _openRoom(MemoryWingView wing, MemoryRoomView room) {
    final companionId = _selectedCompanionId;
    return Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => MemoryCopyScreen(
        title: memoryRoomLabel(room.roomId),
        roomView: true,
        scopeLabel: _scopeLabel,
        load: () =>
            widget.loadCopy!(companionId, wing: wing.wingId, room: room.roomId),
      ),
    ));
  }

  Future<void> _selectCompanion(String? companionId) async {
    if (companionId == _selectedCompanionId) return;
    setState(() {
      _selectedCompanionId = companionId;
      _busy = true;
      _refreshError = null;
    });
    try {
      final library = widget.loadForCompanion == null
          ? await widget.load()
          : await widget.loadForCompanion!(companionId);
      if (!mounted) return;
      setState(() {
        _library = library;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _library = null;
        _busy = false;
      });
    }
  }

  Future<void> _openGraph() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MemoryGraphScreen(
            scopeLabel: _scopeLabel,
            load: ({String? cursor, required bool history}) =>
                widget.loadGraph!(_selectedCompanionId,
                    cursor: cursor, history: history),
          ),
        ),
      );

  /// The selected Companion's name, or null for the Owner's own view.
  String? get _selectedCompanionName {
    final selected = _selectedCompanionId;
    if (selected == null) return null;
    for (final companion in _companions) {
      if (companion.companionId != selected) continue;
      final name = (companion.displayName ?? '').trim();
      return name.isEmpty ? '这个伙伴' : name;
    }
    return '这个伙伴';
  }

  String get _scopeLabel => _selectedCompanionName == null
      ? '你的全部记忆'
      : '${_selectedCompanionName!}能想起的';

  Future<void> _openSearch() {
    final companionId = _selectedCompanionId;
    if (widget.searchRecollections == null) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecollectionsPage(
          companionName: _selectedCompanionName,
          onSearch: (query) => widget.searchRecollections!(companionId, query),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    if (library != null) {
      return MemoryLibraryPage(
        library: library,
        onOpenRoom: widget.loadCopy == null ? null : _openRoom,
        onForget: _canForget ? _openForget : null,
        onOpenToday: widget.loadDay == null ? null : _openToday,
        onExport: widget.loadCopy == null ? null : _openCopy,
        companions: _companions,
        selectedCompanionId: _selectedCompanionId,
        onCompanionChanged:
            widget.loadForCompanion == null ? null : _selectCompanion,
        onOpenGraph: widget.loadGraph == null ? null : _openGraph,
        onSearch: widget.searchRecollections == null ? null : _openSearch,
        onRefresh: _read,
        refreshError: _refreshError,
      );
    }
    return Scaffold(
      key: const Key('memory-library-screen'),
      appBar: AppBar(title: const Text('你的记忆')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(
                key: Key('memory-library-loading'),
              )
            : RefusalNotice(
                key: const Key('memory-library-error'),
                error: _error!,
                subject: '它记住的',
                onRetry: _read,
                retryKey: const Key('memory-library-retry'),
              ),
      ),
    );
  }
}
