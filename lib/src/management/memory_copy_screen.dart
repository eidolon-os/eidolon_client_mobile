import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';
import 'memory_copy_page.dart';

/// Loads the copy, and says when it has been taken away.
///
/// One read, no window and no paging: the whole point of this page is that it
/// does not ask for a slice. The only state worth holding is the copy itself,
/// whether the read failed, and whether the person has already copied it — the
/// last one because pressing a button that gives no sign of having worked is how
/// someone copies their memory four times and trusts none of them.
class MemoryCopyScreen extends StatefulWidget {
  const MemoryCopyScreen({super.key, required this.load, this.clipboard});

  final Future<MemoryCopyView> Function() load;

  /// Injected in tests. The real one is the platform's.
  final Future<void> Function(String text)? clipboard;

  @override
  State<MemoryCopyScreen> createState() => _MemoryCopyScreenState();
}

class _MemoryCopyScreenState extends State<MemoryCopyScreen> {
  MemoryCopyView? _copy;
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
      final copy = await widget.load();
      if (!mounted) return;
      setState(() {
        _copy = copy;
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
    final copy = _copy;
    if (copy != null) {
      return MemoryCopyPage(
        copy: copy,
        clipboard: widget.clipboard,
        onCopied: () {
          final messenger = ScaffoldMessenger.maybeOf(context);
          messenger?.showSnackBar(
            const SnackBar(
              key: Key('memory-copy-done'),
              content: Text('已复制到剪贴板'),
            ),
          );
        },
      );
    }
    return Scaffold(
      key: const Key('memory-copy-screen'),
      appBar: AppBar(title: const Text('导出记忆')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('memory-copy-loading'))
            : Padding(
                key: const Key('memory-copy-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Never an empty copy: someone who saved one would believe
                    // their Eidolon remembers nothing.
                    Text(
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException).hostHasNoOwner
                          ? '这台主机还没有主人，先完成设置'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('memory-copy-retry'),
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
