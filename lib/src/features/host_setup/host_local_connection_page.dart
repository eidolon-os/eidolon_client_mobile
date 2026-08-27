import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../naming/ask_for_a_name.dart';

import '../device_management/mounted_devices_page.dart';
import '../device_setup/device_setup_ports.dart';
import '../setup/change_network_page.dart';
import '../setup/commissioning_transport.dart';
import '../setup/controller_key_bridge.dart';
import '../setup/host_registry.dart';
import 'face_picker.dart';
import 'failure_sentences.dart';
import 'host_product_controller.dart';
import '../../management/management_client.dart';
import '../../management/companion_roster_screen.dart';
import '../../management/memory_library_screen.dart';
import '../../management/lifecycle_sheet.dart';
import '../../management/persona_edit_page.dart';
import '../../generated/management_v1.dart';
import 'companion_page.dart';
import 'managed_controllers_page.dart';
import 'home_models.dart';
import '../../management/conversations_screen.dart';
import '../../management/tasks_screen.dart';
import 'recollections_page.dart';
import 'host_product_session.dart';
import 'host_runtime_status_page.dart';
import 'local_api_discovery.dart';
import 'network_changes.dart';
import 'workspace_models.dart';
import '../constellation/cockpit_composition.dart';
import '../constellation/cockpit_wire.dart';
import '../constellation/constellation_cockpit_page.dart';
import '../constellation/polled_cockpit_feed.dart';
import 'host_models.dart';

export 'host_product_controller.dart' show ManagedHostUpdater;

typedef HostConversationBuilder = Widget Function(
  BuildContext context,
  HostProductController controller,
);

class HostLocalConnectionPage extends StatefulWidget {
  const HostLocalConnectionPage({
    super.key,
    required this.host,
    required this.onHostUpdated,
    this.transport,
    this.controllerKeys,
    this.discovery,
    this.localApiClientFactory,
    this.managementClientFactory,
    this.networkChanges,
    this.deviceProvisioning,
    this.conversationBuilder,
    this.setupContinuation = false,
    this.onSetupComplete,
    this.facePicker,
  }) : assert(!setupContinuation || onSetupComplete != null);

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final CommissioningTransport? transport;
  final ControllerKeyBridge? controllerKeys;
  final LocalApiDiscovery? discovery;
  final LocalApiClientFactory? localApiClientFactory;

  /// Injected alongside the other one in tests. Both produce clients over the
  /// same pinned transport in production; a management call that reached the
  /// Host by another route would be a weaker second door.
  final ManagementClientFactory? managementClientFactory;

  /// Injected in tests, where there is no phone to change networks.
  final NetworkChanges? networkChanges;
  final DeviceProvisioningTransport? deviceProvisioning;
  final HostConversationBuilder? conversationBuilder;

  /// Where the picture an Eidolon wears comes from. The gallery, unless a
  /// test says otherwise.
  final FacePicker? facePicker;
  final bool setupContinuation;
  final VoidCallback? onSetupComplete;

  @override
  State<HostLocalConnectionPage> createState() =>
      _HostLocalConnectionPageState();
}

class _HostLocalConnectionPageState extends State<HostLocalConnectionPage> {
  late final HostProductController _controller;
  final _ownerName = TextEditingController();
  final _companionName = TextEditingController(text: 'Eidolon');

