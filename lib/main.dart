import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:video_player/video_player.dart';

import 'src/avatar/idle_clip_cache.dart';
import 'src/avatar/avatar_stage.dart';
import 'src/controller/client_controller.dart';
import 'src/features/conversation/conversation_provisioner.dart';
import 'src/features/conversation/conversation_flow.dart';
import 'src/features/conversation/mobile_device_runtime.dart';
import 'src/features/conversation/device_owner_directory.dart';
import 'src/features/device_setup/owner_authority_routes.dart';
import 'src/features/conversation/product_conversation_page.dart';
import 'src/features/device_management/mounted_devices_page.dart';
import 'src/features/host_setup/host_runtime_status_page.dart';
import 'src/features/device_setup/mobile_body_enrollment_session.dart';
import 'src/features/device_setup/device_setup_ports.dart';
import 'src/features/device_setup/host_controller_device_admission.dart';
import 'src/features/setup/eidolon_app_shell.dart';
import 'src/features/setup/host_registry.dart';
import 'src/platform/platform_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EidolonMobileApp());
}

class EidolonMobileApp extends StatefulWidget {
  const EidolonMobileApp({
    super.key,
    this.hostRegistry,
    this.deviceProvisioning,
  });

  final HostRegistry? hostRegistry;
  final DeviceProvisioningTransport? deviceProvisioning;

  @override
  State<EidolonMobileApp> createState() => _EidolonMobileAppState();
}

class _EidolonMobileAppState extends State<EidolonMobileApp> {
  late final MobileDeviceRuntime _deviceRuntime = MobileDeviceRuntime(
      directory: DeviceOwnerDirectory(
          routes: OwnerAuthorityRoutes(registry: widget.hostRegistry)));

  @override
  void dispose() {
    unawaited(_deviceRuntime.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eidolon Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6F61FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D13),
        useMaterial3: true,
      ),
      home: EidolonAppShell(
        registry: widget.hostRegistry,
        deviceProvisioning: widget.deviceProvisioning,
        conversationBuilder: (_, controller) {
          Future<void>? preparing;
          Future<void> prepareManagement() {
            if (controller.workspace?.isReady == true) {
              return Future<void>.value();
            }
            return preparing ??=
                controller.connect().whenComplete(() => preparing = null);
          }

          return ProductConversationPage(
            hostName: controller.host.displayName,
            createFlow: () => _deviceRuntime.open(
                hostId: controller.host.hostId,
                hostName: controller.host.displayName,
                bootstrap: () async {
                  await prepareManagement();
                  return controller.fetchDeviceOnboardingTarget();
                },
                management: ConversationManagement(
                    controllerId: controller.host.controllerId,
                    admission: HostControllerDeviceAdmission(controller,
                        prepare: prepareManagement),
                    roster: ({cursor}) async {
                      await prepareManagement();
                      return controller.roster(cursor: cursor);
                    },
                    device: (id) async {
                      await prepareManagement();
                      await controller.refreshDevices();
                      if (controller.devicesError != null) {
                        throw StateError(controller.devicesError!);
                      }
                      return controller.devices?.devices
                          .where((d) => d.deviceId == id)
                          .firstOrNull;
                    },
                    assign: controller.setDeviceCompanion)),
            openDevices: (context) => Navigator.of(context).push<void>(
                MaterialPageRoute(
                    builder: (_) =>
                        MountedDevicesPage(controller: controller))),
            openHostStatus: (context) async {
              final connection = controller.connection;
              if (connection == null) throw StateError('请先连接主机管理服务');
              await Navigator.of(context).push<void>(MaterialPageRoute(
                  builder: (_) => HostRuntimeStatusPage(
                      host: controller.host,
                      connection: connection,
                      readMonitor: controller.hostMonitor)));
            },
          );
        },
      ),
    );
  }
}

