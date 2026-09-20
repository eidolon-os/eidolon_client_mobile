import 'dart:math';
import 'package:flutter/material.dart';
import '../generated/management_v1.dart';
import 'companion_authoring_page.dart';
import 'companion_creation_checkpoint.dart';
import 'management_client.dart';
import 'persona_preview_panel.dart';

typedef CreateCompanion = Future<CreatedCompanion> Function(String, String,
    PersonaAuthoring?, ConversationPreferences?, PersonaPreset?);

/// Shared by roster and device entry points. A caller owns this session so
/// leaving the form preserves drafts; submitted requests share one durable
/// Host/controller/Owner checkpoint across both entry points.
class CompanionCreationFlow {
  CompanionCreationFlow(
      {required this.loadTemplate,
      required this.create,
      this.loadPresets,
      this.preview,
      this.checkpoints,
      this.newOperationId});
  final Future<PersonaAuthoring> Function() loadTemplate;
  final Future<PersonaPresetCatalog> Function()? loadPresets;
  final CreateCompanion create;
  final PreviewPersona? preview;
  final CompanionCreationCheckpointStore? checkpoints;
  final String Function()? newOperationId;
  final Random _random = Random.secure();
  CompanionCreationSubmission? pending;
  bool _disposed = false;
  CompanionCreationDrafts? _drafts;
  PersonaPresetCatalog? _catalog;
  PersonaAuthoring? _template;
  final _retired = <CompanionCreationDrafts>[];

  Future<CompanionCreationSubmission?> recover() async {
    if (checkpoints == null) return pending;
    final saved = await checkpoints!.load();
    if (_disposed) return null;
    if (saved?.operationId != pending?.operationId && _drafts != null) {
      _retired.add(_drafts!);
      _drafts = null;
    }
    pending = saved;
    return saved;
  }

  Future<CreatedCompanion?> open(BuildContext context) async {
    await recover();
    if (_disposed || !context.mounted) return null;
    if (_drafts == null && pending != null) {
      final saved = pending!;
      _template = saved.persona ?? const PersonaAuthoring();
      _catalog = const PersonaPresetCatalog(presets: []);
      _drafts = CompanionCreationDrafts(_template!, const []);
      _drafts!.custom.name.text = saved.name;
      _drafts!.custom.preferences =
          saved.preferences ?? const ConversationPreferences();
    }
    if (_drafts == null) {
      _catalog =
          await loadPresets?.call() ?? const PersonaPresetCatalog(presets: []);
      _template = await loadTemplate();
      if (_disposed || !context.mounted) return null;
      _drafts = CompanionCreationDrafts(_template!, _catalog!.presets);
    }
    if (!context.mounted) return null;
    final created = await Navigator.of(context).push<CreatedCompanion>(
        MaterialPageRoute(
            builder: (_) => _AuthoringRoute(
                template: _template!,
                catalog: _catalog!,
                drafts: _drafts!,
                preview: preview,
                uncertain: () => pending?.uncertain == true,
                create: _submit)));
    if (created != null && !_disposed) {
      _retired.add(_drafts!);
      _drafts = null;
    }
    return created;
  }

  Future<CreatedCompanion> _submit(String name, PersonaAuthoring? persona,
      ConversationPreferences? preferences, PersonaPreset? source) async {
    pending ??= CompanionCreationSubmission(
        _newOperationId(), name, persona, preferences, source);
    final submission = pending!;
    final wasUncertain = submission.uncertain;
    try {
      await checkpoints?.save(submission);
      final answer = await create(submission.operationId, submission.name,
          submission.persona, submission.preferences, submission.sourcePreset);
      await checkpoints?.clear(submission.operationId);
      pending = null;
      return answer;
    } catch (error) {
      submission.uncertain = true;
      if (!wasUncertain &&
          error is ManagementRequestException &&
          (error.statusCode == 400 || error.statusCode == 422)) {
        await checkpoints?.clear(submission.operationId);
        pending = null;
      }
      rethrow;
    }
  }

  void dispose() {
    _disposed = true;
    _drafts?.dispose();
    for (final draft in _retired) {
      draft.dispose();
    }
  }

  String _newOperationId() {
    if (newOperationId != null) return newOperationId!();
    // A version-4 UUID, because the Host's operation id is one. Built from
    // Random.secure like every other identifier this app mints.
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

/// The authoring page plus the one piece of state it cannot own: whether the ask
/// is in flight, and what the Host said if it refused.
///
/// Separate from the page so the page stays a form — it renders what it is given
/// and hands back what was typed. Keeping the request here also means the
/// refusal is shown *on* the form, next to the words that caused it, instead of
/// behind a pop back to the list.
/// Why the creation did not happen, in words the person can act on.
///
/// Written here rather than borrowed from the composition root: that folder
/// composes this surface, so depending on it would invert the direction that
/// keeps this layer generated from the contract — and the boundary test says
/// so. The Host's own sentence is the fallback, not the first choice, because
/// it is written for an operator reading a log.
String _creationRefusal(Object error) {
  if (error is! ManagementRequestException) {
    return '创建未完成：当前网络到不了这台主机。';
  }
  if (error.statusCode == 400 || error.statusCode == 422) {
    return '创建未完成：${error.reason ?? '这台主机不接受这份设定'}';
  }
  if (error.statusCode == 409) {
    return '创建未完成：${error.reason ?? '这台主机上已经有同名的伙伴'}';
  }
  return '创建未完成：${error.reason ?? '这台主机没有完成这次创建'}';
}

class _AuthoringRoute extends StatefulWidget {
  const _AuthoringRoute(
      {required this.template,
      required this.catalog,
      required this.drafts,
      required this.create,
      required this.uncertain,
      this.preview});
  final PersonaAuthoring template;
  final PersonaPresetCatalog catalog;
  final CompanionCreationDrafts drafts;
  final PreviewPersona? preview;
  final bool Function() uncertain;
  final Future<CreatedCompanion> Function(
          String, PersonaAuthoring?, ConversationPreferences?, PersonaPreset?)
      create;
  @override
  State<_AuthoringRoute> createState() => _AuthoringRouteState();
}

class _AuthoringRouteState extends State<_AuthoringRoute> {
  bool _busy = false;
  String? _refusal;
  @override
  Widget build(BuildContext context) => CompanionAuthoringPage(
        template: widget.template,
        presets: widget.catalog.presets,
        drafts: widget.drafts,
        preview: widget.preview,
        busy: _busy,
        locked: widget.uncertain(),
        refusal: _refusal,
        onCreate: (name, persona, preferences, sourcePreset) async {
          if (_busy) return;
          setState(() {
            _busy = true;
            _refusal = null;
          });
          try {
            final created =
                await widget.create(name, persona, preferences, sourcePreset);
            if (context.mounted) Navigator.of(context).pop(created);
          } catch (error) {
            if (!mounted) return;
            setState(() {
              _busy = false;
              _refusal = widget.uncertain()
                  ? '还没能确认创建结果。草稿已保留，请重试确认这次创建。'
                  : _creationRefusal(error);
            });
          }
        },
      );
}
