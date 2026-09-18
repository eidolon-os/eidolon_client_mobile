import 'dart:math';

import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'companion_authoring_page.dart';
import 'persona_preview_panel.dart';
import 'companion_roster_page.dart';
import 'management_client.dart';
import 'refusal_notice.dart';

/// Loads the roster and shows one of three honest answers.
///
/// Kept apart from [CompanionRosterPage] so the page stays a pure function of
/// what the Host said, and so the three states a network read actually has are
/// visible in one place:
///
/// - waiting;
/// - the Host answered, and the roster is shown even if it is empty;
/// - the Host refused, and *what* it said is shown rather than an empty list.
///
/// The last one is the reason this class exists. A failed read rendered as an
/// empty roster tells a person they have no Eidolons, which is a lie in the one
/// situation where they most need the truth.
class CompanionRosterScreen extends StatefulWidget {
  const CompanionRosterScreen({
    super.key,
    required this.load,
    this.openCompanion,
    this.loadContext,
    this.setDefaultCompanion,
    this.createCompanion,
    this.loadPersonaTemplate,
    this.loadPersonaPresets,
    this.preview,
    this.startConversation,
    this.newOperationId,
  });

  /// Asks the Host for one page. Given a cursor when asking for a later one.
  final Future<CompanionRosterView> Function({String? cursor}) load;

  /// Reads one Eidolon. Null leaves the rows unopenable rather than opening
  /// something that cannot load.
  /// Open one Eidolon. The row is handed up rather than a page being built
  /// here, so the list and the home screen open the *same* page.
  ///
  /// They did not. This screen used to push a thinner Companion page of its
  /// own — default badge, rename, put-away — while the richer one (who it is,
  /// what it remembers, what it is doing) was reachable only from the home
  /// card, and only for the Eidolon that answers when nobody was named. So
  /// "open one of my Eidolons" led to two different pages depending on where
  /// you tapped, and only one of them let you change who it is.
  final Future<void> Function(CompanionSummaryView companion)? openCompanion;

  /// Read once when this screen opens, for two things it cannot infer:
  /// whether this Host can change the default at all, and which Owner revision
  /// the person is looking at.
  final Future<ManagementContextView> Function()? loadContext;

  /// Performs the change. Given the revision this screen was showing, not a
  /// freshly-read one — a compare-and-swap against a value read a millisecond
  /// earlier protects nothing.
  final Future<CompanionDetailOutcome> Function(
    String companionId,
    int expectedRevision,
  )? setDefaultCompanion;

  /// Adds one. Given an operation id this screen holds, not one per attempt.
  ///
  /// The persona is what the person wrote on the authoring page, or null when
  /// they left it as the Host had it — null is not the same request as a copy of
  /// the template, and the difference is what keeps a retry a replay.
  final Future<CreatedCompanion> Function(
    String operationId,
    String displayName,
    PersonaAuthoring? persona,
    ConversationPreferences? preferences,
    PersonaPreset? sourcePreset,
  )? createCompanion;

  /// What the Host would write if the authoring form came back untouched.
  ///
  /// Read when the person asks to add one, not when this screen opens: it is
  /// only needed on the way into the form, and a roster that failed to load
  /// because of it would be a list nobody can read for the sake of a button.
  final Future<PersonaAuthoring> Function()? loadPersonaTemplate;
  final Future<PersonaPresetCatalog> Function()? loadPersonaPresets;
  final PreviewPersona? preview;
  final Future<void> Function(CreatedCompanion)? startConversation;

  /// Injected so a test can pin the id; a real screen mints a random one.
  final String Function()? newOperationId;

  @override
  State<CompanionRosterScreen> createState() => _CompanionRosterScreenState();
}

class _CompanionRosterScreenState extends State<CompanionRosterScreen> {
  CompanionRosterView? _roster;
  ManagementContextView? _context;
  Object? _error;
  bool _busy = true;
  String? _changing;
  String? _refusal;
  String? _notice;