class ClientPage extends StatefulWidget {
  const ClientPage({
    super.key,
    this.provisioner,
    this.enrollment,
    this.onApproveThisPhone,
    this.platform,
  });

  final ConversationProvisioner? provisioner;

  /// Injectable so a test can drive this screen with a phone identity, the way
  /// the setup pages take their transports. Every fake in this app used to sit
  /// below the controller, which is how the screen's own words went unread.
  final PlatformBridge? platform;

  /// Take the Owner to the approval queue for this phone's own proposal.
  ///
  /// Present because the phone waiting for approval is the Controller that may
  /// give it. It used to poll for that approval every five seconds and offer
  /// 「立即检查状态」 — a refresh button in front of a decision the person
  /// holding the phone was already authorised to make.
  /// The Enrollment this phone has in flight, if this build wired one.
  ///
  /// Null draws no Enrollment control at all — the screen keeps saying what is
  /// true and offers nothing, which is where it was before any of this existed.
  /// A button wired to nothing would be worse than that silence.
  final MobileBodyEnrollmentSession? enrollment;

  final Future<void> Function(BuildContext context)? onApproveThisPhone;

  @override
  State<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends State<ClientPage> with WidgetsBindingObserver {
  late final ClientController controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = ClientController(
      conversationProvisioner: widget.provisioner,
      enrollment: widget.enrollment,
      platform: widget.platform,
    )..addListener(_refresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.onAppResumed();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(controller: controller),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final useTwoPane = constraints.maxWidth >= 900 &&
                      constraints.maxHeight >= 560;
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1440),
                      child: useTwoPane
                          ? _buildTabletLayout()
                          : _buildCompactLayout(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactLayout() {
    return ListView(
      key: const Key('compact-layout'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        _Stage(controller: controller),
        const SizedBox(height: 12),
        _AgentStatePanel(controller: controller),
        // Primary action sits right under the stage — "开始全双工对话" used to be
        // last in the list, pushed below the fold by the status card/transcript.
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('compact-actions'),
          child: _Actions(
            controller: controller,
            onApproveThisPhone: widget.onApproveThisPhone,
          ),
        ),
        const SizedBox(height: 16),
        ..._detailChildren(includeActions: false),
      ],
    );
  }

  Widget _buildTabletLayout() {
    return Padding(
      key: const Key('tablet-layout'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Stage(controller: controller),
                  const SizedBox(height: 12),
                  _AgentStatePanel(controller: controller),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    children: _detailChildren(includeActions: false),
                  ),
                ),
                const SizedBox(height: 14),
                KeyedSubtree(
                  key: const Key('tablet-actions'),
                  child: _Actions(
                    controller: controller,
                    onApproveThisPhone: widget.onApproveThisPhone,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _detailChildren({required bool includeActions}) => [
        _StatusCard(controller: controller),
        if (controller.notice case final notice?) ...[
          const SizedBox(height: 12),
          _NoticeCard(message: notice),
        ],
        if (controller.failure case final failure?) ...[
          const SizedBox(height: 12),
          _FailureCard(
            failure: failure,
            onDismiss: controller.dismissFailure,
            onRetry: controller.phase == ClientPhase.ready
                ? () => controller.join()
                : () => controller.retry(),
          ),
        ],
        if (controller.transcript.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Transcript(lines: controller.transcript),
        ],
        if (includeActions) ...[
          const SizedBox(height: 18),
          KeyedSubtree(
            key: const Key('compact-actions'),
            child: _Actions(
              controller: controller,
              onApproveThisPhone: widget.onApproveThisPhone,
            ),
          ),
        ],
      ];
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                      colors: [Color(0xFF7B6CFF), Color(0xFF35D6C3)]),
                ),
                child: const Icon(Icons.auto_awesome,
                    color: Colors.white, size: 21),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Eidolon Mobile',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 18)),
                    Text('本地 Companion 客户端',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              _ConnectionBadge(state: controller.uiState),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stage extends StatefulWidget {
  const _Stage({required this.controller});
  final ClientController controller;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  bool _showVideo = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncVideoVisibility);
    _syncVideoVisibility();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncVideoVisibility);
    super.dispose();
  }

  // Once subscribed, the worker's frozen last frame remains the resting face
  // through listening/idle. Only an actual track removal falls back to the local
  // idle clip.
  void _syncVideoVisibility() {
    final active = isAvatarVideoActive(
      hasVideoTrack: widget.controller.remoteVideoTrack != null,
      turn: widget.controller.uiState.agentTurn,
    );
    if (_showVideo != active && mounted) setState(() => _showVideo = active);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final track = controller.remoteVideoTrack;
    final state = controller.uiState;
    // Avatar area ONLY — the agent state machine lives in _AgentStatePanel.
    // Keep the subscribed live/last-frame video for the entire voice session.
    final showVideo = _showVideo && track != null;
    // At idle, play the configured idle-loop clip over the placeholder (falls
    // back to the placeholder when there's no clip / it fails to load).
    final idleClipUrl = controller.idleClipUrl;
    return TweenAnimationBuilder<double>(
      key: ValueKey(state.attentionSequence),
      tween: Tween(begin: 0, end: 1),
      duration: state.attention == DeviceAttentionEffect.none
          ? Duration.zero
          : const Duration(milliseconds: 900),
      curve: Curves.easeOut,
      builder: (context, progress, child) {
        final wiggle = state.attention == DeviceAttentionEffect.wiggle
            ? math.sin(progress * math.pi * 8) * (1 - progress) * 13
            : 0.0;
        final scale = state.attention == DeviceAttentionEffect.identify
            ? 1 + math.sin(progress * math.pi) * .025
            : 1.0;
        return Transform.translate(
          offset: Offset(wiggle, 0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  Color(0xFF292253),
                  Color(0xFF15131E),
                  Color(0xFF101017)
                ],
                radius: 1.15,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: showVideo
                      ? VideoTrackRenderer(
                          track,
                          fit: VideoViewFit.cover,
                          key: const ValueKey('avatar-video'),
                        )
                      : Stack(
                          key: const ValueKey('avatar-idle'),
                          fit: StackFit.expand,
                          children: [
                            const Center(child: _AvatarPlaceholder()),
                            if (idleClipUrl != null)
                              Positioned.fill(
                                child: _IdleClipStage(
                                  url: idleClipUrl,
                                  headersProvider: controller.idleClipHeaders,
                                ),
                              ),
                          ],
                        ),
                ),
                Positioned(
                  left: 18,
                  top: 18,
                  child: _StageBadge(
                    icon: showVideo
                        ? Icons.videocam_rounded
                        : Icons.headphones_rounded,
                    label: showVideo ? '数字人视频' : '语音模式',
                  ),
                ),
                if (state.attention != DeviceAttentionEffect.none)
                  Positioned(
                    right: 18,
                    top: 18,
                    child: _StageBadge(
                      icon: state.attention == DeviceAttentionEffect.identify
                          ? Icons.campaign_rounded
                          : Icons.vibration_rounded,
                      label: state.attention == DeviceAttentionEffect.identify
                          ? '管理端点名'
                          : '动一动',
                    ),
                  ),
                if (state.attention != DeviceAttentionEffect.none)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color:
                                const Color(0xFF50E3C2).withValues(alpha: .75),
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (state.microphone == MicrophoneState.muted)
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 18,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE7A23B).withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFE7A23B).withValues(alpha: .4),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.mic_off_rounded,
                              size: 18, color: Color(0xFFFFC96B)),
                          SizedBox(width: 8),
                          Text('麦克风已静音',
                              style: TextStyle(color: Color(0xFFFFD38B))),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Calm, static avatar placeholder shown when there's no live/idle video. It
/// carries NO state (no color/size/icon by agent turn) — the state machine is
/// the separate _AgentStatePanel — so the avatar area doesn't flash on toggles.
class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: .05),
        border:
            Border.all(color: Colors.white.withValues(alpha: .16), width: 1.5),
      ),
      child: const Icon(Icons.person_rounded, size: 52, color: Colors.white38),
    );
  }
}

