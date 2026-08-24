import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
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
  const MemoryLibraryScreen({super.key, required this.load});

  final Future<MemoryLibraryView> Function() load;

  @override
  State<MemoryLibraryScreen> createState() => _MemoryLibraryScreenState();
}

class _MemoryLibraryScreenState extends State<MemoryLibraryScreen> {
  MemoryLibraryView? _library;
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
      final library = await widget.load();
      if (!mounted) return;
      setState(() {
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

  @override
  Widget build(BuildContext context) {
    final library = _library;
    if (library != null) {
      return MemoryLibraryPage(library: library);
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
