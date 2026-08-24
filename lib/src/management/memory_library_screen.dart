import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'forget_sheet.dart';
import 'management_client.dart';
import 'memory_library_page.dart';

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
    this.loadContext,
    this.previewForget,
    this.confirmForget,
  });

  final Future<MemoryLibraryView> Function() load;

  /// Read once, for the one thing this screen cannot infer: whether this Host
  /// can govern memory at all.
  final Future<ManagementContextView> Function()? loadContext;

  final Future<ForgetProposalView> Function(String target)? previewForget;
  final Future<ForgetResultView> Function(String confirmationToken)? confirmForget;

  @override
  State<MemoryLibraryScreen> createState() => _MemoryLibraryScreenState();
}

class _MemoryLibraryScreenState extends State<MemoryLibraryScreen> {
  MemoryLibraryView? _library;
  ManagementContextView? _context;
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
      // Asked for together: a library drawn before the Host said what it can do
      // would either hide an action it allows or offer one it does not.
      final context =
          widget.loadContext == null ? null : await widget.loadContext!();
      final library = await widget.load();
      if (!mounted) return;
      setState(() {
        _context = context;
        _library = library;
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

  bool get _canForget =>
      widget.previewForget != null &&
      widget.confirmForget != null &&
      _context != null &&
      hostCan(_context!, 'memory.govern');

  /// Opened as its own screen rather than a dialog: what is about to be removed
  /// has to be readable, and a list inside a dialog is where that gets cramped.
  Future<void> _openForget() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ForgetSheet(
          preview: widget.previewForget!,
          confirm: widget.confirmForget!,
        ),
      ),
    );
    if (!mounted) return;
    // Something may be gone now. Re-read rather than patch: the Host says what
    // is remembered, and a stale library after a deletion is exactly the moment
    // a person would stop trusting this screen.
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    if (library != null) {
      return MemoryLibraryPage(
        library: library,
        onForget: _canForget ? _openForget : null,
      );
    }
    return Scaffold(
      key: const Key('memory-library-screen'),
      appBar: AppBar(title: const Text('它记住的')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('memory-library-loading'))
            : Padding(
                key: const Key('memory-library-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException).hostHasNoOwner
                          ? '这台主机还没有主人，先完成设置'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('memory-library-retry'),
                      onPressed: _read,
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
