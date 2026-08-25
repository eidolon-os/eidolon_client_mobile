import 'package:flutter/material.dart';

/// A list of short lines somebody writes one at a time.
///
/// Six of the fields on the create form are lists of sentences — values,
/// boundaries, commitments, facts, habits, examples. The old web page used one
/// editor for all of them, and that was right for a reason worth keeping: these
/// are the same *act* (say one more thing) and a screen that made them look
/// different would be inventing distinctions the person does not have.
///
/// Shaped for a thumb rather than ported from the web:
///
///  * the field submits on the keyboard's own action and **keeps focus**, so
///    three values in a row is type-return-type-return, not a hunt for a button
///    between each one;
///  * an entry is removed by the × on its own row. No long-press, no swipe —
///    both hide the only destructive action on the screen behind a gesture
///    nobody is told about;
///  * blank and duplicate entries are dropped rather than refused. Somebody
///    hitting return twice is not making a mistake worth a message.
class AuthoringLines extends StatefulWidget {
  const AuthoringLines({
    super.key,
    required this.label,
    required this.hint,
    required this.lines,
    required this.onChanged,
    this.help,
    this.fieldKey,
  });

  final String label;

  /// What one entry looks like. Carries the example, so the person is not
  /// guessing at the size of the thing being asked for.
  final String hint;

  /// Why this list exists, in a sentence. The web page had room for a label
  /// alone; a phone has less room and more need to say what a field is for.
  final String? help;

  final List<String> lines;
  final ValueChanged<List<String>> onChanged;
  final Key? fieldKey;

  @override
  State<AuthoringLines> createState() => _AuthoringLinesState();
}

class _AuthoringLinesState extends State<AuthoringLines> {
  final _entry = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _entry.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add(String raw) {
    final line = raw.trim();
    // Nothing to say and already said are both "no change", and neither is
    // worth interrupting someone mid-thought to explain.
    if (line.isEmpty || widget.lines.contains(line)) {
      _entry.clear();
      _focus.requestFocus();
      return;
    }
    widget.onChanged([...widget.lines, line]);
    _entry.clear();
    // Stay put. Somebody adding one value usually has a second one in mind.
    _focus.requestFocus();
  }

  void _remove(String line) {
    widget.onChanged(widget.lines.where((each) => each != line).toList());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: theme.textTheme.titleSmall),
        if (widget.help != null) ...[
          const SizedBox(height: 2),
          Text(
            widget.help!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 8),
        for (final line in widget.lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(child: Text(line, style: theme.textTheme.bodyMedium)),
                IconButton(
                  key: Key('remove-line-$line'),
                  visualDensity: VisualDensity.compact,
                  tooltip: '去掉这一条',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _remove(line),
                ),
              ],
            ),
          ),
        TextField(
          key: widget.fieldKey,
          controller: _entry,
          focusNode: _focus,
          textInputAction: TextInputAction.done,
          onSubmitted: _add,
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            suffixIcon: IconButton(
              tooltip: '加一条',
              icon: const Icon(Icons.add),
              onPressed: () => _add(_entry.text),
            ),
          ),
        ),
      ],
    );
  }
}

/// One paragraph somebody writes about their Eidolon.
///
/// Multiline and growing rather than a fixed box: on a phone a box that stops
/// growing at three lines tells the person to stop writing, and what is being
/// asked for here is not a form value but a description.
class AuthoringProse extends StatelessWidget {
  const AuthoringProse({
    super.key,
    required this.label,
    required this.controller,
    this.help,
    this.minLines = 3,
    this.fieldKey,
  });

  final String label;
  final String? help;
  final TextEditingController controller;
  final int minLines;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleSmall),
        if (help != null) ...[
          const SizedBox(height: 2),
          Text(
            help!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: fieldKey,
          controller: controller,
          minLines: minLines,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
        ),
      ],
    );
  }
}
