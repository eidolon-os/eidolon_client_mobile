import 'package:flutter/material.dart';

import 'tools_wording.dart';

/// What the tool screens have in common: how they say a change landed, how a
/// group is titled, and how a screen that could not read says so.

void sayToolNotice(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

class ToolGroupHeader extends StatelessWidget {
  const ToolGroupHeader({super.key, required this.group, this.action});
  final String group;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 0, 4),
        child: Row(children: [
          Expanded(
            child: Text(toolGroupLabel(group),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          if (action case final action?) action,
        ]),
      );
}

/// 系统, last and folded: tools nobody can switch, shown so that nothing the
/// Host could hand a conversation is hidden from its Owner.
class ToolSystemGroup extends StatelessWidget {
  const ToolSystemGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Card(
          child: ExpansionTile(
            key: const Key('tools-group-system'),
            title: Text(toolGroupLabel(systemToolGroup)),
            children: children,
          ),
        ),
      );
}

/// The lock where a switch would be.
class ToolLock extends StatelessWidget {
  const ToolLock({super.key});

  @override
  Widget build(BuildContext context) => const Icon(Icons.lock_outline);
}

class ToolsUnreadable extends StatelessWidget {
  const ToolsUnreadable(
      {super.key, required this.failure, required this.retry});
  final String failure;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(failure, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ]),
        ),
      );
}
