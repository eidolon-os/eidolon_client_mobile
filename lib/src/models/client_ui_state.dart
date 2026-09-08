import '../features/conversation/mobile_body_standing.dart';
import '../features/device_setup/mobile_body_enrollment_session.dart';
import '../features/conversation/conversation_standing.dart';
import '../features/conversation/channel_refusal.dart';

enum ClientPhase {
  idle,
  discovering,
  registering,
  awaitingApproval,
  awaitingBinding,

  /// This phone cannot become a Body from here, and no retry changes that.
  ///
  /// Distinct from [error] because nothing failed, and distinct from the two
  /// awaiting phases because there is nothing to await. It exists so a stopped
  /// state can be drawn as stopped: the phone spent today showing 「待批准」 and
  /// a 「立即检查状态」 button while polling for an Enrollment that no party in
  /// the system was creating.
  bodyBlocked,
  activating,
  ready,
  joining,
  conversation,
  error,
}

enum ChannelConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

enum AgentTurnState { idle, listening, thinking, speaking }

enum MicrophoneState {
  inactive,
  requestingPermission,
  enabled,
  muted,
  switching,
  failed,
}

enum VideoState { audioOnly, playing, interrupted }

enum DeviceAttentionEffect { none, identify, wiggle }

enum ClientErrorKind {
  discovery,
  network,
  authorization,
  permission,
  liveKit,
  protocol,
  unknown,
}

class ClientFailure {
  const ClientFailure({
    required this.kind,
    required this.title,
    required this.message,
    required this.technicalDetails,
    this.retryable = true,
  });

  final ClientErrorKind kind;
  final String title;
  final String message;
  final String technicalDetails;
  final bool retryable;
}

class ClientUiState {
  const ClientUiState({
    required this.phase,
    required this.controlConnection,
    required this.voiceConnection,
    required this.agentTurn,
    this.conversationStanding = ConversationStanding.asked,
    this.channelRefusal,
    required this.microphone,
    required this.video,
    required this.busy,
    this.attention = DeviceAttentionEffect.none,
    this.attentionSequence = 0,
    this.failure,
    this.notice,
    this.bodyStanding,
    this.enrollmentAct = MobileBodyEnrollmentAct.none,
    this.enrollmentExpiresAt,
    this.deviceFingerprint = '',
  });

  final ClientPhase phase;
  final ChannelConnectionState controlConnection;
  final ChannelConnectionState voiceConnection;
  final AgentTurnState agentTurn;

  /// Whether the far end has confirmed the conversation started.
  ///
  /// The screen used to read 「正在聆听」 from the moment this client *asked*
  /// for a conversation. That was true about the microphone and silent about
  /// whether anything was listening — and it stayed true-looking through an
  /// agent that joined the room and died a millisecond later, which is exactly
  /// what an Owner met on hardware: 「正在聆听」, several sentences spoken, and
  /// nothing in the room to hear them.
  /// What this client knows about the far end, and on what evidence.
  final ConversationStanding conversationStanding;

  /// Why there is no channel, when the Host refused to give one.
  final ChannelRefusal? channelRefusal;
  final MicrophoneState microphone;
  final VideoState video;
  final bool busy;
  final DeviceAttentionEffect attention;
  final int attentionSequence;
  final ClientFailure? failure;
  final String? notice;

  /// Where this phone stands as a Body, when Admission is what answered.
  final MobileBodyStanding? bodyStanding;

  /// What this phone can do about its Enrollment, already resolved.
  final MobileBodyEnrollmentAct enrollmentAct;

  /// When an Enrollment that can only expire does.
  final DateTime? enrollmentExpiresAt;

  final String deviceFingerprint;

