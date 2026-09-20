import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/companion_authoring_page.dart';
import '../../management/management_client.dart';
import 'local_api_client.dart';

/// Uses the same draft and authoring UI as all later companions. No preview is
/// offered before the Owner exists: preview needs an Owner-scoped runtime.
class FirstCompanionPage extends StatefulWidget {
  const FirstCompanionPage({
    super.key,
    required this.loadTemplate,
    required this.loadPresets,
    required this.initialize,
  });

  final Future<PersonaAuthoring> Function() loadTemplate;
  final Future<PersonaPresetCatalog> Function() loadPresets;
  final Future<void> Function(
          String, PersonaAuthoring?, ConversationPreferences?, PersonaPreset?)
      initialize;

  @override
  State<FirstCompanionPage> createState() => _FirstCompanionPageState();
}

class _FirstCompanionPageState extends State<FirstCompanionPage> {
  PersonaAuthoring? _template;
  PersonaPresetCatalog? _catalog;
  CompanionCreationDrafts? _drafts;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  // Once sent, a retry must repeat the complete request, never the live form.
  ({
    String name,
    PersonaAuthoring? persona,
    ConversationPreferences? preferences,
    PersonaPreset? source
  })? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        widget.loadTemplate(),
        widget.loadPresets(),
      ]);
      if (!mounted) return;
      final template = results[0] as PersonaAuthoring;
      final catalog = results[1] as PersonaPresetCatalog;
      setState(() {
        _template = template;
        _catalog = catalog;
        _drafts = CompanionCreationDrafts(template, catalog.presets);
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error is ManagementRequestException &&
                  (error.statusCode == 404 || error.statusCode == 409)
              ? '这台主机尚不支持首次选角，请先更新主机服务。尚未创建伙伴。'
              : '暂时读不到伙伴设定，请检查主机连接后重试。尚未创建伙伴。';
        });
      }
    }
  }

  @override
  void dispose() {
    _drafts?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_drafts == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('认识第一位伙伴')),
        body: Center(
            child: _loading
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!),
                      const SizedBox(height: 16),
                      FilledButton(
                          onPressed: _load, child: const Text('重新读取设定')),
                    ]),
                  )),
      );
    }
    return CompanionAuthoringPage(
      template: _template!,
      presets: _catalog!.presets,
      drafts: _drafts,
      busy: _busy,
      locked: _pending != null,
      refusal: _error,
      onCreate: (name, persona, preferences, source) async {
        if (_busy) return;
        final wasPending = _pending != null;
        final submitted = _pending ??= (
          name: name,
          persona: persona == null
              ? null
              : PersonaAuthoring.fromJson(persona.toJson()),
          preferences: preferences,
          source: source,
        );
        setState(() {
          _busy = true;
          _error = null;
        });
        try {
          await widget.initialize(submitted.name, submitted.persona,
              submitted.preferences, submitted.source);
          if (context.mounted) Navigator.of(context).pop(submitted.name);
        } catch (error) {
          if (!mounted) return;
          final refused = !wasPending &&
              error is LocalApiRequestException &&
              (error.statusCode == 400 || error.statusCode == 422);
          setState(() {
            _busy = false;
            if (refused) _pending = null;
            _error = refused
                ? '主机未接受这份设定，请调整后重试。'
                : '还没能确认创建结果。请重试同一次创建，或返回主机页面检查已有进度。';
          });
        }
      },
    );
  }
}