/// Dedicated, always-on display of the agent turn state (idle / listening /
/// thinking / speaking). Decoupled from the avatar stage so state and avatar
/// never share a widget or toggle against each other.
class _AgentStatePanel extends StatelessWidget {
  const _AgentStatePanel({required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.uiState;
    // A connected full-duplex conversation is listening whenever no explicit
    // thinking/speaking state is active. `idle` is reserved for control-only
    // standby so the room state and agent turn state are not conflated.
    final displayedTurn = state.phase == ClientPhase.conversation &&
            state.agentTurn == AgentTurnState.idle
        ? AgentTurnState.listening
        : state.agentTurn;
    final (Color color, IconData icon, String label) = switch (displayedTurn) {
      AgentTurnState.listening => (
          const Color(0xFF50E3C2),
          Icons.hearing_rounded,
          '正在聆听',
        ),
      AgentTurnState.thinking => (
          const Color(0xFF9B92FF),
          Icons.auto_awesome_rounded,
          '思考中',
        ),
      AgentTurnState.speaking => (
          const Color(0xFF7B6CFF),
          Icons.graphic_eq_rounded,
          '说话中',
        ),
      AgentTurnState.idle => (
          const Color(0xFF8A8AA0),
          Icons.hourglass_empty_rounded,
          state.phase == ClientPhase.ready ? '通道在线 · 待命' : '待命',
        ),
    };
    final active = displayedTurn != AgentTurnState.idle;
    final muted = state.microphone == MicrophoneState.muted;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF171720),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: active ? .5 : .16)),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          if (muted) ...[
            const Spacer(),
            const Icon(Icons.mic_off_rounded,
                size: 16, color: Color(0xFFFFC96B)),
            const SizedBox(width: 6),
            const Text('已静音',
                style: TextStyle(color: Color(0xFFFFD38B), fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// Plays the companion's offline-generated idle-loop clip (fetched from hub with
/// signed headers) on a loop as the resting placeholder. Renders nothing until
/// the clip is ready and nothing on failure (404 / no clip), so the placeholder
/// behind it shows through.
class _IdleClipStage extends StatefulWidget {
  const _IdleClipStage({required this.url, required this.headersProvider});
  final String url;
  final Future<Map<String, String>> Function() headersProvider;

  @override
  State<_IdleClipStage> createState() => _IdleClipStageState();
}

class _IdleClipStageState extends State<_IdleClipStage> {
  VideoPlayerController? _player;
  late final IdleClipCache _cache;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _cache = IdleClipCache();
    _load();
  }

  @override
  void didUpdateWidget(_IdleClipStage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _teardown();
      _load();
    }
  }

  Future<void> _load() async {
    try {
      // Download with a fresh one-shot signature, then loop locally. ExoPlayer
      // may otherwise repeat a network request with the same nonce and receive
      // Hub's anti-replay 409.
      final file = await _cache.download(
        url: widget.url,
        headersProvider: widget.headersProvider,
      );
      final player = VideoPlayerController.file(file);
      await player.initialize();
      await player.setLooping(true);
      await player.setVolume(0); // idle clip is silence-driven; keep it muted
      await player.play();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _ready = true;
      });
    } catch (exception) {
      debugPrint('Idle clip load failed: $exception');
      // No idle clip or load failure → stay transparent; placeholder shows.
    }
  }

  void _teardown() {
    final player = _player;
    _player = null;
    _ready = false;
    if (player != null) player.dispose();
  }

  @override
  void dispose() {
    _teardown();
    _cache.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (!_ready || player == null) return const SizedBox.shrink();
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: player.value.size.width,
        height: player.value.size.height,
        child: VideoPlayer(player),
      ),
    );
  }
}

