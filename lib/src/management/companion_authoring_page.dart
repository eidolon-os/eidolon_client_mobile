import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'persona_form.dart';

/// Saying who a new Eidolon is, before it has been anything.
///
/// This replaced a dialog that asked for a name and nothing else, which meant
/// every Eidolon this Host made was the same person under a different label.
/// The fields are the ones the Admin web page had before it was removed —
/// deliberately the same set, because that page's grouping was already the
/// right one: who TA is, what you two are to each other, how TA comes across.
///
/// Three decisions this screen makes, none of them cosmetic:
///
/// **It starts filled in.** The Host is asked what it would write if nobody
/// said anything, and that is what appears. An empty box labelled 人格画像 asks
/// somebody to invent a personality from nothing; a filled one asks them to
/// change something they can read. It also means the whole screen is skippable
/// — 继续、继续、创建 gives the Eidolon the Host would have made anyway, so
/// adding a second Eidolon never *requires* writing an essay.
///
/// **One step per screen.** Thirteen fields on one scroll is a form; four short
/// pages with a question at the top of each is a conversation. The keyboard
/// covers half a phone, so a step that fits above it is the unit that works.
///
/// **Nothing is required except the name.** Every other field has a value
/// already, and a blank one is a deliberate blank rather than an error — the
/// person is describing someone, and refusing to continue because they have not
/// yet decided what TA will not do would be the screen overruling them.
class CompanionAuthoringPage extends StatefulWidget {
  const CompanionAuthoringPage({
    super.key,
    required this.template,
    required this.onCreate,
    this.busy = false,
    this.refusal,
  });

  /// What the Host would write if this form came back untouched.
  final PersonaAuthoring template;

  /// Hand back a name and the authoring. Null authoring means "as it came" —
  /// see [_authored].
  final Future<void> Function(String displayName, PersonaAuthoring? persona)
      onCreate;

  final bool busy;

  /// Why the Host said no, in words the person can act on.
  final String? refusal;

  @override
  State<CompanionAuthoringPage> createState() => _CompanionAuthoringPageState();
}

class _CompanionAuthoringPageState extends State<CompanionAuthoringPage> {
  static const _steps = ['TA 是谁', '你们的关系', 'TA 如何表达', '确认'];

  final _name = TextEditingController();
  late final PersonaForm _form = PersonaForm(widget.template);

  int _step = 0;

  @override
  void dispose() {
    _name.dispose();
    _form.dispose();
    super.dispose();
  }

  /// The authoring as it now stands, or null if nobody changed anything.
  ///
  /// Null matters on the wire: the Host omits the field entirely, which is the
  /// same request an older client sends, which is what keeps a retry after a
  /// lost answer a replay rather than a conflict. Sending back a copy of the
  /// template would work and would also quietly claim the person authored it.
  PersonaAuthoring? _authored() =>
      _form.unchanged ? null : _form.authoring;

  bool get _named => _name.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('companion-authoring-page'),
      appBar: AppBar(
        title: Text(_steps[_step]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            key: const Key('authoring-progress'),
            value: (_step + 1) / _steps.length,
            minHeight: 4,
          ),
        ),
      ),
      body: Column(
        children: [
          if (widget.refusal != null)
            MaterialBanner(
              key: const Key('authoring-refusal'),
              content: Text(widget.refusal!),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: _body(theme),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  if (_step > 0)
                    TextButton.icon(
                      key: const Key('authoring-back'),
                      onPressed:
                          widget.busy ? null : () => setState(() => _step -= 1),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('上一步'),
                    ),
                  const Spacer(),
                  if (_step < _steps.length - 1)
                    FilledButton.icon(
                      key: const Key('authoring-next'),
                      // The name is the one thing that cannot be defaulted, so
                      // it is also the only thing that blocks the first step.
                      onPressed: _step == 0 && !_named
                          ? null
                          : () => setState(() => _step += 1),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('继续'),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('authoring-create'),
                      onPressed: widget.busy || !_named
                          ? null
                          : () => widget.onCreate(
                                _name.text.trim(),
                                _authored(),
                              ),
                      icon: widget.busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome),
                      label: Text(widget.busy ? '正在创建' : '创建'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    void changed() => setState(() {});
    switch (_step) {
      case 0:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('名字', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const Key('authoring-name'),
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: '比如「小南」'),
            ),
            const SizedBox(height: 24),
            ..._form.whoItIs(changed),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _form.theRelationship(changed),
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _form.howItSpeaks(changed),
        );
      default:
        return _review(theme);
    }
  }

  /// What is about to be created, in the person's own words.
  ///
  /// Assembled from what is on this screen rather than fetched back, because
  /// there is nothing on the Host to fetch yet — and the fields have not been
  /// through anything that could change them, so a round trip would only add a
  /// way for the review to be wrong.
  Widget _review(ThemeData theme) {
    final written = _form.authoring;
    final sections = <(String, String, List<String>)>[
      ('自我认知', written.selfConcept ?? '', written.values ?? const []),
      ('人格画像', written.characterPortrait ?? '', written.boundaries ?? const []),
      (
        '关系',
        written.relationshipNarrative ?? '',
        [
          ...?written.commitments,
          ...?written.pinnedFacts,
          ...?written.safetyBoundaries,
        ],
      ),
      (
        '表达',
        written.voicePortrait ?? '',
        [...?written.behaviorGuidance, ...?written.dialogueExamples],
      ),
    ];
    return Column(
      key: const Key('authoring-review'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _name.text.trim().isEmpty ? 'TA' : _name.text.trim(),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          _authored() == null ? '和这台主机默认会写的一样 — 你也可以回去改。' : '这是你写下的。创建之后仍然可以改。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        for (final (title, prose, lines) in sections) ...[
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (prose.isNotEmpty)
            Text(prose, style: theme.textTheme.bodyMedium)
          else
            Text(
              '（没写）',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 8),
              child: Text('· $line', style: theme.textTheme.bodyMedium),
            ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}