  @override
  void initState() {
    super.initState();
    _controller = HostProductController(
      host: widget.host,
      onHostUpdated: widget.onHostUpdated,
      transport: widget.transport,
      controllerKeys: widget.controllerKeys,
      discovery: widget.discovery,
      localApiClientFactory: widget.localApiClientFactory,
      managementClientFactory: widget.managementClientFactory,
      networkChanges: widget.networkChanges,
    )..addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.connect();
    });
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_refresh)
      ..dispose();
    _ownerName.dispose();
    _companionName.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _openNetworkChange() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChangeNetworkPage(
          host: _controller.host,
          transport: widget.transport,
          controllerKeys: widget.controllerKeys,
        ),
      ),
    );
    if (mounted) await _controller.connect();
  }

  /// Ask what this person should be called, and tell the Host.
  Future<void> _renameOwner() async {
    final owner = _controller.workspace?.owner;
    if (owner == null) return;
    final name = await askForAName(
      context,
      question: '你叫什么？',
      hint: '它会这样称呼你',
      current: owner.displayName,
      dialogKey: const Key('rename-owner-dialog'),
      fieldKey: const Key('owner-name-field'),
      confirmKey: const Key('confirm-owner-name'),
    );
    if (name == null || !mounted) return;
    try {
      await _controller.renameOwner(displayName: name);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('改名没有完成：${failureSentence(error)}')),
      );
    }
  }

  /// Ask what this Eidolon should be called, and tell the Host.
  /// Rename the Eidolon whose page this is — not whichever one answers.
  Future<void> _renameCompanion(HostCompanion companion) async {
    final name = await askForAName(
      context,
      question: '这个 Eidolon 叫什么？',
      hint: '给它起个名字',
      current: companion.displayName,
      dialogKey: const Key('rename-companion-dialog'),
      fieldKey: const Key('companion-name-field'),
      confirmKey: const Key('confirm-companion-name'),
    );
    if (name == null || !mounted) return;
    try {
      await _controller.renameCompanion(
        companionId: companion.companionId,
        displayName: name,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('改名没有完成：${failureSentence(error)}')),
      );
    }
  }

  /// Open the Eidolon itself. A Host is a machine someone owns; this is who
  /// they talk to, and it had been living as rows on the machine's card.
  /// Open one Eidolon — the one whose row was tapped.
  ///
  /// It used to open ``home.answering`` regardless, so an Owner with three
  /// Eidolons could reach exactly one of them and the other two had no page.
  /// Put this Eidolon away, or bring it back.
  ///
  /// Reachable from the Eidolon's own page, which is the only page there is
  /// now. It used to live on a second, thinner Companion screen that only the
  /// roster could reach — so whether you could put an Eidolon away depended on
  /// which of two paths you had taken to it.
  Future<void> _changeLifecycle(HostCompanion companion) async {
    final moved = await showModalBottomSheet<CompanionLifecycleView>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CompanionLifecycleSheet(
        displayName: companion.displayName,
        lifecycleState: companion.lifecycleState,
        // Only the other active ones can take over answering. Offering an
        // archived Eidolon as a successor would offer to wake something the
        // person deliberately put away.
        others: [
          for (final row in _controller.home?.companions ?? const [])
            if (row.companionId != companion.companionId &&
                row.lifecycleState == 'active')
              LifecycleSuccessor(
                companionId: row.companionId,
                displayName: row.displayName,
              ),
        ],
        setLifecycle: (state, replacement) => _controller.setCompanionLifecycle(
          companionId: companion.companionId,
          lifecycleState: state,
          replacementCompanionId: replacement,
        ),
      ),
    );
    if (moved == null || !mounted) return;
    final released = moved.releasedDevices ?? const <String>[];
    if (released.isNotEmpty) {
      // Said out loud: a speaker that goes quiet without a sentence cannot be
      // told from a broken one.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            released.length == 1
                ? '有 1 台设备不再由它应答了'
                : '有 ${released.length} 台设备不再由它应答了',
          ),
        ),
      );
    }
    await _controller.refreshWorkspace();
  }

  Future<void> _openCompanion(HostCompanion companion) {
    final answering = companion;
    // Asked for as the page opens rather than with the rest of the home read:
    // a photograph is worth fetching when someone is about to look at it.
    unawaited(
      _controller
          .loadCompanionFace(companionId: answering.companionId)
          .catchError((Object _) {}),
    );
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AnimatedBuilder(
          animation: _controller,
          builder: (_, __) {
            // Re-read from the live home so the page follows a rename or a
            // state change, and falls back to what the row said if this Eidolon
            // has since left the first page of the list.
            final current = _controller.home?.companions.firstWhere(
                  (row) => row.companionId == companion.companionId,
                  orElse: () => companion,
                ) ??
                companion;
            return CompanionPage(
              companion: current,
              devices: _controller.devices,
              // Read once when the Host was connected, so a row this Host
              // cannot serve says so instead of opening onto a page that fails.
              hostContext: _controller.managementCapabilities,
              // Every action is about the Eidolon this page is about — the one
              // whose row was tapped. They used to be about ``answering``, so
              // opening any Eidolon and editing it would have edited the
              // default one.
              isDefault:
                  current.companionId == _controller.home?.defaultCompanionId,
              onChangeLifecycle: _capabilityHold('companion.archive') == null
                  ? () => _changeLifecycle(current)
                  : null,
              onRename: () => _renameCompanion(current),
              onOpenPersona: () => _openPersonaEdit(current),
              onOpenRecollections: () => _openRecollections(current),
              onOpenTasks: () => _openTasks(current),
              onOpenConversations: () => _openConversations(current),
              face: _controller.companionFace,
              onChangeFace: () => _changeCompanionFace(current),
              onClearFace: _controller.companionFace == null
                  ? null
                  : () => _clearCompanionFace(current),
            );
          },
        ),
      ),
    );
  }

  /// Every Eidolon this Owner has, not just the one this Host runs by default.
  ///
  /// The workspace card above can only ever show one, because the runtime it
  /// reads answers with one. This is the read that can show the rest.
  Future<void> _openRoster() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CompanionRosterScreen(
            load: ({String? cursor}) => _controller.roster(cursor: cursor),
            // The same page the home rows open. One Eidolon, one page,
            // wherever it was tapped from.
            openCompanion: (row) => _openCompanion(HostCompanion.fromView(row)),
            loadContext: _controller.managementContext,
            setDefaultCompanion: (companionId, expectedRevision) =>
                _controller.setDefaultCompanion(
              companionId: companionId,
              expectedRevision: expectedRevision,
            ),
            loadCompanionFace: (companionId) =>
                _controller.companionFacePicture(companionId: companionId),
            renameCompanion: (companionId, displayName) =>
                _controller.renameOneCompanion(
              companionId: companionId,
              displayName: displayName,
            ),
            setCompanionLifecycle:
                (companionId, lifecycleState, replacementCompanionId) =>
                    _controller.setCompanionLifecycle(
              companionId: companionId,
              lifecycleState: lifecycleState,
              replacementCompanionId: replacementCompanionId,
            ),
            createCompanion: (operationId, displayName, persona) =>
                _controller.createCompanion(
              operationId: operationId,
              displayName: displayName,
              persona: persona,
            ),
            loadPersonaTemplate: _controller.personaAuthoringTemplate,
          ),
        ),
      );

  /// Everything it has filed, not just what a search turns up.
  ///
  /// The search box answers "do you remember X"; this answers "what do you
  /// have", which is the question someone asks before they know what to search
  /// for.
  /// Why the Host is withholding a feature, or null if it is not.
  ///
  /// Nothing when the capabilities have not been read: silence is "not asked
  /// yet", and treating it as a refusal would withdraw every feature for the
  /// moment after connecting.
  String? _capabilityHold(String capability) {
    final context = _controller.managementCapabilities;
    return context == null ? null : capabilityHold(context, capability);
  }

  Future<void> _openMemoryLibrary() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MemoryLibraryScreen(
            load: _controller.memoryLibrary,
            loadContext: _controller.managementContext,
            previewForget: (target) =>
                _controller.previewForget(target: target),
            confirmForget: (token) =>
                _controller.confirmForget(confirmationToken: token),
            loadDay: (since) => _controller.memoryEntries(since: since),
            loadCopy: _controller.memoryCopy,
            loadCompanions: () async => (await _controller.roster()).companions,
            assignAudience: (entryId, companionId) =>
                _controller.assignMemoryAudience(
              entryId: entryId,
              companionId: companionId,
            ),
          ),
        ),
      );

  /// What this Eidolon was given to do, and how far it has got.
  ///
  /// Its own screen: the two actions on it change what a Companion is doing, and
  /// a control like that inside a summary card is a control someone presses by
  /// accident.
  Future<void> _openTasks(HostCompanion companion) {
    final companionId = companion.companionId;
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TasksScreen(
          load: (cursor) =>
              _controller.tasks(companionId: companionId, cursor: cursor),
          cancel: (taskId) => _controller.cancelTask(
            companionId: companionId,
            taskId: taskId,
          ),
          retry: (taskId) => _controller.retryTask(
            companionId: companionId,
            taskId: taskId,
          ),
        ),
      ),
    );
  }

  /// When this Eidolon and I talked, and what was said.
  Future<void> _openConversations(HostCompanion companion) {
    final companionId = companion.companionId;
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ConversationsScreen(
          load: (cursor) => _controller.conversations(
            companionId: companionId,
            cursor: cursor,
          ),
          loadTranscript: (conversationId, cursor) => _controller.transcript(
            companionId: companionId,
            conversationId: conversationId,
            cursor: cursor,
          ),
        ),
      ),
    );
  }

  /// Ask this Eidolon what it remembers.
  Future<void> _openRecollections(HostCompanion companion) {
    final name = companion.displayName;
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecollectionsPage(
          companionName: name.isNotEmpty ? name : '它',
          onSearch: (query) => _controller.recollections(query: query),
        ),
      ),
    );
  }

  /// Choose the picture this Eidolon wears.
  ///
  /// The picker is asked for a bounded JPEG rather than the original file. The
  /// face is a conditioning image for a digital human — a camera's full
  /// resolution is of no use to it, and would not fit through the pinned
  /// transport that carries everything else this app says to its Host.
  Future<void> _changeCompanionFace(HostCompanion companion) async {
    final Uint8List? bytes;
    try {
      bytes = await (widget.facePicker ?? const GalleryFacePicker()).pickFace();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能打开相册：${failureSentence(error)}')),
      );
      return;
    }
    if (bytes == null || !mounted) return;
    try {
      await _controller.setCompanionFace(
        companionId: companion.companionId,
        face: bytes,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这张照片没能用上：${failureSentence(error)}')),
      );
    }
  }

  Future<void> _clearCompanionFace(HostCompanion companion) async {
    try {
      await _controller.clearCompanionFace(
        companionId: companion.companionId,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能拿掉这张脸：${failureSentence(error)}')),
      );
    }
  }

  /// Change who this Eidolon is.
  ///
  /// Read first, then edit: the form has to open on who it currently is, or
  /// saving would replace everything the person did not retype. A read that
  /// fails opens no form and says why — a form full of guesses would describe
  /// an Eidolon this Host does not have.
  Future<void> _openPersonaEdit(HostCompanion companion) async {
    final PersonaAuthoring standing;
    try {
      standing = await _controller.persona(companionId: companion.companionId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读不到它是谁：${failureSentence(error)}')),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _PersonaEditRoute(
          displayName: companion.displayName,
          standing: standing,
          save: (authored) => _controller.setPersona(
            companionId: companion.companionId,
            persona: authored,
          ),
        ),
      ),
    );
    if (!mounted) return;
    // The chapter line on the home card moves when the persona does, so the
    // one read that composes it is the one to redo.
    await _controller.refreshWorkspace();
  }

  Future<void> _openControllers() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ManagedControllersPage(
            loadControllers: _controller.listControllers,
            invite: _controller.inviteController,
            revoke: (controllerId) =>
                _controller.revokeController(controllerId: controllerId),
          ),
        ),
      );

  /// The sovereign domain of this Host, on one screen.
  ///
  /// The same information model as the console's cockpit — Owner, Companion,
  /// devices, memory — plus the vitals the console cannot reach. Separate from
  /// 主机动态, which answers "what happened lately"; this one answers "what is
  /// mine and how is it".
  /// The star map, reading this Host.
  ///
  /// Identity is real: the Owner comes from `/context` and the Companions from
  /// the roster, both over the same pinned session everything else here uses.
  /// The runtime lanes are not — Mission Control has no producer on the
  /// management plane yet — so every one of them reports unavailable with that
  /// reason, and the moons say 读不到 rather than 未绑定 or 空闲.
  ///
  /// It is offered next to the runtime cockpit rather than replacing it. The
  /// swap is the plan (docs/constellation-cockpit.md §3.2) but not yet: the
  /// cockpit still shows vitals, services and activity from endpoints that
  /// answer, and trading those for a mostly-unreadable map would be a
  /// regression dressed as progress.
  Future<void> _openConstellation() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ConstellationCockpitPage(
            // A factory: the page owns the poll for exactly as long as it is on
            // screen, and starting and stopping it are its job, not this one's.
            openFeed: () => PolledCockpitFeed(
              read: CockpitComposer(
                readContext: _controller.managementContext,
                readRoster: _controller.roster,
                // Three authorities, one screen: /context owns the Owner, the
                // roster owns which Eidolons exist, and Mission Control owns
                // only what was observed of them. A runtime read that fails
                // costs its lanes and nothing else.
                readRuntime: () async => parseMissionControlRuntime(
                  await _controller.missionControlSnapshot(),
                ),
              ).read,
            ),
            // The map's own reading is a bounded now; this is the record behind
            // it, paged by the Host. Passed in rather than reached for, so the
            // cockpit stays a screen that reads what it is given.
            readHistory: (cursor) async => activityPageFromJson(
              await _controller.activityHistory(cursor: cursor),
            ),
          ),
        ),
      );

  Future<void> _openDevices() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MountedDevicesPage(
            controller: _controller,
            deviceProvisioning: widget.deviceProvisioning,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final connection = _controller.connection;
    return Scaffold(
      key: const Key('host-local-connection-page'),
      appBar: AppBar(
        title: Text(
          (_controller.workspace?.isReady ?? false) ? '我的 Eidolon' : '连接主机',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _controller.host.displayName,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('仅连接同一局域网中的主机；发现地址后仍会验证 Host 和管理设备身份。'),
          const SizedBox(height: 24),
          if (_controller.connecting) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(
              _controller.progress ?? '正在连接',
              key: const Key('local-connection-progress'),
              textAlign: TextAlign.center,
            ),
          ] else if (connection != null) ...[
            _ConnectedHostCard(
              connection: connection,
              // Offered only once there is an Owner for the history to belong
              // to. Before that there is nothing this screen could be about.
              // Gated on this Host having an Owner, not on the Workspace setup
              // read — which is what it was, and a live Host disproved it: Owner
              // claimed, session valid, `/setup/workspace` failing, and the star
              // map hidden even though `/context` and the roster would both have
              // answered. Its sources are the management plane's; the gate has to
              // be about the same fact it needs.
              onOpenConstellation:
                  connection.overview.state.claim == HostClaimState.claimed
                      ? _openConstellation
                      : null,
              onOpenSystem: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HostRuntimeStatusPage(
                    host: _controller.host,
                    connection: connection,
                    readVitals: _controller.hostVitals,
                    listServices: _controller.listHostServices,
                    changeService: _controller.changeHostService,
                    loadActivity: _controller.activity,
                    listControllers: _controller.listControllers,
                    devices: _controller.devices,
                    devicesError: _controller.devicesError,
                    revokeRuntimeSessions: _controller.revokeRuntimeSessions,
                    // A destructive action on a Host that cannot perform it is
                    // the clearest case for saying so rather than offering it.
                    sessionRevokeHold: _capabilityHold('session.revoke'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _WorkspaceCard(
              controller: _controller,
              ownerName: _ownerName,
              companionName: _companionName,
              setupContinuation: widget.setupContinuation,
              onSetupComplete: widget.onSetupComplete,
              onReconnect: _controller.connect,
              onOpenCompanion: _openCompanion,
              onOpenRoster: _openRoster,
              onOpenMemoryLibrary: _openMemoryLibrary,
              // Read once when the Host connected. A Host that never got its
              // memory credential says so here rather than handing over a row
              // that opens onto a page which cannot load.
              memoryHold: _capabilityHold('memory.read'),
              onRenameOwner: _renameOwner,
              onChangeNetwork: _openNetworkChange,
            ),
            if (_controller.workspace?.isReady ?? false) ...[
              const SizedBox(height: 16),
              // Still inside setup, so the two entries are not offered yet —
              // and the screen now says so, which is the whole fix.
              //
              // What this looked like on a real phone: claiming finished, the
              // page said 「Eidolon 已准备就绪」 with all three Eidolons rendered
              // and a valid session, and the 「对话」 and 「设备」 cards simply
              // did not exist. The tester force-stopped the app and came back
              // in from the Host list to get them, having no way to tell that
              // this screen was a setup step rather than the finished Host
              // page — the two are otherwise identical.
              //
              // Worth recording, because the first diagnosis was that
              // `setupContinuation` had failed to exit: it cannot. It is a
              // final field on the widget, so this page either is the
              // continuation page or is not, for its whole life. Nothing was
              // stuck. What was missing was a sentence.
              if (widget.setupContinuation)
                Card(
                  key: const Key('setup-continuation-entries-held'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '这台主机已经就绪。「对话」和「设备」在你点上面的「进入我的 Eidolon」'
                      '之后出现 —— 这一步还在设置流程里。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              else ...[
                if (widget.conversationBuilder case final builder?) ...[
                  _ConversationCard(
                    onOpen: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (context) => builder(context, _controller),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                _DevicesSummaryCard(
                  controller: _controller,
                  onOpen: _openDevices,
                  onOpenControllers: _openControllers,
                ),
              ],
            ],
          ] else if (_controller.connectionError case final error?) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error, key: const Key('local-connection-error')),
              ),
            ),
            const SizedBox(height: 16),
            // A Host whose identity changed will never change back, so a retry
            // is the one thing that cannot work — and it used to be the only
            // control on this screen. The two routes that do work are on the
            // page underneath, so name them and open it.
            if (_controller.connectionRecovery ==
                HostConnectionRecovery.identityChanged) ...[
              const Text(
                '重新连接改变不了这件事：主机重装或重置之后会换一把新钥匙，'
                '而这台手机记的还是旧的那把。'
                '上一页的「恢复」里有两条路——'
                '「不再管理这台主机」让这台手机忘掉旧身份，重新设置一次；'
                '「手机丢失或重新认领」在有人能到主机旁边时重新拿回管理权。',
                key: Key('local-connection-identity-changed'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('open-host-recovery'),
                onPressed: Navigator.of(context).canPop()
                    ? () => Navigator.of(context).pop()
                    : null,
                icon: const Icon(Icons.settings_backup_restore),
                label: const Text('回到主机管理'),
              ),
            ] else if (_controller.connectionRecovery ==
                HostConnectionRecovery.reclaimRequired) ...[
              // The Host is the right one; it has withdrawn this phone's
              // authority. Connecting is exactly the thing that fails, so a
              // retry here is the same empty promise as the one above — only
              // the way back differs: be claimed again, which somebody at the
              // Host has to open the window for first.
              const Text(
                '重新连接改变不了这件事：要连上就得先被授权，而授权正是被收回的那一样东西。'
                '让身边能登进这台主机的人执行一次「重新认领」，他会拿到一个限时的 Setup 码；'
                '然后在上一页用「设置新主机」把这台手机重新认领回来——主机上的数据不会丢。',
                key: Key('local-connection-reclaim-required'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('open-host-reclaim'),
                onPressed: Navigator.of(context).canPop()
                    ? () => Navigator.of(context).pop()
                    : null,
                icon: const Icon(Icons.arrow_back),
                label: const Text('回到主机管理'),
              ),
            ] else
              FilledButton.icon(
                key: const Key('retry-local-connection'),
                onPressed: _controller.connect,
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
          ],
        ],
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('conversation-card'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.graphic_eq,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '对话',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '这台移动设备使用独立 Device 身份连接 Hub。首次使用需要完成设备批准和 Companion 绑定。',
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('open-conversation'),
                onPressed: onOpen,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('打开对话'),
              ),
            ],
          ),
        ),
      );
}

class _ConnectedHostCard extends StatelessWidget {
  const _ConnectedHostCard({
    required this.connection,
    required this.onOpenSystem,
    this.onOpenConstellation,
  });

  final HostProductConnection connection;
  final VoidCallback onOpenSystem;

  /// Null until this Host has an Owner whose devices could have a history.

  /// The star map. Offered only once there is an Owner: a sovereign domain with
  /// no Owner has nothing to draw.
  final VoidCallback? onOpenConstellation;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('local-connection-complete'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.verified_user,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '已安全连接',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text(networkLabel(connection.overview.state.network)),
                ],
              ),
              const SizedBox(height: 16),
              // How the Host was located is not shown. It was the mDNS
              // instance name here, which was already developer detail, and
              // once locating gained other means it started printing their
              // internal labels — 服务：remembered — at a person. Where it
              // answered is a fact about their Host; which mechanism found it
              // is a fact about this App.
              Text('Host IP：${connection.endpoint.ipAddress}'),
              Text('Controller：${connection.controllerId}'),
              Text('本次管理会话有效至 ${_localTime(connection.sessionExpiresAt)}'),
              const SizedBox(height: 12),
              // Two entries, and the split is the one §3.2 argued for: the
              // sovereign domain (who, and what is happening for them) is a
              // picture; this machine (how it is, and what can be done about
              // it) is text. Four buttons read three of the same sources.
              if (onOpenConstellation case final open?) ...[
                FilledButton.icon(
                  key: const Key('open-constellation'),
                  onPressed: open,
                  icon: const Icon(Icons.hub_outlined),
                  label: const Text('驾驶舱'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                key: const Key('open-host-runtime-status'),
                onPressed: onOpenSystem,
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('主机运行状态'),
              ),
            ],
          ),
        ),
      );
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.controller,
    required this.ownerName,
    required this.companionName,
    required this.setupContinuation,
    required this.onSetupComplete,
    required this.onReconnect,
    required this.onChangeNetwork,
    required this.onOpenCompanion,
    required this.onOpenRoster,
    required this.onOpenMemoryLibrary,
    this.memoryHold,
    required this.onRenameOwner,
  });

  final HostProductController controller;
  final TextEditingController ownerName;
  final TextEditingController companionName;
  final bool setupContinuation;
  final VoidCallback? onSetupComplete;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onChangeNetwork;
  final void Function(HostCompanion companion) onOpenCompanion;

  /// Reachable whether or not the runtime answered: "what do I have" is a
  /// question the management contract answers on its own, and a Host that
  /// cannot report a running Companion may still have a roster to show.
  final VoidCallback onOpenRoster;

  /// Reachable whether or not the runtime answered: what is remembered is the
  /// Owner's memory, and it does not depend on a Companion running right now.
  final VoidCallback onOpenMemoryLibrary;

  /// Why this Host is not offering its memory, when it is not offering it.
  final String? memoryHold;

  /// Null until the Host has a Workspace to name anyone in.
  final VoidCallback? onRenameOwner;

  @override
  Widget build(BuildContext context) {
    final workspace = controller.workspace;
    if (workspace?.isReady ?? false) {
      return _buildReady(context, workspace!);
    }
    if (workspace == null && controller.workspaceError != null) {
      return _buildUnavailable(context);
    }
    return Card(
      key: const Key('workspace-setup'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('完成你的 Eidolon', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('主机已经安全接入。现在创建首个 Owner、主 Companion 和 Workspace。'),
            if (controller.workspaceError case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                key: const Key('workspace-setup-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              key: const Key('workspace-owner-name'),
              controller: ownerName,
              enabled: !controller.workspaceBusy,
              maxLength: 128,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '怎么称呼你',
                hintText: '例如：Manson',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('workspace-companion-name'),
              controller: companionName,
              enabled: !controller.workspaceBusy,
              maxLength: 128,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _initialize(),
              decoration: const InputDecoration(
                labelText: 'Eidolon 的名字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('initialize-workspace'),
              onPressed: controller.workspaceBusy ? null : _initialize,
              icon: controller.workspaceBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(controller.workspaceBusy ? '正在创建' : '创建我的 Eidolon'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('retry-workspace-status'),
              onPressed:
                  controller.workspaceBusy ? null : controller.refreshWorkspace,
              icon: const Icon(Icons.refresh),
              label: const Text('检查已有进度'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnavailable(BuildContext context) => Card(
        key: const Key('workspace-unavailable'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Workspace 状态暂不可用',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                controller.workspaceError!,
                key: const Key('workspace-setup-error'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('retry-workspace-status'),
                onPressed: controller.workspaceBusy
                    ? null
                    : controller.refreshWorkspace,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载 Workspace'),
              ),
            ],
          ),
        ),
      );

  void _initialize() => controller.initializeWorkspace(
        ownerDisplayName: ownerName.text,
        companionDisplayName: companionName.text,
      );

  /// One row per Eidolon this person has.
  ///
  /// The default one is *marked*, not promoted: 「默认应答」 is a setting on one
  /// row, where it used to be the identity of the whole card. Running state
  /// comes from the Host and has three values — a runtime it could not ask
  /// about says so rather than reading as "stopped".
  List<Widget> _companionRows(BuildContext context, HostHome? home) {
    if (home == null) return const [];
    if (home.companions.isEmpty) {
      return [
        _WorkspaceResourceStatus(
          key: const Key('no-companions-row'),
          icon: Icons.face_retouching_natural,
          label: '还没有 Eidolon',
          statusLabel: '可新建',
          detail: '在「你所有的 Eidolon」里建第一个',
          onOpen: onOpenRoster,
          openKey: const Key('open-roster-empty'),
          openTooltip: '新建',
        ),
      ];
    }
    return [
      for (final companion in home.companions)
        _WorkspaceResourceStatus(
          key: Key('home-companion-${companion.companionId}'),
          onOpen: () => onOpenCompanion(companion),
          openKey: Key('open-companion-${companion.companionId}'),
          openTooltip: '打开它',
          icon: Icons.face_retouching_natural,
          // The name its Owner gave it. The identifier is what remains when the
          // Host cannot say — never shown as if it were a name.
          label: companion.displayName.isNotEmpty
              ? companion.displayName
              : '未命名的 Eidolon',
          statusLabel: _companionStatus(companion, home),
          detail: _companionDetail(companion, home),
        ),
    ];
  }

  /// What state this Eidolon is in, in three words or fewer.
  ///
  /// Life comes first: an Eidolon somebody put away is put away whatever the
  /// runtime says, and showing 运行中 over 已收起 would describe the machine
  /// instead of the person's decision.
  String _companionStatus(HostCompanion companion, HostHome home) {
    if (companion.isPutAway) return '已收起';
    switch (companion.running) {
      case true:
        return '在运行';
      case false:
        return '没在运行';
      default:
        return '状态未知';
    }
  }

  String _companionDetail(HostCompanion companion, HostHome home) {
    final parts = <String>[];
    if (companion.companionId == home.defaultCompanionId) {
      parts.add('没指名时由它回答');
    }
    if (companion.running == null && home.runtimeUnavailable.isNotEmpty) {
      // Why it is unknown, not merely that it is: 「主机的运行服务在启动」 and
      // 「这台主机没有运行服务」 send a person to different places.
      parts.add(switch (home.runtimeUnavailable) {
        'runtime_starting' => '运行服务正在启动，稍后再看',
        'runtime_not_configured' => '这台主机没有配置运行服务',
        _ => '暂时问不到运行服务',
      });
    }
    if (parts.isEmpty) parts.add('打开它：它是谁、它记得什么、连着哪些设备');
    return parts.join(' · ');
  }

  Widget _buildReady(BuildContext context, WorkspaceStatus workspace) {
    final home = controller.home;
    return Card(
      key: const Key('workspace-ready'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Eidolon 已准备就绪',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('你好，${workspace.owner!.displayName}。'),
                ),
                if (onRenameOwner != null)
                  IconButton(
                    key: const Key('rename-owner'),
                    onPressed: onRenameOwner,
                    tooltip: '改名',
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Every Eidolon this person has, one row each. Not one promoted to
            // the top of the card with the rest reduced to a number: the Owner's
            // own screen is about their Eidolons, and which of them replies when
            // nobody was named is a setting on the set rather than the shape of
            // it. Two of them can be running at once, and this can say so.
            ..._companionRows(context, home),
            _WorkspaceResourceStatus(
              key: const Key('companion-roster-row'),
              onOpen: onOpenRoster,
              openKey: const Key('open-companion-roster'),
              openTooltip: '看全部',
              icon: Icons.groups_2_outlined,
              label: '你所有的 Eidolon',
              statusLabel:
                  home == null ? '可查看' : '${home.companionCounts.total} 个',
              detail: '新建一个，或者改由谁来应答',
            ),
            _WorkspaceResourceStatus(
              key: const Key('memory-library-row'),
              onOpen: onOpenMemoryLibrary,
              hold: memoryHold,
              openKey: const Key('open-memory-library'),
              openTooltip: '看它记住的',
              icon: Icons.auto_stories_outlined,
              // The Owner's, not any one Eidolon's: one Realm per person, and
              // every Eidolon reads and writes it through an audience. This row
              // used to say 它的记忆 and describe whichever one answered.
              label: '你的记忆',
              // Reachable, not "running". Whether a memory can be opened is
              // about this Host's memory service; the old label read
              // 「有没有默认伙伴」 and printed 运行中, which was a guess about a
              // different thing entirely.
              statusLabel: memoryHold == null ? '可查看' : '暂不可用',
              // Not the realm identifier. That line was the only thing this
              // row ever said, and it named a thing an Owner cannot open,
              // search or act on — an identifier standing in for the fact
              // that there is nothing here to show yet.
              // What it actually holds when the Host could say, and an honest
              // placeholder when it could not: a memory nothing has been
              // written into yet is a real and ordinary state.
              detail: home?.memory.isNotEmpty == true
                  ? '${home!.memory}，留在这台主机上，没有离开过'
                  : '还没记下什么，留在这台主机上，没有离开过',
            ),
            if (controller.homeError case final error?) ...[
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error,
                    key: const Key('home-error'),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                key: const Key('retry-home'),
                onPressed: controller.workspaceBusy
                    ? null
                    : controller.refreshWorkspace,
                icon: const Icon(Icons.refresh),
                label: const Text('重新读取概览'),
              ),
            ],
            if (setupContinuation) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('finish-workspace-setup'),
                onPressed: onSetupComplete,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('进入我的 Eidolon'),
              ),
            ] else ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                key: const Key('refresh-host-product-state'),
                onPressed: controller.connecting || controller.workspaceBusy
                    ? null
                    : onReconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('重新发现并刷新'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('change-network-from-product'),
                onPressed: controller.connecting || controller.workspaceBusy
                    ? null
                    : onChangeNetwork,
                icon: const Icon(Icons.wifi),
                label: const Text('更换 Wi-Fi'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DevicesSummaryCard extends StatelessWidget {
  const _DevicesSummaryCard({
    required this.controller,
    required this.onOpen,
    required this.onOpenControllers,
  });

  final HostProductController controller;
  final VoidCallback onOpen;
  final VoidCallback onOpenControllers;

  @override
  Widget build(BuildContext context) {
    final count = controller.devices?.devices.length;
    return Card(
      key: const Key('mounted-devices-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_other_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child:
                      Text('设备', style: Theme.of(context).textTheme.titleLarge),
                ),
                if (count != null) Chip(label: Text('$count')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              controller.devicesError ??
                  (count == 0
                      ? '还没有由主机确认接入的设备。'
                      : '查看主机已确认挂载的设备和 Companion 关联。'),
              style: controller.devicesError == null
                  ? null
                  : TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              key: const Key('open-mounted-devices'),
              onPressed: onOpen,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('打开设备管理'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('open-managed-controllers'),
              onPressed: onOpenControllers,
              icon: const Icon(Icons.phonelink_lock_outlined),
              label: const Text('管理手机'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceResourceStatus extends StatelessWidget {
  const _WorkspaceResourceStatus({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.statusLabel,
    this.onOpen,
    this.openKey,
    this.openTooltip,
    this.hold,
  });

  final IconData icon;
  final String label;
  final String detail;
  final String statusLabel;

  /// Offered where the row stands for something with more behind it than a
  /// status. Tapping goes there; the row is not itself the whole story.
  final VoidCallback? onOpen;

  /// The button's own key and tooltip, per row.
  ///
  /// These used to be hard-coded to 'open-persona-history' and '它的变化' for
  /// every row that had a button — a leftover from when only one row did. The
  /// moment a second one appeared, two different destinations answered to the
  /// same key and offered the same tooltip, and a test tapping that key would
  /// have opened whichever one was built first.
  final Key? openKey;
  final String? openTooltip;

  /// Why this row is not openable, when the Host says it is not.
  ///
  /// The row stays and carries the reason. Removing it would teach someone the
  /// feature was gone; leaving the button would open a page that cannot load.
  final String? hold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (hold != null)
              Chip(label: Text(hold!))
            else if (onOpen != null)
              IconButton(
                key: openKey,
                onPressed: onOpen,
                tooltip: openTooltip,
                icon: const Icon(Icons.chevron_right),
              ),
            Icon(
              Icons.check_circle_outline,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Text(statusLabel),
          ],
        ),
      );
}

String _localTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

/// The edit page plus the request state it cannot own.
///
/// Separate so the page stays a form: it renders who the Eidolon is and hands
/// back what was typed. Keeping the request here also puts a refusal *on* the
/// form, beside the words that caused it, rather than behind a pop back to the
/// Eidolon's page where the person can no longer see what they wrote.
class _PersonaEditRoute extends StatefulWidget {
  const _PersonaEditRoute({
    required this.displayName,
    required this.standing,
    required this.save,
  });

  final String displayName;
  final PersonaAuthoring standing;
  final Future<PersonaAuthoring> Function(PersonaAuthoring authored) save;

  @override
  State<_PersonaEditRoute> createState() => _PersonaEditRouteState();
}

class _PersonaEditRouteState extends State<_PersonaEditRoute> {
  bool _busy = false;
  String? _refusal;

  @override
  Widget build(BuildContext context) {
    return PersonaEditPage(
      displayName: widget.displayName,
      standing: widget.standing,
      busy: _busy,
      refusal: _refusal,
      onSave: (authored) async {
        final navigator = Navigator.of(context);
        setState(() {
          _busy = true;
          _refusal = null;
        });
        try {
          await widget.save(authored);
          if (!mounted) return;
          navigator.pop();
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _refusal = '没能保存：${failureSentence(error)}';
          });
        }
      },
    );
  }
}