  /// Held across retries, exactly like the device-removal request id: the whole
  /// point of the operation id is that a second attempt is the *same* attempt.
  /// Cleared only once the Host has answered for it, one way or the other.
  _CreationSubmission? _pendingSubmission;
  CompanionCreationDrafts? _drafts;
  PersonaPresetCatalog? _catalog;
  PersonaAuthoring? _template;
  bool _preparing = false;
  final _retiredDrafts = <CompanionCreationDrafts>[];

  @override
  void dispose() {
    _drafts?.dispose();
    for (final drafts in _retiredDrafts) {
      drafts.dispose();
    }
    super.dispose();
  }

  final Random _random = Random.secure();

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read({String? cursor}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Asked for together on a first read, because a roster drawn before the
      // Host said what it can do would either hide an action it allows or
      // offer one it does not.
      final context = cursor == null && widget.loadContext != null
          ? await widget.loadContext!()
          : _context;
      final page = await widget.load(cursor: cursor);
      if (!mounted) return;
      setState(() {
        _context = context;
        // Pages are appended rather than replacing what is on screen: asking
        // for more must not make what a person was already reading disappear.
        _roster = cursor == null || _roster == null
            ? page
            : CompanionRosterView(
                contractVersion: page.contractVersion,
                defaultCompanionId: page.defaultCompanionId,
                companions: [..._roster!.companions, ...page.companions],
                nextCursor: page.nextCursor,
                runtimeUnavailable:
                    page.runtimeUnavailable ?? _roster!.runtimeUnavailable,
              );
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  /// Ask the Host to move the pointer, then believe only the Host.
  ///
  /// The whole page is re-read on success rather than patched locally: the
  /// Owner revision has moved, and a screen holding the old one would refuse
  /// the person's next change for a reason that is this screen's fault.
  Future<void> _makeDefault(CompanionSummaryView companion) async {
    final change = widget.setDefaultCompanion;
    final revision = _context?.owner.revision;
    if (change == null || revision == null) return;
    setState(() {
      _changing = companion.companionId;
      _refusal = null;
    });
    try {
      await change(companion.companionId, revision);
      if (!mounted) return;
      setState(() => _changing = null);
      await _read();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _changing = null;
        _refusal = _refusalSentence(error);
      });
      // A stale view is the one refusal that is answered by looking again, and
      // the person should not have to press anything to get that.
      if (error is ManagementRequestException && error.someoneElseChangedIt) {
        await _read();
      }
    }
  }

  Future<void> _openCompanion(CompanionSummaryView companion) async {
    final open = widget.openCompanion;
    if (open == null) return;
    await open(companion);
    if (mounted) await _read();
  }

  /// Keyed on the status, which is contract — not on the Host's own sentence,
  /// which is written for an operator reading a log.
  static String _refusalSentence(Object error) {
    if (error is! ManagementRequestException) return '$error';
    if (error.someoneElseChangedIt) {
      return '别的地方刚改过默认，已经重新读取';
    }
    if (error.statusCode == 400) {
      return '这台主机不允许把它设为默认';
    }
    if (error.statusCode == 404) {
      return '这台主机上没有这个 Eidolon';
    }
    return '没有改成：$error';
  }

  /// Ask for another Eidolon: who it is, then the ask itself.
  ///
  /// This used to be a dialog with one box in it, which is why every Eidolon
  /// this Host made was the same person under a different name. The form opens
  /// on what the Host would write by itself, so it can be walked past in three
  /// taps — the cost of saying more is on whoever wants to say more.
  ///
  /// The operation id is minted here and **kept across a failure**, so pressing
  /// 创建 again after a lost answer addresses the same Eidolon. It is also held
  /// across the form: someone who backs out and starts again is still asking for
  /// the one thing they asked for.
  Future<void> _add() async {
    final create = widget.createCompanion;
    final loadTemplate = widget.loadPersonaTemplate;
    if (create == null || loadTemplate == null || _preparing) return;
    setState(() {
      _preparing = true;
      _refusal = null;
      _notice = null;
    });
    try {
      if (_drafts == null) {
        _catalog = widget.loadPersonaPresets == null
            ? const PersonaPresetCatalog(presets: [])
            : await widget.loadPersonaPresets!();
        _template = await loadTemplate();
        if (!mounted) return;
        _drafts = CompanionCreationDrafts(_template!, _catalog!.presets);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _refusal = '伙伴模板暂时没能加载，请重试新建伙伴。';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    final created =
        await Navigator.of(context).push<CreatedCompanion>(MaterialPageRoute(
      builder: (_) => _AuthoringRoute(
        template: _template!,
        catalog: _catalog!,
        drafts: _drafts!,
        preview: widget.preview,
        uncertain: () => _pendingSubmission?.uncertain == true,
        create: (name, persona, preferences, sourcePreset) async {
          _pendingSubmission ??= _CreationSubmission(
              _newOperationId(), name, persona, preferences, sourcePreset);
          final submission = _pendingSubmission!;
          try {
            final answer = await create(
                submission.operationId,
                submission.name,
                submission.persona,
                submission.preferences,
                submission.sourcePreset);
            _pendingSubmission = null;
            return answer;
          } catch (error) {
            // A deterministic validation refusal can be edited. A lost response
            // must be resolved by retrying the exact same submission.
            if (error is ManagementRequestException &&
                (error.statusCode ?? 0) >= 400 &&
                (error.statusCode ?? 0) < 500 &&
                error.statusCode != 408) {
              _pendingSubmission = null;
            } else {
              submission.uncertain = true;
            }
            rethrow;
          }
        },
      ),
    ));
    if (!mounted) return;
    if (created != null) {
      _retiredDrafts.add(_drafts!);
      _drafts = null;
      setState(() => _notice = created.memoryReady
          ? '${created.displayName} 已经在这台主机上了'
          : '${created.displayName} 已经建好，记忆还在启动');
    }
    await _read();
    if (!mounted || created == null || widget.startConversation == null) return;
    final talk = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text('认识一下，${created.displayName}'),
              content: Text(created.memoryReady
                  ? '伙伴已经准备好了，聊一句试试吧。'
                  : '伙伴已创建，记忆服务还在准备。你可以稍后开始对话。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('稍后再聊')),
                FilledButton(
                    key: const Key('created-start-conversation'),
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('开始对话')),
              ],
            ));
    if (mounted && talk == true) await widget.startConversation!(created);
  }

  String _newOperationId() {
    if (widget.newOperationId != null) return widget.newOperationId!();
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

  @override
  Widget build(BuildContext context) {
    final roster = _roster;
    if (roster != null) {
      return Stack(
        children: [
          CompanionRosterPage(
            roster: roster,
            onOpen: widget.openCompanion == null ? null : _openCompanion,
            onLoadMore: roster.nextCursor == null
                ? null
                : () => _read(cursor: roster.nextCursor),
            onMakeDefault: widget.setDefaultCompanion == null ||
                    _context == null ||
                    !hostCan(_context!, 'companion.set_default')
                ? null
                : _makeDefault,
            busyCompanionId: _changing,
            refusal: _refusal,
            notice: _notice,
            onAdd: _preparing ||
                    widget.createCompanion == null ||
                    _context == null ||
                    !hostCan(_context!, 'companion.create')
                ? null
                : _add,
          ),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(key: Key('roster-loading-more')),
            ),
        ],
      );
    }
    return Scaffold(
      key: const Key('companion-roster-screen'),
      appBar: AppBar(title: const Text('你的伙伴')),
      body: Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('roster-loading'))
            : RefusalNotice(
                key: const Key('roster-error'),
                error: _error!,
                subject: '你的伙伴',
                onRetry: () => _read(),
                retryKey: const Key('roster-retry'),
              ),
      ),
    );
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

class _CreationSubmission {
  _CreationSubmission(this.operationId, this.name, this.persona,
      this.preferences, this.sourcePreset);
  final String operationId;
  final String name;
  final PersonaAuthoring? persona;
  final ConversationPreferences? preferences;
  final PersonaPreset? sourcePreset;
  bool uncertain = false;
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
  final Future<CreatedCompanion> Function(String, PersonaAuthoring?,
      ConversationPreferences?, PersonaPreset?) create;
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
