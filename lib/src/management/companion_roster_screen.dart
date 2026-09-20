import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'companion_creation_flow.dart';
import 'companion_creation_checkpoint.dart';
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
    this.connectDevice,
    this.newOperationId,
    this.creationCheckpoints,
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
  final Future<void> Function(CreatedCompanion)? connectDevice;

  /// Injected so a test can pin the id; a real screen mints a random one.
  final String Function()? newOperationId;
  final CompanionCreationCheckpointStore? creationCheckpoints;

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

  late final _creation = CompanionCreationFlow(
    loadTemplate: () => widget.loadPersonaTemplate!(),
    loadPresets: widget.loadPersonaPresets,
    create: (id, name, persona, preferences, source) =>
        widget.createCompanion!(id, name, persona, preferences, source),
    checkpoints: widget.creationCheckpoints,
    preview: widget.preview,
    newOperationId: widget.newOperationId,
  );
  bool _preparing = false;

  @override
  void dispose() {
    _creation.dispose();
    super.dispose();
  }

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
      CompanionCreationSubmission? recovered;
      String? recoveryError;
      if (cursor == null && _creation.pending == null) {
        try {
          recovered = await _creation.recover();
        } catch (_) {
          recoveryError = '手机暂时读不到创建进度。伙伴列表仍可查看，重试读取前不会发送新的创建请求。';
        }
      }
      if (!mounted) return;
      setState(() {
        _creation.pending ??= recovered;
        if (recovered != null) {
          _notice = '${recovered.name} 的上次创建尚未确认，请继续确认同一次创建。';
        }
        if (recoveryError != null) _refusal = recoveryError;
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
                activityUnavailable:
                    page.activityUnavailable ?? _roster!.activityUnavailable,
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
    CreatedCompanion? result;
    try {
      result = await _creation.open(context);
    } catch (_) {
      if (mounted) {
        setState(() => _refusal = '创建进度或伙伴设定暂时读不到。请重试；为避免重复创建，暂未发送新请求。');
      }
      return;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (!mounted) return;
    final created = result;
    if (created != null) {
      setState(() => _notice = created.memoryReady
          ? '${created.displayName} 已经在这台主机上了'
          : '${created.displayName} 已经建好，记忆还在启动');
    }
    await _read();
    if (!mounted ||
        created == null ||
        (widget.startConversation == null && widget.connectDevice == null)) {
      return;
    }
    final next = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text('认识一下，${created.displayName}'),
              content: Text(created.memoryReady
                  ? '伙伴已经保存在这台主机上。可以先在手机上聊聊，或连接陪伴设备，选择由 TA 回应，再设置说话、字幕和表情。可用表达方式取决于设备。'
                  : '伙伴已创建，记忆服务还在准备。你可以稍后开始对话。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('稍后再聊')),
                if (widget.connectDevice != null)
                  OutlinedButton(
                      key: const Key('created-connect-device'),
                      onPressed: () => Navigator.pop(dialogContext, 'device'),
                      child: const Text('连接陪伴设备')),
                if (widget.startConversation != null)
                  FilledButton(
                      key: const Key('created-start-conversation'),
                      onPressed: () => Navigator.pop(dialogContext, 'talk'),
                      child: const Text('开始对话')),
              ],
            ));
    if (!mounted) return;
    if (next == 'talk') await widget.startConversation!(created);
    if (next == 'device') await widget.connectDevice!(created);
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
            resumingCreation: _creation.pending != null,
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
