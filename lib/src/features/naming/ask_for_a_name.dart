import 'package:flutter/material.dart';

/// Ask what something should be called.
///
/// Every resource an Owner can see — the Eidolon, a device, later a face or a
/// memory — is named the same way, so the rule about what counts as an answer
/// belongs here rather than being retyped beside each screen:
///
///  * a name is trimmed, because trailing space is a typing accident;
///  * cancelling and clearing the box both mean *leave it alone*, and both come
///    back as null — no screen may take a name away by way of a rename box;
///  * the field owns its own controller for as long as the dialog is on screen,
///    including the frames it spends animating out. Disposing at the call site
///    the moment the route pops looks correct and is not: the dialog is rebuilt
///    once more on the way out, and by then the controller is gone.
Future<String?> askForAName(
  BuildContext context, {
  required String question,
  required String hint,
  String current = '',
  Key? dialogKey,
  Key? fieldKey,
  Key? confirmKey,
}) async {
  final chosen = await showDialog<String>(
    context: context,
    builder: (dialogContext) => _NameDialog(
      key: dialogKey,
      question: question,
      hint: hint,
      current: current,
      fieldKey: fieldKey,
      confirmKey: confirmKey,
    ),
  );
  final name = chosen?.trim();
  if (name == null || name.isEmpty) return null;
  return name;
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    super.key,
    required this.question,
    required this.hint,
    required this.current,
    this.fieldKey,
    this.confirmKey,
  });

  final String question;
  final String hint;
  final String current;
  final Key? fieldKey;
  final Key? confirmKey;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.question),
      content: TextField(
        key: widget.fieldKey,
        controller: _field,
        autofocus: true,
        maxLength: 128,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
