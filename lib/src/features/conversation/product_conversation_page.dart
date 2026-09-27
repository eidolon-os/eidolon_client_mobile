import 'role_group_controller.dart';
import 'role_group_page.dart';
import 'dart:async';
import '../../management/companion_portrait.dart';
import '../../models/conversation_mode.dart';
import 'package:flutter/material.dart';

import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';
import 'package:livekit_client/livekit_client.dart';

import '../device_setup/mobile_body_enrollment_session.dart';
import 'channel_refusal.dart';
import 'conversation_flow.dart';
import 'conversation_standing.dart';
import 'mobile_body_standing.dart';
import 'shared_conversation_preparation_page.dart';
import 'device_conversation_page.dart';
import '../device_management/mounted_device_models.dart';

class ProductConversationPage extends StatefulWidget {
  const ProductConversationPage(
      {super.key,
      required this.createFlow,
      required this.hostName,
      this.loadGroupDevices,
      this.changeSharedSession,
      this.deviceConversation,
      this.roleGroup,
      this.openDevices,
      this.openHostStatus});
  final Future<ConversationFlow> Function() createFlow;
  final String hostName;
  final DeviceConversationCommand? deviceConversation;
  final RoleGroupController? roleGroup;
  final Future<void> Function(String, List<String>?, String?)?
      changeSharedSession;
  final Future<MountedDeviceInventory> Function()? loadGroupDevices;
  final Future<void> Function(BuildContext)? openDevices;
  final Future<void> Function(BuildContext)? openHostStatus;
  @override
  State<ProductConversationPage> createState() =>
      _ProductConversationPageState();
}

