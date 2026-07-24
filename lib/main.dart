import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import 'src/avatar/avatar_stage.dart';
import 'src/controller/client_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EidolonMobileApp());
}

class EidolonMobileApp extends StatelessWidget {
  const EidolonMobileApp({super.key});

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
      home: const ClientPage(),
    );
  }
}

class ClientPage extends StatefulWidget {
  const ClientPage({super.key});

  @override
  State<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends State<ClientPage> with WidgetsBindingObserver {
  late final ClientController controller;
  final manualUrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = ClientController()..addListener(_refresh);
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
    manualUrl.dispose();
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
        const SizedBox(height: 16),
        ..._detailChildren(includeActions: true),
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
            child: Center(child: _Stage(controller: controller)),
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
                    onManualUrl: _showManualUrl,
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
              onManualUrl: _showManualUrl,
            ),
          ),
        ],
      ];

  Future<void> _showManualUrl() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动指定 Hub'),
        content: TextField(
          controller: manualUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.10:8082/api/device/register',
            labelText: 'register_url',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('连接')),
        ],
      ),
    );
    if (accepted == true) {
      await controller.start(manualRegisterUrl: manualUrl.text);
    }
  }
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
                    Text('Android client demo',
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

class _Stage extends StatelessWidget {
  const _Stage({required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final track = controller.remoteVideoTrack;
    final state = controller.uiState;
    // Render the live talking-head only while the agent is speaking; the worker
    // publishes a frozen frame between turns, so idle keeps the local placeholder.
    final showVideo = shouldShowAvatarVideo(
      hasVideoTrack: track != null,
      turn: state.agentTurn,
    );
    final accent = switch (state.agentTurn) {
      AgentTurnState.listening => const Color(0xFF50E3C2),
      AgentTurnState.thinking => const Color(0xFF9B92FF),
      AgentTurnState.speaking => const Color(0xFF7B6CFF),
      AgentTurnState.idle => const Color(0xFF6F61FF),
    };
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
                          track!,
                          fit: VideoViewFit.cover,
                          key: const ValueKey('avatar-video'),
                        )
                      : Center(
                          key: const ValueKey('avatar-idle'),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                width: state.agentSpeaking ? 124 : 106,
                                height: state.agentSpeaking ? 124 : 106,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: accent.withValues(alpha: .16),
                                  border: Border.all(
                                    color: accent.withValues(alpha: .55),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: accent.withValues(alpha: .28),
                                      blurRadius: state.agentSpeaking ? 58 : 42,
                                      spreadRadius:
                                          state.agentSpeaking ? 12 : 7,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  state.microphone == MicrophoneState.muted
                                      ? Icons.mic_off_rounded
                                      : state.agentTurn ==
                                              AgentTurnState.thinking
                                          ? Icons.auto_awesome_rounded
                                          : Icons.graphic_eq_rounded,
                                  size: 52,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(height: 22),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: Text(
                                  state.headline,
                                  key: ValueKey(state.headline),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 7),
                              SizedBox(
                                width: 360,
                                child: Text(
                                  state.supportingText,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
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
                    identity.deviceId,
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
                      ClipboardData(text: identity.deviceId),
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
    const labels = ['发现 Hub', '管理员批准', '绑定 Companion'];
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

class _Actions extends StatelessWidget {
  const _Actions({required this.controller, required this.onManualUrl});
  final ClientController controller;
  final VoidCallback onManualUrl;

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
                      state.phase == ClientPhase.error ? '重新连接' : '发现并连接 Hub'),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: state.busy ? null : onManualUrl,
              child: const Text('mDNS 不可用？手动输入地址'),
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