  /// The one sentence that owns the admission copy, when there is a standing.
  ///
  /// Every admission phase defers to it rather than carrying its own line: the
  /// phases are three and the standings are seven, and the three-way fold is
  /// exactly what said 「正在关联 Companion」 to a phone that was in fact
  /// finished, and 「主机正在认领 Mobile」 to one that had never asked.
  MobileBodySentence? get bodySentence {
    final standing = bodyStanding;
    if (standing == null) return null;
    // Two of the acts mean the Authority's own sentence is no longer true: it
    // still describes a proposal in motion, and this phone can no longer move
    // it. The Authority cannot know that — what is missing never left this
    // process — so the correction happens here rather than in the projection.
    switch (enrollmentAct) {
      case MobileBodyEnrollmentAct.abandon:
        return unfinishableEnrollmentSentence(
          withdrawable: true,
          fingerprint: deviceFingerprint,
        );
      case MobileBodyEnrollmentAct.waitForExpiry:
        return unfinishableEnrollmentSentence(
          withdrawable: false,
          expiresAt: enrollmentExpiresAt,
          fingerprint: deviceFingerprint,
        );
      case MobileBodyEnrollmentAct.propose:
      case MobileBodyEnrollmentAct.approve:
      case MobileBodyEnrollmentAct.collect:
      case MobileBodyEnrollmentAct.none:
        return mobileBodySentence(
          standing,
          fingerprint: deviceFingerprint,
          refusal: channelRefusal,
        );
    }
  }

  bool get hubOnline =>
      controlConnection == ChannelConnectionState.connected ||
      controlConnection == ChannelConnectionState.reconnecting;

  bool get inConversation =>
      phase == ClientPhase.joining || phase == ClientPhase.conversation;

  bool get microphoneEnabled => microphone == MicrophoneState.enabled;

  bool get agentSpeaking => agentTurn == AgentTurnState.speaking;

  String get headline {
    if (phase == ClientPhase.error && failure != null) return failure!.title;
    if (_admissionPhase) {
      final sentence = bodySentence;
      if (sentence != null) return sentence.headline;
    }
    return switch (phase) {
      ClientPhase.idle => '连接我的 Eidolon',
      ClientPhase.discovering => '正在验证主机与 Hub…',
      ClientPhase.registering => '正在安全接入 Mobile…',
      ClientPhase.awaitingApproval => '等你批准这台手机',
      ClientPhase.awaitingBinding => '正在完成这台手机的归属',
      ClientPhase.bodyBlocked => '这台手机还不能对话',
      ClientPhase.activating => '正在接入通道…',
      ClientPhase.ready =>
        controlConnection == ChannelConnectionState.reconnecting
            ? '正在恢复通道…'
            : '设备在线，可以开始对话',
      ClientPhase.joining => microphone == MicrophoneState.requestingPermission
          ? '等待麦克风授权…'
          : '正在建立全双工语音连接…',
      ClientPhase.conversation => _conversationHeadline,
      ClientPhase.error => '连接失败',
    };
  }

  String get _conversationHeadline {
    if (voiceConnection == ChannelConnectionState.reconnecting) {
      return '正在恢复语音连接…';
    }
    // Said before the mute check on purpose, both of them: whether this
    // phone's microphone is muted is not the interesting fact while nobody is
    // on the other end, or while nobody has answered yet.
    if (conversationStanding == ConversationStanding.farEndGone) {
      return '对话已中断';
    }
    if (!conversationStanding.answered) return '正在接通对话…';
    if (microphone == MicrophoneState.muted) return '麦克风已静音';
    return switch (agentTurn) {
      // 「正在聆听」 is a claim about the far end's pipeline, so it waits for
      // the far end to prove it — a final transcript of this phone's own
      // speech. Until then the person is still invited to speak, because that
      // first utterance is what produces the proof.
      AgentTurnState.listening when !conversationStanding.hearsUs =>
        '已接通，可以开始说话',
      AgentTurnState.listening => '正在聆听',
      AgentTurnState.thinking => '正在思考',
      AgentTurnState.speaking => '正在回复',
      AgentTurnState.idle => '全双工对话中',
    };
  }