class _ProductConversationPageState extends State<ProductConversationPage>
    with WidgetsBindingObserver {
  ConversationFlow? _flow;
  String? _error;
  String? _technicalError;
  bool _loading = true;
  bool _leaving = false;
  bool _allowPop = false;
  final _detailsScroll = ScrollController();
  String? _lastTranscript;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _technicalError = null;
    });
    try {
      final flow = await widget.createFlow();
      if (!mounted) {
        flow.dispose();
        return;
      }
      _flow = flow..addListener(_refresh);
      setState(() => _loading = false);
      await flow.initialize();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _technicalError = e.toString();
          _error = e is TimeoutException
              ? '主机暂未响应。请确认主机已开机并与本机处于同一网络，然后重试。'
              : e is FormatException
                  ? '主机身份或目录未通过校验，请在诊断中查看原因。'
                  : '暂未完成对话准备。请重试，或在诊断中检查主机服务。';
        });
      }
    }
  }

  void _refresh() {
    if (!mounted) return;
    final lines = _flow?.client.transcript;
    final last = lines == null || lines.isEmpty
        ? ''
        : '${lines.length}:${lines.last.text}';
    final changed = last.isNotEmpty && last != _lastTranscript;
    final followsLatest =
        !_detailsScroll.hasClients || _detailsScroll.position.extentAfter < 100;
    _lastTranscript = last;
    setState(() {});
    if (changed && followsLatest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detailsScroll.hasClients) {
          _detailsScroll.animateTo(_detailsScroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _flow?.client.onAppResumed();
    } else {
      unawaited(_flow?.client.setPttHeld(false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detailsScroll.dispose();
    _flow
      ?..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  Future<void> _back() async {
    if (_leaving) return;
    _leaving = true;
    await _flow?.close();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _recoverRegistration() async {
    final flow = _flow;
    if (flow == null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('恢复已有设备登记'),
              content: Text('核验本机在「${widget.hostName}」上已完成的登记。'
                  '验证成功后，本机将使用该登记继续对话。\n\n'
                  '验证失败会保留原记录，不会自动重新登记或更换设备归属。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('核验并恢复')),
              ],
            ));
    if (confirmed == true && mounted && identical(flow, _flow)) {
      await flow.client.recoverEnrollment();
    }
  }

  Future<void> _pickCompanion() async {
    final flow = _flow!;
    await flow.refreshManagement();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .7),
                child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    children: [
                      Text('选择应答伙伴',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                          flow.client.canLeave
                              ? '更换伙伴会结束当前对话，返回准备页。'
                              : '选好伙伴和对话方式后，点击开始对话。',
                          style: TextStyle(
                              color: Neon.inkDim, height: 1.6, fontSize: 13.5)),
                      const SizedBox(height: 16),
                      if (flow.companions.isEmpty)
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(flow.managementError ??
                                '还没有可用伙伴，请先在主机中添加或启用伙伴。')),
                      for (final c in flow.companions)
                        ListTile(
                            key: ValueKey('choose-${c.companionId}'),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            leading: CompanionPortrait(
                                companionId: c.companionId,
                                name: c.displayName ?? '',
                                artworkId: c.artworkId,
                                loadFace: flow.management.loadFace),
                            title: Text(c.displayName ?? c.companionId),
                            subtitle: flow.client.canLeave
                                ? const Text('结束当前对话并更换')
                                : null,
                            trailing: c.companionId == flow.selectedCompanionId
                                ? const Icon(Icons.check_circle_rounded,
                                    color: Neon.cyan)
                                : null,
                            onTap: () => Navigator.pop(context, c.companionId)),
                    ]))));
    if (chosen != null && mounted) {
      if (chosen != flow.selectedCompanionId && await _confirmChange()) {
        await flow.choose(chosen);
      }
    }
  }

  Future<bool> _confirmChange() async {
    if (!mounted) return false;
    if (_flow?.client.canLeave != true) return true;
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('结束当前对话？'),
                  content: const Text('更换后将回到准备页，点击开始对话即可接通。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('继续对话')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('结束并更换')),
                  ],
                )) ==
        true;
  }

  Widget _modes(ConversationFlow f) {
    final locked = f.busy || f.client.isBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('对话方式',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: .6,
                color: Neon.inkFaint)),
        const SizedBox(height: Neon.s2 + 2),
        Wrap(spacing: Neon.s2, runSpacing: Neon.s2, children: [
          for (final mode in ConversationMode.values)
            NeonChoice(
              key: ValueKey('mode-${mode.wireValue}'),
              label: mode.label,
              selected: f.selectedMode == mode,
              onTap: locked
                  ? null
                  : () async {
                      if (mode != f.selectedMode && await _confirmChange()) {
                        await f.chooseMode(mode);
                      }
                    },
            ),
        ]),
        const SizedBox(height: Neon.s3),
        Text(f.selectedMode?.description ?? '请选择一种对话方式',
            style: const TextStyle(
                color: Neon.inkFaint, fontSize: 12.5, height: 1.55)),
      ],
    );
  }

  Widget _pttButton(ConversationFlow f) {
    final c = f.client;
    final enabled = !f.busy && !c.isBusy && c.conversationStanding.answered;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '按住说话，松开发送',
      child: Listener(
        onPointerDown: enabled ? (_) => unawaited(c.setPttHeld(true)) : null,
        onPointerUp: (_) => unawaited(c.setPttHeld(false)),
        onPointerCancel: (_) => unawaited(c.setPttHeld(false)),
        child: NeonCta(
          enabled: enabled,
          color: c.pttHeld ? Neon.cyanSoft : Neon.cyan,
          child: FilledButton.icon(
            style: EidolonTheme.primaryButton(
                    colors: c.pttHeld
                        ? const [Neon.cyanSoft, Neon.cyan]
                        : Neon.accentGradient)
                .copyWith(
                    minimumSize:
                        const WidgetStatePropertyAll(Size.fromHeight(56))),
            onPressed: enabled ? () {} : null,
            icon: const Icon(Icons.mic_rounded),
            label: Text(c.pttHeld ? '松开发送' : '按住说话'),
          ),
        ),
      ),
    );
  }

  void _diagnostics() {
    final f = _flow;
    Future<void> open(Future<void> Function(BuildContext) destination) async {
      Navigator.pop(context);
      try {
        await destination(context);
        if (!mounted) return;
        if (f != null) {
          await f.retry();
        } else {
          await _load();
        }
      } catch (e) {
        _technicalError = e.toString();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂时无法打开主机检查，请稍后重试。')));
        }
      }
    }

    showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('对话诊断',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      if (_technicalError != null)
                        SelectableText(_technicalError!),
                      SelectableText(
                          'Owner：${f?.ownerDomainId ?? "尚未确认"}\n设备：${f?.client.identity?.deviceInstanceId ?? "尚未读取"}\n'
                          '密钥指纹：${f?.client.identity?.fingerprint ?? "尚未读取"}\n'
                          '通道：${f?.client.controlConnection.name}\n'
                          '${f?.client.config?.diagnostic ?? ""}\n'
                          '${f?.client.failure?.technicalDetails ?? ""}\n${f?.managementError ?? ""}'),
                      const SizedBox(height: 16),
                      if (widget.openDevices != null)
                        ListTile(
                            leading: const Icon(Icons.devices_rounded),
                            title: const Text('查看设备与授权'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => open(widget.openDevices!)),
                      if (widget.openHostStatus != null)
                        ListTile(
                            leading: const Icon(Icons.monitor_heart_outlined),
                            title: const Text('检查主机服务'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => open(widget.openHostStatus!)),
                    ]))));
  }

  @override
  Widget build(BuildContext context) {
    final flow = _flow;
    return PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_back());
        },
        child: Scaffold(
          key: const Key('product-conversation-page'),
          appBar: AppBar(
              leading: IconButton(
                  tooltip: '返回主机',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: _back),
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('对话',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.2)),
                    const SizedBox(height: 1),
                    Text(widget.hostName,
                        style: Neon.mono(size: 11, color: Neon.inkFaint)),
                  ]),
              actions: [
                if (flow != null || _error != null)
                  IconButton(
                      tooltip: '对话诊断',
                      onPressed: _diagnostics,
                      icon: const Icon(Icons.more_horiz_rounded))
              ]),
          body: _loading
              ? const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text('正在准备本机对话…')
                ]))
              : _error != null
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.all(28),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            const GlyphBadge(Icons.cloud_off_rounded,
                                color: Neon.warn, size: 58),
                            const SizedBox(height: Neon.s5),
                            Text('暂时无法连接',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 12),
                            ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 460),
                                child: Text(_error!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Neon.inkDim, height: 1.65))),
                            const SizedBox(height: 20),
                            FilledButton(
                                onPressed: _load, child: const Text('重新连接'))
                          ])))
                  : _body(flow!),
        ));
  }

  Widget _body(ConversationFlow flow) =>
      LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 850;
        final error = flow.error ?? flow.client.failure?.message;
        final errorShownInStatus = !flow.client.canJoin &&
            !flow.client.canLeave &&
            error == flow.client.uiState.supportingText;
        final content = <Widget>[
          if (widget.loadGroupDevices != null) ...[
            Material(
              color: Neon.surfaceHigh,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Neon.radiusM),
                side: const BorderSide(color: Neon.hair),
              ),
              child: ListTile(
                key: const Key('prepare-shared-conversation'),
                leading: const Icon(Icons.groups_2_outlined, color: Neon.cyan),
                title: Text(widget.deviceConversation == null ? '一起聊' : '跨设备对话'),
                subtitle: Text(flow.client.canLeave
                    ? '结束当前对话后，可准备多人搭配'
                    : widget.deviceConversation == null ? '选择参与设备 · 检查共享连接' : '选择输入、播放设备和回答的伙伴'),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled:
                    !flow.client.canLeave && !flow.busy && !flow.client.isBusy,
                onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                  builder: (_) => widget.deviceConversation != null
                    ? DeviceConversationPage(command: widget.deviceConversation!, load: () async {
                        final inventory = await widget.loadGroupDevices!();
                        return (devices: inventory.devices,
                          localDeviceId: flow.client.identity?.deviceInstanceId,
                          coverage: inventory.coverage);
                      }) : SharedConversationPreparationPage(
                    loadFace: flow.management.loadFace,
                    changeSession: widget.changeSharedSession,
                    load: () async {
                      final inventory = await widget.loadGroupDevices!();
                      return (
                        devices: inventory.devices,
                        localDeviceId: flow.client.identity?.deviceInstanceId,
                        coverage: inventory.coverage,
                      );
                    },
                  ),
                )),
              ),
            ),
            if (widget.roleGroup != null) ListTile(
              key: const Key('open-role-group'), leading: const Icon(Icons.groups),
              title: const Text('IP 角色团队'), subtitle: const Text('一个 PTT 输入 · 按对话内容决定谁回应'),
              enabled: !flow.client.canLeave && !flow.busy && !flow.client.isBusy,
              onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) =>
                RoleGroupPage(controller: widget.roleGroup!, load: () async {
                  final inventory = await widget.loadGroupDevices!();
                  return (devices: inventory.devices, localDeviceId: flow.client.identity?.deviceInstanceId,
                    coverage: inventory.coverage);
                })))),
            const SizedBox(height: 18),
          ],
          _partner(flow),
          const SizedBox(height: 18),
          _modes(flow),
          const SizedBox(height: 18),
          _status(flow),
          if (flow.client.enrollmentAct == MobileBodyEnrollmentAct.approve) ...[
            const SizedBox(height: 18),
            _approval(flow)
          ],
          if (error != null && !errorShownInStatus) ...[
            const SizedBox(height: 16),
            _notice(error, error: true)
          ],
          if (flow.client.activationExhausted) ...[
            const SizedBox(height: 16),
            _notice('准备时间比预期长。你可以重新检查，或在右上角诊断中查看主机服务。')
          ],
          if (flow.managementError != null && !flow.client.canLeave) ...[
            const SizedBox(height: 12),
            Text('伙伴信息暂不可用，可下拉刷新。已获得的设备授权不受影响。',
                style: const TextStyle(color: Neon.inkFaint, fontSize: 12.5))
          ],
          const SizedBox(height: 20),
          _transcript(flow),
        ];
        final details = RefreshIndicator(
            onRefresh: flow.retry,
            child: ListView(
                controller: _detailsScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(wide ? 12 : 24, 20, 24, 24),
                children: content));
        return SafeArea(
            top: false,
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: Column(children: [
                      Expanded(
                          child: wide
                              ? Row(children: [
                                  Expanded(
                                      child: Padding(
                                          padding: const EdgeInsets.all(32),
                                          child: _stage(flow, 330))),
                                  Expanded(child: details),
                                ])
                              : Column(children: [
                                  if (constraints.maxHeight > 620)
                                    Padding(
                                        padding: const EdgeInsets.only(top: 20),
                                        child: _stage(flow, 154)),
                                  Expanded(child: details),
                                ])),
                      Container(
                          padding: const EdgeInsets.fromLTRB(
                              Neon.s5, Neon.s4, Neon.s5, Neon.s5),
                          decoration: BoxDecoration(
                              border: const Border(
                                  top: BorderSide(color: Neon.hair)),
                              gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Neon.void_.withValues(alpha: .8),
                                  ])),
                          child: Center(
                              child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 640),
                                  child: _actions(flow)))),
                    ]))));
      });

  Widget _stage(ConversationFlow f, double size) {
    final track = f.client.remoteVideoTrack;
    final live = f.client.canLeave;
    final halo = live ? Neon.cyan : Neon.indigo;
    return Semantics(
        label: '伙伴形象',
        child: SizedBox(
            width: size + 36,
            height: size + 36,
            child: Stack(alignment: Alignment.center, children: [
              // Two quiet rings hold the portrait in the middle of the screen.
              // Without them the avatar floated in empty space and the page had
              // no centre.
              _halo(size + 36, halo, live ? .20 : .09),
              _halo(size + 18, halo, live ? .32 : .14),
              AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(colors: [
                        Color(0xFF1B2440),
                        Color(0xFF0D1324),
                        Color(0xFF070A14)
                      ]),
                      border: Border.all(
                          color: live
                              ? Neon.cyan.withValues(alpha: .75)
                              : Colors.white.withValues(alpha: .10),
                          width: live ? 2 : 1),
                      boxShadow:
                          Neon.glow(halo, blur: 48, alpha: live ? .30 : .16)),
                  child: ClipOval(
                      child: track != null
                          ? VideoTrackRenderer(track)
                          : Center(
                              child: f.selectedCompanionId == null
                                  ? Text('✦',
                                      style: TextStyle(
                                          fontSize: size * .28,
                                          color:
                                              Neon.cyan.withValues(alpha: .55)))
                                  : CompanionPortrait(
                                      companionId: f.selectedCompanionId!,
                                      name: f.companionName,
                                      artworkId: f.companions
                                          .where((c) =>
                                              c.companionId ==
                                              f.selectedCompanionId)
                                          .firstOrNull
                                          ?.artworkId,
                                      loadFace: f.management.loadFace,
                                      size: size)))),
            ])));
  }

  Widget _halo(double size, Color color, double alpha) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: alpha))));

  Widget _partner(ConversationFlow f) {
    final enabled = !(f.busy || f.client.isBusy);
    return Center(
        child: Column(children: [
      const Text('本机应答伙伴',
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: .6,
              color: Neon.inkFaint)),
      const SizedBox(height: Neon.s3),
      Material(
          color: Colors.white.withValues(alpha: .035),
          borderRadius: BorderRadius.circular(99),
          child: InkWell(
              onTap: enabled ? _pickCompanion : null,
              borderRadius: BorderRadius.circular(99),
              child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: Neon.hair)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                        child: Text(f.companionName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 20,
                                letterSpacing: -.3,
                                color: enabled ? Colors.white : Neon.inkDim,
                                fontWeight: FontWeight.w700))),
                    const SizedBox(width: Neon.s2),
                    const Icon(Icons.expand_more_rounded,
                        color: Neon.inkDim, size: 20),
                  ])))),
    ]));
  }

  Widget _status(ConversationFlow f) {
    final c = f.client;
    final active = c.canLeave && c.conversationStanding.answered;
    final headline = active && c.mode == ConversationMode.ptt
        ? c.pttHeld
            ? '正在收音…'
            : c.agentSpeaking
                ? '伙伴正在说话'
                : '按住按钮说话'
        : active &&
                c.mode == ConversationMode.halfDuplex &&
                c.agentSpeaking &&
                !c.userMuted
            ? '伙伴正在说话'
            : c.uiState.headline;
    final tone = c.activationExhausted
        ? NeonTone.warn
        : active
            ? NeonTone.ok
            : c.canJoin
                ? NeonTone.accent
                : NeonTone.idle;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: Neon.s4 + 2, vertical: Neon.s4 + 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .025),
        borderRadius: BorderRadius.circular(Neon.radiusL),
        border: Border.all(color: Neon.hair),
      ),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: neonToneColor(tone),
                boxShadow: Neon.glow(neonToneColor(tone), blur: 7, alpha: .9)),
          ),
          const SizedBox(width: Neon.s2 + 2),
          Flexible(
            child: Text(
                c.activationExhausted
                    ? '对话尚未就绪'
                    : c.canJoin
                        ? '准备开始对话'
                        : headline,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.1,
                    color: Colors.white)),
          ),
        ]),
        const SizedBox(height: Neon.s3),
        Text(
            c.canJoin
                ? '选好伙伴和对话方式后再接通。准备期间麦克风关闭。'
                : c.canLeave
                    ? (c.conversationStanding == ConversationStanding.farEndGone
                        ? '伙伴已离开，麦克风已关闭。可以重新开始。'
                        : c.conversationStanding == ConversationStanding.asked
                            ? '正在等待伙伴接通，麦克风保持静音。'
                            : c.mode == ConversationMode.halfDuplex &&
                                    c.agentSpeaking
                                ? '伙伴正在说话，结束后将恢复聆听。'
                                : c.mode.description)
                    : c.uiState.supportingText,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Neon.inkDim, height: 1.65, fontSize: 13)),
      ]),
    );
  }

  Widget _approval(ConversationFlow f) => NeonPanel(
      accent: Neon.cyan,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          GlyphBadge(Icons.phonelink_lock_rounded, size: 34),
          SizedBox(width: Neon.s3),
          Expanded(
              child: Text('这是你手上这台手机',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Neon.ink)))
        ]),
        const SizedBox(height: Neon.s3),
        Text(
            f.reviewedProposal == null
                ? (f.error == null ? '正在核对本机提案…' : '本机提案尚未核对成功，请重试。')
                : '设备身份与本机密钥匹配。确认后，本机将作为虚拟设备接入。',
            style: const TextStyle(
                fontSize: 13.5, height: 1.6, color: Neon.inkDim)),
        const SizedBox(height: Neon.s3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Neon.s3),
          decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .28),
              borderRadius: BorderRadius.circular(Neon.radiusS),
              border: Border.all(color: Neon.hair)),
          child: SelectableText('密钥指纹\n${f.client.identity?.fingerprint ?? ""}',
              style: Neon.mono(size: 11, color: Neon.inkFaint)),
        ),
        if (f.selectedCompanionId == null)
          Padding(
            padding: const EdgeInsets.only(top: Neon.s2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: _pickCompanion, child: const Text('选择应答伙伴')),
            ),
          ),
      ]));

  Widget _transcript(ConversationFlow f) {
    final lines = f.client.transcript;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('本次对话',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: .6,
                color: Neon.inkFaint)),
        const SizedBox(width: Neon.s3),
        const Expanded(child: Divider(height: 1)),
      ]),
      const SizedBox(height: Neon.s4),
      if (lines.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: Neon.s4),
            child: Text('对话开始后，文字会显示在这里。',
                style: TextStyle(color: Neon.inkFaint, fontSize: 13))),
      for (final line in lines)
        Padding(
            padding: const EdgeInsets.only(bottom: Neon.s4),
            child: Container(
              padding: const EdgeInsets.only(left: Neon.s3),
              decoration: const BoxDecoration(
                  border: Border(
                      left: BorderSide(color: Neon.hairStrong, width: 2))),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line.speaker,
                        style: Neon.mono(size: 10.5, color: Neon.inkFaint)),
                    const SizedBox(height: Neon.s1),
                    Text(line.text,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: line.isFinal ? Neon.ink : Neon.inkDim)),
                  ]),
            )),
    ]);
  }

  Widget _actions(ConversationFlow f) {
    final c = f.client;
    final busy = f.busy || c.isBusy;
    Widget button(String label, VoidCallback? action, IconData icon) =>
        SizedBox(
            width: double.infinity,
            child: NeonCta(
                enabled: !busy && action != null,
                child: FilledButton.icon(
                    style: EidolonTheme.primaryButton().copyWith(
                        minimumSize:
                            const WidgetStatePropertyAll(Size.fromHeight(56))),
                    onPressed: busy ? null : action,
                    icon: Icon(icon, size: 20),
                    label: Text(label))));
    if (c.canLeave &&
        c.conversationStanding != ConversationStanding.farEndGone) {
      return Row(children: [
        Expanded(
            child: c.mode == ConversationMode.ptt
                ? _pttButton(f)
                // Secondary weight: muting is not the action this bar is for,
                // and a second filled button beside "结束对话" made the two read
                // as equals.
                : OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56)),
                    onPressed: busy || !c.conversationStanding.answered
                        ? null
                        : c.toggleMicrophone,
                    icon: Icon(c.microphoneEnabled
                        ? Icons.mic_rounded
                        : Icons.mic_off_rounded),
                    label: Text(c.userMuted ? '解除静音' : '静音'))),
        const SizedBox(width: Neon.s3),
        Expanded(
            child: NeonCta(
                color: Neon.bad,
                enabled: !busy,
                child: FilledButton.icon(
                    style: EidolonTheme.primaryButton(
                            colors: Neon.dangerGradient,
                            foreground: Colors.white)
                        .copyWith(
                            minimumSize: const WidgetStatePropertyAll(
                                Size.fromHeight(56))),
                    onPressed: busy ? null : c.leave,
                    icon: const Icon(Icons.call_end_rounded),
                    label: const Text('结束对话'))))
      ]);
    }
    if (c.canLeave) {
      return button('重新开始对话', f.startConversation, Icons.refresh_rounded);
    }
    if (c.canJoin) {
      if (f.selectedCompanionId == null) {
        return button('选择应答伙伴', _pickCompanion, Icons.person_add_alt_rounded);
      }
      return button(
          f.selectedMode == null ? '先选择对话方式' : '开始对话',
          f.hasSelection ? f.startConversation : null,
          Icons.graphic_eq_rounded);
    }
    if (c.enrollmentAct == MobileBodyEnrollmentAct.propose) {
      return button(
          c.config?.bodyStanding == MobileBodyStanding.registrationRequired
              ? '在当前主机登记本机'
              : '登记本机',
          f.propose,
          Icons.add_link_rounded);
    }
    if (c.enrollmentAct == MobileBodyEnrollmentAct.approve) {
      return button(
          f.selectedCompanionId == null
              ? '选择应答伙伴'
              : f.reviewedProposal == null
                  ? '重新核对本机'
                  : f.selectedMode == null
                      ? '先选择对话方式'
                      : '确认接入并开始对话',
          f.reviewedProposal != null && f.selectedCompanionId != null
              ? (f.hasSelection ? f.approveAndStart : null)
              : f.selectedCompanionId == null
                  ? _pickCompanion
                  : f.loadReview,
          Icons.verified_user_outlined);
    }
    if (c.enrollmentAct == MobileBodyEnrollmentAct.abandon) {
      return button('撤回未完成的登记', c.abandonEnrollment, Icons.undo_rounded);
    }
    if (c.enrollmentAct == MobileBodyEnrollmentAct.collect) {
      return button('继续接入', c.finishEnrollment, Icons.arrow_forward_rounded);
    }
    final refusal = c.config?.channelRefusal;
    if (refusal == ChannelRefusal.localClaimMissing ||
        refusal == ChannelRefusal.deviceFactsStale) {
      return button('恢复已有登记', _recoverRegistration, Icons.link_rounded);
    }
    if (busy) {
      return SizedBox(
          height: 56,
          child: Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Neon.s3),
            Text('正在准备…', style: Neon.mono(size: 13, color: Neon.inkDim)),
          ])));
    }
    return button('重新检查', f.retry, Icons.refresh_rounded);
  }

  Widget _notice(String text, {bool error = false}) {
    final tone = error ? Neon.bad : Neon.warn;
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Neon.s4),
        decoration: BoxDecoration(
            color: tone.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(Neon.radiusM),
            border: Border.all(color: tone.withValues(alpha: .24))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 17, color: tone),
          const SizedBox(width: Neon.s3),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      height: 1.6, fontSize: 13, color: Neon.ink))),
        ]));
  }
}
