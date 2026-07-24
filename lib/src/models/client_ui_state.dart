enum ClientPhase {
  idle,
  discovering,
  registering,
  awaitingApproval,
  awaitingBinding,
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
    required this.microphone,
    required this.video,
    required this.busy,
    this.attention = DeviceAttentionEffect.none,
    this.attentionSequence = 0,
    this.failure,
    this.notice,
  });

  final ClientPhase phase;
  final ChannelConnectionState controlConnection;
  final ChannelConnectionState voiceConnection;
  final AgentTurnState agentTurn;
  final MicrophoneState microphone;
  final VideoState video;
  final bool busy;
  final DeviceAttentionEffect attention;
  final int attentionSequence;
  final ClientFailure? failure;
  final String? notice;

  bool get hubOnline =>
      controlConnection == ChannelConnectionState.connected ||
      controlConnection == ChannelConnectionState.reconnecting;

  bool get inConversation =>
      phase == ClientPhase.joining || phase == ClientPhase.conversation;

  bool get microphoneEnabled => microphone == MicrophoneState.enabled;

  bool get agentSpeaking => agentTurn == AgentTurnState.speaking;

  String get headline {
    if (phase == ClientPhase.error && failure != null) return failure!.title;
    return switch (phase) {
      ClientPhase.idle => '连接你的 Eidolon Hub',
      ClientPhase.discovering => '正在寻找局域网中的 Hub…',
      ClientPhase.registering => '正在验证设备身份…',
      ClientPhase.awaitingApproval => '等待管理员批准',
      ClientPhase.awaitingBinding => '等待绑定 Companion',
      ClientPhase.activating => '正在建立控制连接…',
      ClientPhase.ready =>
        controlConnection == ChannelConnectionState.reconnecting
            ? '正在恢复控制连接…'
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
    if (microphone == MicrophoneState.muted) return '麦克风已静音';
    return switch (agentTurn) {
      AgentTurnState.listening => '正在聆听',
      AgentTurnState.thinking => '正在思考',
      AgentTurnState.speaking => '正在回复',
      AgentTurnState.idle => '全双工对话中',
    };
  }

  String get supportingText => switch (phase) {
        ClientPhase.idle => '自动发现、注册并连接同一局域网中的服务',
        ClientPhase.discovering => '正在通过 mDNS 扫描，通常几秒内完成',
        ClientPhase.registering => '使用设备密钥安全注册，并声明全双工能力',
        ClientPhase.awaitingApproval => '请在管理端批准此移动设备，页面会自动检查',
        ClientPhase.awaitingBinding => '设备已批准，请在管理端选择要绑定的 Companion',
        ClientPhase.activating => '授权已完成，正在连接 LiveKit 控制通道',
        ClientPhase.ready => '控制通道保持在线，点击下方按钮开始语音会话',
        ClientPhase.joining => '正在刷新会话凭据并启用 WebRTC AEC',
        ClientPhase.conversation => _conversationSupportingText,
        ClientPhase.error => failure?.message ?? '请检查网络后重试',
      };

  String get _conversationSupportingText {
    if (voiceConnection == ChannelConnectionState.reconnecting) {
      return '画面会保留，连接恢复后将自动继续';
    }
    if (microphone == MicrophoneState.muted) return '解除静音后才能继续说话';
    return switch (agentTurn) {
      AgentTurnState.listening => '请直接说话，AEC 会抑制扬声器回声',
      AgentTurnState.thinking => 'Eidolon 正在组织回答',
      AgentTurnState.speaking => '麦克风仍保持开启，你可以直接说话打断',
      AgentTurnState.idle => '麦克风与扬声器同时工作，可以自然连续对话',
    };
  }

  String get connectionLabel => switch (phase) {
        ClientPhase.idle => '未连接',
        ClientPhase.discovering || ClientPhase.registering => '连接中',
        ClientPhase.awaitingApproval => '待批准',
        ClientPhase.awaitingBinding => '待绑定',
        ClientPhase.activating || ClientPhase.joining => '正在连接',
        ClientPhase.ready =>
          controlConnection == ChannelConnectionState.reconnecting
              ? '控制重连中'
              : 'Hub 在线',
        ClientPhase.conversation =>
          voiceConnection == ChannelConnectionState.reconnecting
              ? '语音重连中'
              : '对话中',
        ClientPhase.error => '连接异常',
      };
}
