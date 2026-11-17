import 'dart:async';

import 'package:flutter/material.dart';

import 'tool_policies.dart';
import 'tools_wording.dart';

/// 「它能做的事」 on an Eidolon's page, saying how many tools it can use.
///
/// Reads its own line, and again after the page it opens closes, so the
/// sentence under it is always the Host's latest answer rather than one the
/// page that holds it would have to remember to refresh.
class CompanionToolsTile extends StatefulWidget {
  const CompanionToolsTile({
    super.key,
    required this.companionId,
    required this.tools,
    required this.onOpen,
  });

  final String companionId;
  final ToolPolicies tools;
  final Future<void> Function() onOpen;

  @override
  State<CompanionToolsTile> createState() => _CompanionToolsTileState();
}

class _CompanionToolsTileState extends State<CompanionToolsTile> {
  String? _line;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final view = await widget.tools.companion(widget.companionId);
      if (mounted) setState(() => _line = companionToolsLine(view));
    } catch (_) {
      // The row still opens; the page says what went wrong.
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
        key: const Key('companion-tools'),
        leading: const Icon(Icons.handyman_outlined),
        title: const Text('它能做的事'),
        subtitle: Text(_line ?? '决定它在对话里能用哪些工具'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await widget.onOpen();
          await _read();
        },
      );
}
