import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../device_setup/mobile_body_enrollment_session.dart';
import 'channel_refusal.dart';
import 'conversation_flow.dart';
import 'conversation_standing.dart';
import 'mobile_device_runtime.dart';

class ProductConversationPage extends StatefulWidget {
  const ProductConversationPage(
      {super.key,
      required this.createFlow,
      required this.hostName,
      this.openDevices,
      this.openHostStatus});
  final Future<ConversationFlow> Function() createFlow;
  final String hostName;
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
  bool _ownerConflict = false;
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
      _ownerConflict = false;
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
          _ownerConflict = e is MobileDeviceOwnerConflict;
          _technicalError = e.toString();
          _error = _ownerConflict
              ? e.toString()
              : e is TimeoutException
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
    if (state == AppLifecycleState.resumed) _flow?.client.onAppResumed();
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
                              ? '后续对话沿用这个选择。切换会结束当前对话，并开始一段新对话。'
                              : '后续对话沿用这个选择。选好后，点击开始对话。',
                          style: TextStyle(color: Colors.white60, height: 1.5)),
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
                            leading: CircleAvatar(
                                child: Text(
                                    _initial(c.displayName ?? c.companionId))),
                            title: Text(c.displayName ?? c.companionId),
                            subtitle: flow.client.canLeave
                                ? const Text('切换并开始新对话')
                                : null,
                            trailing: c.companionId == flow.selectedCompanionId
                                ? const Icon(Icons.check_circle_rounded,
                                    color: Color(0xff8ee4cf))
                                : null,
                            onTap: () => Navigator.pop(context, c.companionId)),
                    ]))));
    if (chosen != null && mounted) {
      await flow.choose(chosen, restart: flow.client.canLeave);
    }
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
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    Text(widget.hostName,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54)),
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
                            Icon(
                                _ownerConflict
                                    ? Icons.devices_other_rounded
                                    : Icons.cloud_off_rounded,
                                size: 40,
                                color: Colors.white54),
                            const SizedBox(height: 16),
                            Text(_ownerConflict ? '另一次登记尚未结束' : '暂时无法连接',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 12),
                            ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 460),
                                child: Text(_error!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white60, height: 1.6))),
                            const SizedBox(height: 20),
                            FilledButton(
                                onPressed: _ownerConflict ? _back : _load,
                                child: Text(_ownerConflict ? '返回选择主机' : '重新连接'))
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
          _partner(flow),
          const SizedBox(height: 22),
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
                style: const TextStyle(color: Colors.white54, fontSize: 12))
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
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                          decoration: const BoxDecoration(
                              border: Border(
                                  top: BorderSide(color: Colors.white10))),
                          child: Center(
                              child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 640),
                                  child: _actions(flow)))),
                    ]))));
      });

  Widget _stage(ConversationFlow f, double size) {
    final track = f.client.remoteVideoTrack;
    return Semantics(
        label: '伙伴形象',
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: size,
            height: size,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(colors: [
                  Color(0xff51476d),
                  Color(0xff252337),
                  Color(0xff12131d)
                ]),
                border: Border.all(
                    color: f.client.canLeave
                        ? const Color(0xff8ee4cf)
                        : Colors.white12),
                boxShadow: [
                  BoxShadow(
                      color: const Color(0xff8675df).withValues(alpha: .10),
                      blurRadius: 45)
                ]),
            child: ClipOval(
                child: track != null
                    ? VideoTrackRenderer(track)
                    : Center(
                        child: Text(f.selectedCompanionId == null ? '✦' : _initial(f.companionName),
                            style: TextStyle(
                                fontSize: size * .3,
                                fontWeight: FontWeight.w300,
                                color: const Color(0xffe5dfff)))))));
  }

  Widget _partner(ConversationFlow f) => Center(
          child: Column(children: [
        const Text('本机应答伙伴',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        TextButton(
            onPressed: f.busy || f.client.isBusy ? null : _pickCompanion,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                  child: Text(f.companionName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 26,
                          color: Colors.white,
                          fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more_rounded, color: Colors.white54),
            ])),
      ]));

  Widget _status(ConversationFlow f) {
    final c = f.client;
    return Column(children: [
      Text(c.activationExhausted ? '对话尚未就绪' : c.uiState.headline,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
      const SizedBox(height: 8),
      Text(
          c.canJoin
              ? '点击下方按钮开始。准备期间麦克风保持关闭。'
              : c.canLeave
                  ? (c.conversationStanding == ConversationStanding.farEndGone
                      ? '伙伴已离开，麦克风已关闭。可以重新开始。'
                      : c.conversationStanding == ConversationStanding.asked
                          ? '正在等待伙伴接通，麦克风已开启。'
                          : '自然地说话，随时可以打断或静音。')
                  : c.uiState.supportingText,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white60, height: 1.6, fontSize: 13)),
    ]);
  }

  Widget _approval(ConversationFlow f) => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: const Color(0xff1d2530),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: const Color(0xff8ee4cf).withValues(alpha: .25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.phonelink_lock_rounded, color: Color(0xff8ee4cf)),
          SizedBox(width: 10),
          Expanded(
              child: Text('这是你手上这台手机',
                  style: TextStyle(fontWeight: FontWeight.w600)))
        ]),
        const SizedBox(height: 12),
        Text(f.reviewedProposal == null
            ? (f.error == null ? '正在核对本机提案…' : '本机提案尚未核对成功，请重试。')
            : '设备身份与本机密钥匹配。确认后，本机将作为虚拟设备接入。'),
        const SizedBox(height: 10),
        SelectableText('密钥指纹\n${f.client.identity?.fingerprint ?? ""}',
            style: const TextStyle(
                color: Colors.white54, fontSize: 11, height: 1.5)),
        if (f.selectedCompanionId == null)
          TextButton(onPressed: _pickCompanion, child: const Text('选择应答伙伴')),
      ]));

  Widget _transcript(ConversationFlow f) {
    final lines = f.client.transcript;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('本次对话', style: TextStyle(fontSize: 12, color: Colors.white38)),
      const SizedBox(height: 12),
      if (lines.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('对话开始后，文字会显示在这里。',
                style: TextStyle(color: Colors.white38, fontSize: 13))),
      for (final line in lines)
        Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.speaker,
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
              const SizedBox(height: 4),
              Text(line.text,
                  style: TextStyle(
                      height: 1.55,
                      color: line.isFinal
                          ? Colors.white.withValues(alpha: .88)
                          : Colors.white54)),
            ])),
    ]);
  }

  Widget _actions(ConversationFlow f) {
    final c = f.client;
    final busy = f.busy || c.isBusy;
    Widget button(String label, VoidCallback? action, IconData icon) =>
        SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: const Color(0xffb5a8f2),
                    foregroundColor: const Color(0xff211d35)),
                onPressed: busy ? null : action,
                icon: Icon(icon, size: 21),
                label: Text(label)));
    if (c.canLeave &&
        c.conversationStanding != ConversationStanding.farEndGone) {
      return Row(children: [
        Expanded(
            child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54)),
                onPressed: busy ? null : c.toggleMicrophone,
                icon: Icon(c.microphoneEnabled
                    ? Icons.mic_rounded
                    : Icons.mic_off_rounded),
                label: Text(c.microphoneEnabled ? '静音' : '解除静音'))),
        const SizedBox(width: 12),
        Expanded(
            child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: const Color(0xffa34754)),
                onPressed: busy ? null : c.leave,
                icon: const Icon(Icons.call_end_rounded),
                label: const Text('结束对话')))
      ]);
    }
    if (c.canLeave) {
      return button('重新开始对话', f.startConversation, Icons.refresh_rounded);
    }
    if (c.canJoin) {
      if (f.device != null && f.device!.attachedCompanionId == null) {
        return button('选择应答伙伴', _pickCompanion, Icons.person_add_alt_rounded);
      }
      return button('开始对话', f.startConversation, Icons.graphic_eq_rounded);
    }
    if (c.enrollmentAct == MobileBodyEnrollmentAct.propose) {
      return button('登记本机', f.propose, Icons.add_link_rounded);
    }
    if (c.enrollmentAct == MobileBodyEnrollmentAct.approve) {
      return button(
          f.selectedCompanionId == null
              ? '选择应答伙伴'
              : f.reviewedProposal == null
                  ? '重新核对本机'
                  : '确认接入并开始对话',
          f.reviewedProposal != null && f.selectedCompanionId != null
              ? f.approveAndStart
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
        refusal == ChannelRefusal.deviceFactsStale ||
        refusal == ChannelRefusal.ownerMismatch) {
      return button('恢复已有登记', _recoverRegistration, Icons.link_rounded);
    }
    if (busy) {
      return const SizedBox(
          height: 54,
          child: Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('正在准备…')
          ])));
    }
    return button('重新检查', f.retry, Icons.refresh_rounded);
  }

  Widget _notice(String text, {bool error = false}) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: error ? const Color(0xff38232c) : const Color(0xff202331),
          borderRadius: BorderRadius.circular(14)),
      child: Text(text, style: const TextStyle(height: 1.5, fontSize: 13)));

  static String _initial(String name) => name.characters.firstOrNull ?? '✦';
}