  /// The phases whose copy is a statement about this phone's admission.
  bool get _admissionPhase =>
      phase == ClientPhase.awaitingApproval ||
      phase == ClientPhase.awaitingBinding ||
      phase == ClientPhase.bodyBlocked;

  String get supportingText {
    if (_admissionPhase) {
      final sentence = bodySentence;
      if (sentence != null) return sentence.detail;
    }
    return _phaseSupportingText;
  }

  String get _phaseSupportingText => switch (phase) {
        ClientPhase.idle => '通过已认证主机接入 Hub 与当前 Companion',
        ClientPhase.discovering => '验证 Host 会话提供的 Hub 身份和 TLS 绑定',
        ClientPhase.registering =>
          '使用 Android Keystore 身份完成 Enrollment 与 Owner 认领',
        ClientPhase.awaitingApproval => '登记已经提出，主机在等一个批准',
        ClientPhase.awaitingBinding => '归属还没有落定，这一步在这台手机上跑',
        ClientPhase.bodyBlocked => '这台手机在这个 Owner 域里还没有可以对话的身份',
        ClientPhase.activating => '授权已完成，正在接入这台主机的通道',
        ClientPhase.ready => '通道保持在线，点击下方按钮开始对话',
        ClientPhase.joining => '正在刷新会话凭据并启用 WebRTC AEC',
        ClientPhase.conversation => _conversationSupportingText,
        ClientPhase.error => failure?.message ?? '请检查网络后重试',
      };

  String get _conversationSupportingText {
    if (voiceConnection == ChannelConnectionState.reconnecting) {
      return '画面会保留，连接恢复后将自动继续';
    }
    // 「请直接说话」 is an instruction, and giving it before anything has
    // confirmed it is listening is how a person talks into a room with nobody
    // in it. This says what is actually happening instead.
    if (conversationStanding == ConversationStanding.farEndGone) {
      return '对面已经不在这次对话里了，麦克风已关闭。结束后可以重新开始';
    }
    if (!conversationStanding.answered) {
      return '已经请求对话，正在等主机接入 Companion';
    }
    if (microphone == MicrophoneState.muted) return '解除静音后才能继续说话';
    return switch (agentTurn) {
      AgentTurnState.listening when !conversationStanding.hearsUs =>
        '直接说话就可以',
      AgentTurnState.listening => '请直接说话，AEC 会抑制扬声器回声',
      // Not a name, for the same reason the transcript no longer uses one:
      // nothing tells a Body which Companion is answering it.
      AgentTurnState.thinking => 'Companion 正在组织回答',
      AgentTurnState.speaking => '麦克风仍保持开启，你可以直接说话打断',
      AgentTurnState.idle => '麦克风与扬声器同时工作，可以自然连续对话',
    };
  }

  String get connectionLabel {
    if (_admissionPhase) {
      final sentence = bodySentence;
      if (sentence != null) return sentence.connectionLabel;
    }
    return _phaseConnectionLabel;
  }

  String get _phaseConnectionLabel => switch (phase) {
        ClientPhase.idle => '未连接',
        ClientPhase.discovering || ClientPhase.registering => '连接中',
        ClientPhase.awaitingApproval => '待批准',
        ClientPhase.awaitingBinding => '待绑定',
        ClientPhase.bodyBlocked => '不能对话',
        ClientPhase.activating || ClientPhase.joining => '正在连接',
        ClientPhase.ready =>
          controlConnection == ChannelConnectionState.reconnecting
              ? '控制重连中'
              : 'Hub 在线',
        ClientPhase.conversation => switch (voiceConnection) {
            ChannelConnectionState.reconnecting => '语音重连中',
            _ => switch (conversationStanding) {
                ConversationStanding.farEndGone => '对面已离开',
                ConversationStanding.asked => '接通中',
                ConversationStanding.accepted ||
                ConversationStanding.hearing =>
                  '对话中',
              },
          },
        ClientPhase.error => '连接异常',
      };
}
