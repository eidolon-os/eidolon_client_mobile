import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'authoring_lines.dart';

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
  late final TextEditingController _selfConcept;
  late final TextEditingController _characterPortrait;
  late final TextEditingController _relationshipNarrative;
  late final TextEditingController _voicePortrait;

  late List<String> _values;
  late List<String> _boundaries;
  late List<String> _commitments;
  late List<String> _pinnedFacts;
  late List<String> _safetyBoundaries;
  late List<String> _behaviorGuidance;
  late List<String> _dialogueExamples;

  int _step = 0;

  @override
  void initState() {
    super.initState();
    final template = widget.template;
    _selfConcept = TextEditingController(text: template.selfConcept ?? '');
    _characterPortrait =
        TextEditingController(text: template.characterPortrait ?? '');
    _relationshipNarrative =
        TextEditingController(text: template.relationshipNarrative ?? '');
    _voicePortrait = TextEditingController(text: template.voicePortrait ?? '');
    _values = [...?template.values];
    _boundaries = [...?template.boundaries];
    _commitments = [...?template.commitments];
    _pinnedFacts = [...?template.pinnedFacts];
    _safetyBoundaries = [...?template.safetyBoundaries];
    _behaviorGuidance = [...?template.behaviorGuidance];
    _dialogueExamples = [...?template.dialogueExamples];
  }

  @override
  void dispose() {
    _name.dispose();
    _selfConcept.dispose();
    _characterPortrait.dispose();
    _relationshipNarrative.dispose();
    _voicePortrait.dispose();
    super.dispose();
  }

  /// The authoring as it now stands, or null if nobody changed anything.
  ///
  /// Null matters on the wire: the Host omits the field entirely, which is the
  /// same request an older client sends, which is what keeps a retry after a
  /// lost answer a replay rather than a conflict. Sending back a copy of the
  /// template would work and would also quietly claim the person authored it.
  PersonaAuthoring? _authored() {
    final draft = PersonaAuthoring(
      archetype: widget.template.archetype,
      selfConcept: _selfConcept.text.trim(),
      characterPortrait: _characterPortrait.text.trim(),
      relationshipNarrative: _relationshipNarrative.text.trim(),
      voicePortrait: _voicePortrait.text.trim(),
      values: _values,
      boundaries: _boundaries,
      commitments: _commitments,
      pinnedFacts: _pinnedFacts,
      safetyBoundaries: _safetyBoundaries,
      behaviorGuidance: _behaviorGuidance,
      dialogueExamples: _dialogueExamples,
      modalityNotes: widget.template.modalityNotes,
      traits: widget.template.traits,
    );
    return _sameAsTemplate(draft) ? null : draft;
  }

  bool _sameAsTemplate(PersonaAuthoring draft) {
    final template = widget.template;
    bool sameLines(List<String>? mine, List<String>? theirs) {
      final a = mine ?? const [];
      final b = theirs ?? const [];
      return a.length == b.length &&
          List.generate(a.length, (index) => a[index] == b[index])
              .every((equal) => equal);
    }

    return draft.selfConcept == (template.selfConcept ?? '') &&
        draft.characterPortrait == (template.characterPortrait ?? '') &&
        draft.relationshipNarrative == (template.relationshipNarrative ?? '') &&
        draft.voicePortrait == (template.voicePortrait ?? '') &&
        sameLines(draft.values, template.values) &&
        sameLines(draft.boundaries, template.boundaries) &&
        sameLines(draft.commitments, template.commitments) &&
        sameLines(draft.pinnedFacts, template.pinnedFacts) &&
        sameLines(draft.safetyBoundaries, template.safetyBoundaries) &&
        sameLines(draft.behaviorGuidance, template.behaviorGuidance) &&
        sameLines(draft.dialogueExamples, template.dialogueExamples);
  }

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
            AuthoringProse(
              fieldKey: const Key('authoring-self-concept'),
              label: '自我认知',
              help: 'TA 认为自己是什么。用 TA 的口吻写。',
              controller: _selfConcept,
            ),
            const SizedBox(height: 24),
            AuthoringProse(
              fieldKey: const Key('authoring-character-portrait'),
              label: '人格画像',
              help: '别人会怎么形容 TA。',
              controller: _characterPortrait,
              minLines: 4,
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-values'),
              label: '价值观',
              help: 'TA 长期坚持的东西。',
              hint: '一条长期坚持的价值',
              lines: _values,
              onChanged: (lines) => setState(() => _values = lines),
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-boundaries'),
              label: '不可突破的边界',
              help: 'TA 无论如何都不会做的事。',
              hint: '一条绝不跨过的边界',
              lines: _boundaries,
              onChanged: (lines) => setState(() => _boundaries = lines),
            ),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AuthoringProse(
              fieldKey: const Key('authoring-relationship'),
              label: '关系叙事',
              help: '你和 TA 是什么关系，从哪里开始的。',
              controller: _relationshipNarrative,
              minLines: 4,
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-commitments'),
              label: '关系承诺',
              help: 'TA 对这段关系许下的事。',
              hint: 'TA 对这段关系的一条承诺',
              lines: _commitments,
              onChanged: (lines) => setState(() => _commitments = lines),
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-pinned-facts'),
              label: '已确认事实',
              help: '关于你的、TA 一开始就该知道的事。',
              hint: '关于你已确认的事实',
              lines: _pinnedFacts,
              onChanged: (lines) => setState(() => _pinnedFacts = lines),
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-safety-boundaries'),
              label: '关系安全边界',
              help: '在你们之间始终要守住的东西。',
              hint: '在关系中需要始终遵守的边界',
              lines: _safetyBoundaries,
              onChanged: (lines) => setState(() => _safetyBoundaries = lines),
            ),
          ],
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AuthoringProse(
              fieldKey: const Key('authoring-voice-portrait'),
              label: '表达画像',
              help: 'TA 说话是什么样的。',
              controller: _voicePortrait,
              minLines: 4,
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-behavior-guidance'),
              label: '行为引导',
              help: '看得出来的表达习惯。',
              hint: '一条可观察的表达习惯',
              lines: _behaviorGuidance,
              onChanged: (lines) => setState(() => _behaviorGuidance = lines),
            ),
            const SizedBox(height: 24),
            AuthoringLines(
              fieldKey: const Key('authoring-dialogue-examples'),
              label: '典型对话示例',
              help: '一句能代表 TA 的话。',
              hint: '一段能代表 TA 的自然表达',
              lines: _dialogueExamples,
              onChanged: (lines) => setState(() => _dialogueExamples = lines),
            ),
          ],
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
    final sections = <(String, String, List<String>)>[
      ('自我认知', _selfConcept.text.trim(), _values),
      ('人格画像', _characterPortrait.text.trim(), _boundaries),
      (
        '关系',
        _relationshipNarrative.text.trim(),
        [..._commitments, ..._pinnedFacts, ..._safetyBoundaries],
      ),
      (
        '表达',
        _voicePortrait.text.trim(),
        [..._behaviorGuidance, ..._dialogueExamples],
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