class _StageBadge extends StatelessWidget {
  const _StageBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .28),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.uiState;
    final aecActive = state.phase == ClientPhase.conversation &&
        state.voiceConnection == ChannelConnectionState.connected;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: const Color(0xFF171720),
          borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              state.headline,
              key: ValueKey(state.headline),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            state.supportingText,
            style: const TextStyle(color: Colors.white54, height: 1.35),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              const _Tag(
                icon: Icons.sync_alt_rounded,
                label: '全双工',
                active: true,
              ),
              _Tag(
                icon: Icons.hearing_rounded,
                label: aecActive ? 'AEC 已启用' : '支持 AEC',
                active: aecActive,
              ),
              if (controller.hub != null)
                _Tag(
                    icon: Icons.lan_rounded,
                    label: controller.hub!.instanceName,
                    active: state.hubOnline),
              if (controller.remoteVideoTrack != null)
                const _Tag(
                  icon: Icons.videocam_rounded,
                  label: '数字人视频',
                  active: true,
                ),
            ],
          ),
          if (state.phase == ClientPhase.awaitingApproval ||
              state.phase == ClientPhase.awaitingBinding) ...[
            const SizedBox(height: 18),
            _ProvisioningProgress(phase: state.phase),
          ],
          if (controller.identity case final identity?) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    // This phone's identity in the Owner Domain, derived from
                    // its own operational key. What used to be printed here —
                    // and copied, and quoted in bug reports — was
                    // `mobile-android-<hash of ANDROID_ID>`, a string Hub has
                    // no record of and would refuse.
                    identity.deviceInstanceId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '复制设备 ID',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: identity.deviceInstanceId),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('设备 ID 已复制')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProvisioningProgress extends StatelessWidget {
  const _ProvisioningProgress({required this.phase});

  final ClientPhase phase;

  @override
  Widget build(BuildContext context) {
    final activeStep = phase == ClientPhase.awaitingApproval ? 1 : 2;
    const labels = ['验证 Hub', '认领 Mobile', '准备对话'];
    return Row(
      children: List.generate(labels.length, (index) {
        final completed = index < activeStep;
        final active = index == activeStep;
        return Expanded(
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: completed
                      ? const Color(0xFF50E3C2)
                      : active
                          ? const Color(0xFF7B6CFF)
                          : Colors.white12,
                ),
                child: completed
                    ? const Icon(Icons.check_rounded,
                        size: 14, color: Color(0xFF071A17))
                    : Center(
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  labels[index],
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        active || completed ? Colors.white70 : Colors.white30,
                  ),
                ),
              ),
              if (index != labels.length - 1) const SizedBox(width: 5),
            ],
          ),
        );
      }),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF6F61FF).withValues(alpha: .12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF8A7FFF).withValues(alpha: .28),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded,
                size: 19, color: Color(0xFFB8B1FF)),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      );
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({
    required this.failure,
    required this.onDismiss,
    required this.onRetry,
  });

  final ClientFailure failure;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFF6B6B).withValues(alpha: .09),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFFFF8D8D).withValues(alpha: .25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.error_outline_rounded,
                        size: 20, color: Color(0xFFFF9A9A)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(failure.title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(
                          failure.message,
                          style: const TextStyle(
                            color: Colors.white60,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭提示',
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 12, 10),
              child: Row(
                children: [
                  if (failure.retryable)
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('重试'),
                    ),
                  const Spacer(),
                  PopupMenuButton<void>(
                    tooltip: '查看技术详情',
                    itemBuilder: (context) => [
                      PopupMenuItem<void>(
                        enabled: false,
                        child: SizedBox(
                          width: 360,
                          child: SelectableText(
                            failure.technicalDetails,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('技术详情',
                          style:
                              TextStyle(fontSize: 12, color: Colors.white54)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// The control for a stopped Enrollment, or the honest absence of one.
///
/// Five outcomes, because there are five. Collapsing them was the original
/// defect on this screen: 「立即检查状态」 stood in front of an Enrollment that
/// no party was making, and later in front of one no party could finish.
class _EnrollmentAction extends StatelessWidget {
  const _EnrollmentAction({required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final busy = controller.uiState.busy;
    switch (controller.enrollmentAct) {
      case MobileBodyEnrollmentAct.propose:
        return _button(
          // Not 「开始对话」. What this does is propose; the approval that
          // follows is a second act by the same person, and a label promising
          // a conversation would hide it.
          label: '登记这台手机',
          icon: Icons.badge_rounded,
          onPressed: busy ? null : controller.proposeSelf,
        );
      case MobileBodyEnrollmentAct.collect:
        return _button(
          label: '领取归属凭证',
          icon: Icons.download_done_rounded,
          onPressed: busy ? null : controller.finishEnrollment,
        );
      case MobileBodyEnrollmentAct.abandon:
        return _button(
          label: '撤回这次登记',
          icon: Icons.undo_rounded,
          onPressed: busy ? null : controller.abandonEnrollment,
          // A withdrawal is not the thing this screen is for, and it undoes
          // something. It gets the quieter of the two buttons.
          tonal: true,
        );
      case MobileBodyEnrollmentAct.waitForExpiry:
        // No control at all, and this is the case that most tempts one. The
        // Authority does not allow `approved_awaiting_handoff` to be
        // cancelled, so 「撤回」 here would fail every time it was pressed. The
        // sentence beside it names the expiry; nothing here should suggest the
        // wait can be shortened.
        return const SizedBox.shrink();
      case MobileBodyEnrollmentAct.approve:
      case MobileBodyEnrollmentAct.none:
        // `approve` is drawn by the approval route above, and `none` is a gap
        // this phone cannot close.
        return const SizedBox.shrink();
    }
  }

  Widget _button({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool tonal = false,
  }) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Text(label),
    );
    return SizedBox(
      width: double.infinity,
      child: tonal
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: child,
            )
          : FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: child,
            ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.controller, this.onApproveThisPhone});
  final ClientController controller;
  final Future<void> Function(BuildContext context)? onApproveThisPhone;

  @override
  Widget build(BuildContext context) {
    final state = controller.uiState;
    return switch (state.phase) {
      ClientPhase.conversation => _ConversationControls(controller: controller),
      ClientPhase.ready => SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: state.busy ? null : controller.join,
            icon: const Icon(Icons.forum_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('开始全双工对话'),
            ),
          ),
        ),
      // Stopped, and what can be done about it depends on two things at once:
      // what the Authority says, and whether this process still holds the
      // one-shot key and challenge the Enrollment needs. `enrollmentAct` is
      // that pair already resolved — see `mobile_body_enrollment_session.dart`.
      ClientPhase.bodyBlocked => _EnrollmentAction(controller: controller),
      ClientPhase.awaitingApproval
          when controller.awaitsThisControllersApproval &&
              onApproveThisPhone != null =>
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: state.busy ? null : () => onApproveThisPhone!(context),
            icon: const Icon(Icons.verified_user_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 13),
              child: Text('去批准这台手机'),
            ),
          ),
        ),
      // An act this phone can take is drawn wherever it exists, not only where
      // the stage is stopped. `collect` lives here: the stage advances, so the
      // phase is never `bodyBlocked`, and this branch's bare 「立即检查状态」 was
      // the only thing on screen while a Grant sat waiting to be redeemed. The
      // controller now redeems it by itself; this is what a person is left with
      // when that attempt failed.
      ClientPhase.awaitingApproval ||
      ClientPhase.awaitingBinding
          when controller.enrollmentAct != MobileBodyEnrollmentAct.none &&
              !(controller.phase == ClientPhase.awaitingApproval &&
                  controller.awaitsThisControllersApproval) =>
        _EnrollmentAction(controller: controller),
      ClientPhase.awaitingApproval || ClientPhase.awaitingBinding => SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: state.busy ? null : controller.checkActivation,
            icon: state.busy
                ? const _SmallProgress()
                : const Icon(Icons.refresh_rounded),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Text(state.busy ? '正在检查…' : '立即检查状态'),
            ),
          ),
        ),
      ClientPhase.discovering ||
      ClientPhase.registering ||
      ClientPhase.activating ||
      ClientPhase.joining =>
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: null,
            icon: const _SmallProgress(),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Text(state.headline.replaceAll('…', '')),
            ),
          ),
        ),
      ClientPhase.idle || ClientPhase.error => Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: state.busy
                    ? null
                    : state.phase == ClientPhase.error
                        ? controller.retry
                        : controller.start,
                icon: state.busy
                    ? const _SmallProgress()
                    : const Icon(Icons.radar_rounded),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    state.phase == ClientPhase.error
                        ? '重新连接'
                        : controller.usesProductProvisioning
                            ? '连接我的 Eidolon'
                            : '发现并连接 Hub',
                  ),
                ),
              ),
            ),
          ],
        ),
    };
  }
}

