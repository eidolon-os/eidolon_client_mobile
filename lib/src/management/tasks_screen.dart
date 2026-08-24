import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';
import 'tasks_page.dart';

/// Loads the tasks, sends the two actions, and says what the Host answered.
///
/// The state machine is the Host's, so this screen holds no opinion about what a
/// task becomes: it sends the ask, replaces the row with what came back, and puts
/// a refusal on screen in the Host's terms. Three of those refusals are ordinary
/// rather than exceptional — the task finished while the page was open, it cannot
/// be retried from where it is, or this Host has no worker to run it — and each
/// is a sentence rather than an error dialog.
///
/// Re-reads after an action rather than patching the one row, for the same reason
/// the memory pages do: what a person is looking at should be what the Host says,
/// and one action can move more than one field.
class TasksScreen extends StatefulWidget {
  const TasksScreen({
    super.key,
    required this.load,
    this.cancel,
    this.retry,
  });

  final Future<TaskPageView> Function(String? cursor) load;

  /// Null hides the action. Both are needed for either to appear: a page that
  /// offered only half would be a page whose other half silently does nothing.
  final Future<TaskView> Function(String taskId)? cancel;
  final Future<TaskView> Function(String taskId)? retry;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  TaskPageView? _page;
  Object? _error;
  bool _busy = true;
  String? _actingOn;
  String? _notice;
  String? _cursor;

  bool get _canAct => widget.cancel != null && widget.retry != null;

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
      final page = await widget.load(cursor);
      if (!mounted) return;
      setState(() {
        _page = page;
        _cursor = page.nextCursor;
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

  Future<void> _act(
    TaskView task,
    Future<TaskView> Function(String taskId) action,
  ) async {
    setState(() {
      _actingOn = task.taskId;
      _notice = null;
    });
    try {
      final updated = await action(task.taskId);
      if (!mounted) return;
      setState(() => _notice = _becameSentence(updated));
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = _refusalSentence(error));
    } finally {
      if (mounted) setState(() => _actingOn = null);
      // Either way the Host now knows something this screen does not.
      await _read();
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page != null) {
      return TasksPage(
        page: page,
        notice: _notice,
        busyTaskId: _actingOn,
        onCancel: _canAct
            ? (task) => _act(task, widget.cancel!)
            : null,
        onRetry: _canAct ? (task) => _act(task, widget.retry!) : null,
        onLoadMore: _busy || _cursor == null ? null : () => _read(cursor: _cursor),
      );
    }
    return Scaffold(
      key: const Key('tasks-screen'),
      appBar: AppBar(title: const Text('交给它的事')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('tasks-loading'))
            : Padding(
                key: const Key('tasks-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Never an empty list on failure: "it has nothing to do" and
                    // "I could not ask" are different things to be told.
                    Text('$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('tasks-retry-read'),
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

String _becameSentence(TaskView task) {
  switch (task.status) {
    case 'cancelled':
      return '已经停下了';
    case 'accepted':
    case 'queued':
      return '已重新排队';
    default:
      // The Host moved it somewhere this app has no sentence for. Say where.
      return '现在的状态：${task.status}';
  }
}

String _refusalSentence(Object error) {
  if (error is ManagementRequestException) {
    if (error.statusCode == 409) {
      // The common one, and not a fault: the runtime moved while the page was
      // open. The Host's own words carry which way it moved.
      return '主机拒绝了：${error.reason ?? error.message}';
    }
    if (error.statusCode == 503) {
      return '这台主机现在做不了这件事';
    }
    if (error.statusCode == 404) {
      return '这件事已经不在了';
    }
  }
  return '没能改成：$error';
}
