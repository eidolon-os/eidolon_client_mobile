import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'persona_form.dart';
import 'conversation_preferences_form.dart';

/// Two decisions: name and a short description, then review and reply preferences.
class CompanionAuthoringPage extends StatefulWidget {
  const CompanionAuthoringPage({
    super.key,
    required this.template,
    this.presets = const [],
    required this.onCreate,
    this.busy = false,
    this.refusal,
  });

  /// What the Host would write if this form came back untouched.
  final PersonaAuthoring template;
  final List<PersonaPreset> presets;

  /// Hand back a name and the authoring. Null authoring means "as it came" —
  /// see [_authored].
  final Future<void> Function(String displayName, PersonaAuthoring? persona,
      ConversationPreferences? preferences) onCreate;

  final bool busy;

  /// Why the Host said no, in words the person can act on.
  final String? refusal;

  @override
  State<CompanionAuthoringPage> createState() => _CompanionAuthoringPageState();
}

class _CompanionAuthoringPageState extends State<CompanionAuthoringPage> {
  static const _steps = ['认识你的伙伴', '确认设定'];

  final _name = TextEditingController();
  late PersonaForm _form = PersonaForm(widget.template);

  int _step = 0;
  int _presetIndex = 0;
  ConversationPreferences _preferences = ConversationPreferences();
  bool _preferencesChanged = false;

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
      _form.unchanged && widget.presets.isEmpty ? null : _form.authoring;

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
                      onPressed: widget.busy || (_step == 0 && !_named)
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
                                _preferencesChanged ? _preferences : null,
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
            if (widget.presets.isNotEmpty)
              Wrap(spacing: 8, children: [
                for (var i = 0; i < widget.presets.length; i++)
                  ChoiceChip(
                      label: Text(widget.presets[i].title),
                      selected: _presetIndex == i,
                      onSelected: widget.busy
                          ? null
                          : (_) => setState(() {
                                _presetIndex = i;
                                _form.dispose();
                                _form = PersonaForm(widget.presets[i].persona);
                              })),
              ]),
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
            Text('用一句话描述你希望 TA 是什么样的伙伴', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const Key('authoring-short-description'),
              controller: _form.characterPortrait,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => changed(),
              decoration:
                  const InputDecoration(hintText: '例如：温和直接，愿意听我说，说话简短一些'),
            ),
            const SizedBox(height: 12),
            const Text('其他设定已有默认值，创建后仍可调整。'),
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
        Text(_form.characterPortrait.text, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 16),
        ConversationPreferencesForm(
            value: _preferences,
            onChanged: (value) => setState(() {
                  _preferences = value;
                  _preferencesChanged = true;
                })),
        const SizedBox(height: 16),
        const Text('表达示例（说明所选起点风格，不反映自定义修改）'),
        if (widget.presets.isNotEmpty)
          for (final example in widget.presets[_presetIndex].examples)
            Padding(
                padding: const EdgeInsets.only(top: 8), child: Text(example))
        else
          const Text('你：今天有点累。\nTA：辛苦了，先歇一会儿。我在。'),
        const SizedBox(height: 16),
        ExpansionTile(
          key: const Key('authoring-details'),
          title: const Text('详细设定（可选）'),
          children: [
            ..._form.whoItIs(() => setState(() {})),
            ..._form.theRelationship(() => setState(() {})),
            ..._form.howItSpeaks(() => setState(() {})),
          ],
        ),
      ],
    );
  }
}
