import 'package:flutter/material.dart';
import '../generated/management_v1.dart';
import 'conversation_preferences_form.dart';
import 'persona_form.dart';
import 'persona_preview_panel.dart';

/// The roster owns drafts across navigation; each starting point has its own.
class CompanionCreationDrafts {
  CompanionCreationDrafts(
      PersonaAuthoring template, List<PersonaPreset> presets)
      : custom = CompanionDraft('', template, const ConversationPreferences()),
        presets = {
          for (final p in presets)
            p.presetId: CompanionDraft(p.defaultName, p.persona, p.preferences)
        },
        selectedId = presets.isEmpty ? null : presets.first.presetId;
  final CompanionDraft custom;
  final Map<String, CompanionDraft> presets;
  String? selectedId;
  CompanionDraft get selected => presets[selectedId] ?? custom;
  void dispose() {
    custom.dispose();
    for (final draft in presets.values) {
      draft.dispose();
    }
  }
}

class CompanionDraft {
  CompanionDraft(String name, PersonaAuthoring persona, this.preferences)
      : name = TextEditingController(text: name),
        form = PersonaForm(persona);
  final TextEditingController name;
  final PersonaForm form;
  ConversationPreferences preferences;
  void dispose() {
    name.dispose();
    form.dispose();
  }
}

class CompanionAuthoringPage extends StatefulWidget {
  const CompanionAuthoringPage(
      {super.key,
      required this.template,
      this.presets = const [],
      this.drafts,
      required this.onCreate,
      this.preview,
      this.busy = false,
      this.locked = false,
      this.refusal});
  final PersonaAuthoring template;
  final List<PersonaPreset> presets;
  final CompanionCreationDrafts? drafts;
  final Future<void> Function(
      String, PersonaAuthoring?, ConversationPreferences?) onCreate;
  final PreviewPersona? preview;
  final bool busy;
  final bool locked;
  final String? refusal;
  @override
  State<CompanionAuthoringPage> createState() => _CompanionAuthoringPageState();
}

class _CompanionAuthoringPageState extends State<CompanionAuthoringPage> {
  late final _drafts =
      widget.drafts ?? CompanionCreationDrafts(widget.template, widget.presets);
  bool _editing = false;
  bool _review = false;
  CompanionDraft get _draft => _drafts.selected;
  bool get _custom => _drafts.selectedId == null;
  bool get _disabled => widget.busy || widget.locked;
  bool get _valid => _draft.name.text.trim().isNotEmpty;
  @override
  void initState() {
    super.initState();
    _editing = _drafts.selectedId == null;
  }

  @override
  void dispose() {
    if (widget.drafts == null) _drafts.dispose();
    super.dispose();
  }