class _ConversationControls extends StatelessWidget {
  const _ConversationControls({required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final microphone = controller.uiState.microphone;
    final switching = microphone == MicrophoneState.switching;
    final muted = microphone == MicrophoneState.muted;
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: switching ? null : controller.toggleMicrophone,
            icon: switching
                ? const _SmallProgress()
                : Icon(muted ? Icons.mic_off_rounded : Icons.mic_rounded),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Text(switching
                  ? '正在切换…'
                  : muted
                      ? '解除静音'
                      : '静音'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB54747),
              foregroundColor: Colors.white,
            ),
            onPressed: controller.leave,
            icon: const Icon(Icons.call_end_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 13),
              child: Text('结束对话'),
            ),
          ),
        ),
      ],
    );
  }
}

class _SmallProgress extends StatelessWidget {
  const _SmallProgress();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.lines});
  final List<TranscriptLine> lines;

  @override
  Widget build(BuildContext context) {
    final visible = lines.length <= 8 ? lines : lines.sublist(lines.length - 8);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF15151D),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.subtitles_rounded, size: 17, color: Colors.white54),
              SizedBox(width: 8),
              Text('实时转写',
                  style: TextStyle(fontSize: 13, color: Colors.white60)),
            ],
          ),
          const SizedBox(height: 6),
          ...visible.map((line) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  line.speaker,
                  style: const TextStyle(
                    color: Color(0xFF9B92FF),
                    fontSize: 12,
                  ),
                ),
                subtitle: Text(
                  line.text,
                  style: TextStyle(
                    color: line.isFinal ? Colors.white : Colors.white60,
                    fontStyle:
                        line.isFinal ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
                trailing: line.isFinal
                    ? null
                    : const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
              )),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.icon,
    required this.label,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .055),
            borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            icon,
            size: 14,
            color: active ? const Color(0xFF8BE5D9) : Colors.white54,
          ),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.white70))
        ]),
      );
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.state});

  final ClientUiState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state.phase) {
      ClientPhase.ready || ClientPhase.conversation => const Color(0xFF50E3C2),
      ClientPhase.awaitingApproval ||
      ClientPhase.awaitingBinding =>
        const Color(0xFFFFC96B),
      // Not amber. Amber is "in progress", and this state is stopped.
      ClientPhase.bodyBlocked => Colors.white38,
      ClientPhase.error => const Color(0xFFFF8D8D),
      ClientPhase.idle => Colors.white38,
      _ => const Color(0xFF9B92FF),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 7),
          Text(
            state.connectionLabel,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
