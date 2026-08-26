import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'persona_form.dart';

/// Changing who an Eidolon is, after it has been someone for a while.
///
/// One scrolling page rather than the four steps that creating one uses, and
/// the difference is deliberate. Creating is a walk through questions somebody
/// has not been asked yet; editing is almost always coming to change **one**
/// thing, and making them page through three screens to reach it would be
/// charging a guided tour for a sentence.
///
/// It opens on who the Eidolon currently is, never on the template. That is
/// what makes saving safe: everything not touched goes back exactly as it came,
/// including the parts this form does not show.
///
/// Saving with nothing changed is not an error and not a write — the button is
/// simply inert, because pressing it would either lie or add a chapter to the
/// record for something that did not happen.
class PersonaEditPage extends StatefulWidget {
  const PersonaEditPage({
    super.key,
    required this.displayName,
    required this.standing,
    required this.onSave,
    this.busy = false,
    this.refusal,
  });

  /// What it is called, for the title. Not editable here: what it is called and
  /// who it is are two decisions, and renaming lives beside the name.
  final String displayName;

  /// Who it is now, as the Host answered a moment ago.
  final PersonaAuthoring standing;

  final Future<void> Function(PersonaAuthoring authored) onSave;
  final bool busy;
  final String? refusal;

  @override
  State<PersonaEditPage> createState() => _PersonaEditPageState();
}

class _PersonaEditPageState extends State<PersonaEditPage> {
  late final PersonaForm _form = PersonaForm(widget.standing);

  @override
  void initState() {
    super.initState();
    // Prose fields are not rebuilt on every keystroke by their controllers, but
    // whether anything changed is — that is what makes 保存 come alive the
    // moment a person actually changes something.
    for (final field in [
      _form.selfConcept,
      _form.characterPortrait,
      _form.relationshipNarrative,
      _form.voicePortrait,
    ]) {
      field.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unchanged = _form.unchanged;
    return Scaffold(
      key: const Key('persona-edit-page'),
      appBar: AppBar(title: Text('${widget.displayName} 是谁')),
      body: Column(
        children: [
          if (widget.refusal != null)
            MaterialBanner(
              key: const Key('persona-edit-refusal'),
              content: Text(widget.refusal!),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '改了之后它就是这样。以前是什么样仍然记着。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _heading(theme, 'TA 是谁'),
                  ..._form.whoItIs(_changed),
                  const SizedBox(height: 32),
                  _heading(theme, '你们的关系'),
                  ..._form.theRelationship(_changed),
                  const SizedBox(height: 32),
                  _heading(theme, 'TA 如何表达'),
                  ..._form.howItSpeaks(_changed),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  if (unchanged)
                    Text(
                      '还没有改动',
                      key: const Key('persona-edit-unchanged'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    key: const Key('persona-edit-save'),
                    onPressed: widget.busy || unchanged
                        ? null
                        : () => widget.onSave(_form.authoring),
                    icon: widget.busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(widget.busy ? '正在保存' : '保存'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(title, style: theme.textTheme.titleMedium),
      );
}