  void _back() {
    if (widget.busy) return;
    if (widget.locked) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_editing || _review) {
      setState(() {
        _editing = false;
        _review = false;
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inner = _editing || _review;
    return PopScope(
        canPop: !widget.busy && (!inner || widget.locked),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && inner) _back();
        },
        child: Scaffold(
            key: const Key('companion-authoring-page'),
            appBar: AppBar(
                title: Text(_review
                    ? '确认你的伙伴'
                    : _editing
                        ? (_custom ? '自定义伙伴' : '调整伙伴')
                        : '认识一个新伙伴'),
                leading: inner
                    ? IconButton(
                        onPressed: widget.busy ? null : _back,
                        tooltip:
                            MaterialLocalizations.of(context).backButtonTooltip,
                        icon: const Icon(Icons.arrow_back))
                    : null),
            body: Column(children: [
              if (widget.refusal != null)
                MaterialBanner(
                    key: const Key('authoring-refusal'),
                    content: Text(widget.refusal!),
                    actions: const [SizedBox.shrink()]),
              Expanded(
                  child: AbsorbPointer(
                      absorbing: _disabled,
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 760),
                                  child: inner
                                      ? _form(theme)
                                      : _selection(theme)))))),
              SafeArea(
                  top: false,
                  child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Row(children: [
                        Expanded(
                            child: Text(
                                widget.locked
                                    ? '重试将确认同一次创建，不会重复添加。'
                                    : '创建后也可以随时调整。',
                                style: theme.textTheme.bodySmall)),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                            key: Key(_custom &&
                                    _editing &&
                                    !_review &&
                                    !widget.locked
                                ? 'authoring-next'
                                : 'authoring-create'),
                            onPressed:
                                widget.busy || (!_valid && !widget.locked)
                                    ? null
                                    : () {
                                        if (_custom &&
                                            _editing &&
                                            !_review &&
                                            !widget.locked) {
                                          setState(() => _review = true);
                                        } else {
                                          widget.onCreate(
                                              _draft.name.text.trim(),
                                              _draft.form.authoring,
                                              _draft.preferences);
                                        }
                                      },
                            icon: widget.busy
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.auto_awesome),
                            label: Text(widget.busy
                                ? '正在创建'
                                : widget.locked
                                    ? '重试创建'
                                    : _custom && _editing && !_review
                                        ? '继续'
                                        : '创建伙伴')),
                      ]))),
            ])));
  }

  Widget _selection(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('你想认识怎样的伙伴？', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('选一个合拍的，就可以开始。名字和设定都能再改。'),
        const SizedBox(height: 20),
        for (final p in widget.presets) ...[
          Card(
              clipBehavior: Clip.antiAlias,
              color: _drafts.selectedId == p.presetId
                  ? theme.colorScheme.secondaryContainer
                  : null,
              child: InkWell(
                  key: Key('preset-${p.presetId}'),
                  onTap: () => setState(() => _drafts.selectedId = p.presetId),
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        CircleAvatar(
                            child: Text(p.defaultName.characters.first)),
                        const SizedBox(width: 16),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text('${p.defaultName} · ${p.title}',
                                  style: theme.textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text(p.description),
                              if (_drafts.selectedId == p.presetId &&
                                  p.examples.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(p.examples.first,
                                    style: theme.textTheme.bodySmall)
                              ],
                            ])),
                        const SizedBox(width: 8),
                        Icon(_drafts.selectedId == p.presetId
                            ? Icons.check_circle
                            : Icons.circle_outlined),
                      ])))),
          const SizedBox(height: 6)
        ],
        OutlinedButton.icon(
            key: const Key('authoring-custom'),
            onPressed: () => setState(() {
                  _drafts.selectedId = null;
                  _editing = true;
                  _review = false;
                }),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('自己定义一个伙伴')),
        const SizedBox(height: 16),
        if (!_custom) ...[
          Text('即将认识：${_draft.name.text.trim()}',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  key: const Key('authoring-customize'),
                  onPressed: () => setState(() => _editing = true),
                  icon: const Icon(Icons.tune),
                  label: const Text('改名字或调整设定')))
        ],
        if (_custom && _draft.name.text.trim().isNotEmpty)
          Text('自定义草稿：${_draft.name.text.trim()}'),
      ]);
  Widget _form(ThemeData theme) => Column(
          key: Key(_review ? 'authoring-review' : 'authoring-edit'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                key: const Key('authoring-name'),
                controller: _draft.name,
                maxLength: 128,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: '名字')),
            const SizedBox(height: 16),
            TextField(
                key: const Key('authoring-short-description'),
                controller: _draft.form.characterPortrait,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                    labelText: '你希望 TA 是什么样的伙伴',
                    hintText: '例如：温和直接，愿意听我说，说话简短一些')),
            const SizedBox(height: 20),
            ExpansionTile(
                key: const Key('authoring-preferences'),
                title: const Text('回复偏好（可选）'),
                children: [
                  ConversationPreferencesForm(
                      value: _draft.preferences,
                      onChanged: (value) =>
                          setState(() => _draft.preferences = value))
                ]),
            ExpansionTile(
                key: const Key('authoring-details'),
                title: const Text('详细设定（可选）'),
                children: [
                  ..._draft.form.whoItIs(() => setState(() {})),
                  ..._draft.form.theRelationship(() => setState(() {})),
                  ..._draft.form.howItSpeaks(() => setState(() {}))
                ]),
            if (widget.preview != null)
              ExpansionTile(title: const Text('先试聊一句（可选）'), children: [
                PersonaPreviewPanel(
                    draft: PersonaPreviewRequest(
                        name: _draft.name.text.trim(),
                        persona: _draft.form.authoring,
                        preferences: _draft.preferences,
                        modality: 'voice',
                        text: ''),
                    preview: widget.preview!)
              ]),
          ]);
}
