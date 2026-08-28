import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// 它做了什么 — what I asked it to do, and whether it did.
///
/// The blueprint's fifth moment. Two things make this page honest, and both are
/// about not speaking for the Host:
///
/// **The state is the Host's word, shown as the Host's word.** This app groups
/// nine possible states into "still going" and "over", because that is the
/// distinction a person acts on — but a state it has never heard of is treated as
/// still going and labelled with what the Host called it, rather than hidden or
/// renamed. A page that dropped an unfamiliar state would make a task disappear
/// while it was running.
///
/// **The two actions are offers, not outcomes.** 别做了 is offered while a task
/// is going and 再试一次 once it has stopped badly, but pressing either sends the
/// ask and shows what came back — including "it had already finished", which is
/// the answer whenever the runtime moved while the page was open.
class TasksPage extends StatelessWidget {
  const TasksPage({
    super.key,
    required this.page,
    this.onCancel,
    this.onRetry,
    this.onLoadMore,
    this.busyTaskId,
    this.notice,
  });

  final TaskPageView page;

  /// Null hides the action rather than disabling it: a control this Host has not
  /// promised is worse than no control.
  final void Function(TaskView task)? onCancel;
  final void Function(TaskView task)? onRetry;

  /// Non-null when the Host said there is another page.
  final VoidCallback? onLoadMore;

  /// The task an action is in flight for, so two taps cannot race.
  final String? busyTaskId;

  /// What the Host said about the last action — including a refusal.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final tasks = page.tasks;
    return Scaffold(
      key: const Key('tasks-page'),
      appBar: AppBar(title: const Text('任务与进度')),
      body: tasks.isEmpty
          ? const Center(
              key: Key('tasks-empty'),
              child: Padding(
                padding: EdgeInsets.all(24),
                // A quiet answer, not a fault: most days nobody delegates
                // anything.
                child: Text('还没有长期任务'),
              ),
            )
          : ListView.separated(
              key: const Key('tasks-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount:
                  tasks.length +
                  (onLoadMore == null ? 0 : 1) +
                  (notice == null ? 0 : 1),
              separatorBuilder: (_, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (notice != null && index == 0) {
                  return Padding(
                    key: const Key('tasks-notice'),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Text(
                      notice!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                }
                final offset = index - (notice == null ? 0 : 1);
                if (offset == tasks.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      key: const Key('tasks-load-more'),
                      onPressed: onLoadMore,
                      child: const Text('看更早的'),
                    ),
                  );
                }
                final task = tasks[offset];
                return _TaskRow(
                  task: task,
                  busy: busyTaskId == task.taskId,
                  onCancel: onCancel == null || _isOver(task.status)
                      ? null
                      : () => onCancel!(task),
                  onRetry: onRetry == null || !_isRetryable(task.status)
                      ? null
                      : () => onRetry!(task),
                );
              },
            ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.busy,
    this.onCancel,
    this.onRetry,
  });

  final TaskView task;
  final bool busy;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress ?? '';
    final result = task.result ?? '';
    final error = task.errorMessage ?? '';
    return ListTile(
      key: Key('task-${task.taskId}'),
      isThreeLine: true,
      title: Text(
        (task.asked ?? '').isEmpty ? '（没有记下要做什么）' : task.asked!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(_stateSentence(task)),
          // Shown in this order because it is the order a person asks in: what
          // is it doing, what did it produce, why did it stop.
          if (result.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(result, maxLines: 3, overflow: TextOverflow.ellipsis),
            )
          else if (progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                progress,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : onCancel != null
          ? IconButton(
              key: Key('task-cancel-${task.taskId}'),
              tooltip: '别做了',
              onPressed: onCancel,
              icon: const Icon(Icons.stop_circle_outlined),
            )
          : onRetry != null
          ? IconButton(
              key: Key('task-retry-${task.taskId}'),
              tooltip: '再试一次',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            )
          : null,
    );
  }
}

/// Still going, as far as this app can tell.
///
/// The list is the Host's, and anything unrecognised counts as still going: a
/// task in a state this release has not heard of is running somewhere, and
/// treating it as finished would offer 再试一次 for work already in progress.
bool _isOver(String status) =>
    const {'succeeded', 'failed', 'cancelled', 'timed_out'}.contains(status);

/// Stopped without doing the job. Not `succeeded`: asking for finished work
/// again is a new task, and the Host refuses it anyway.
bool _isRetryable(String status) =>
    const {'failed', 'cancelled', 'timed_out'}.contains(status);

String _stateSentence(TaskView task) {
  switch (task.status) {
    case 'succeeded':
      return '做完了';
    case 'failed':
      return '没做成';
    case 'cancelled':
      return '已取消';
    case 'timed_out':
      return '超时了';
    case 'running':
    case 'submitted':
      return '正在做';
    case 'accepted':
    case 'created':
    case 'queued':
      return '排着队';
    default:
      // The Host's own word. Not "unknown": a person reading their own screen
      // deserves the thing it was actually called.
      return '状态：${task.status}';
  }
}
