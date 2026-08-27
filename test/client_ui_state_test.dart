import 'package:eidolon_client_mobile/src/models/client_ui_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ClientUiState conversationState({
    ChannelConnectionState voice = ChannelConnectionState.connected,
    AgentTurnState agent = AgentTurnState.idle,
    MicrophoneState microphone = MicrophoneState.enabled,
  }) {
    return ClientUiState(
      phase: ClientPhase.conversation,
      controlConnection: ChannelConnectionState.connected,
      voiceConnection: voice,
      agentTurn: agent,
      microphone: microphone,
      video: VideoState.audioOnly,
      busy: false,
    );
  }

  test('voice reconnect takes priority over agent and microphone feedback', () {
    final state = conversationState(
      voice: ChannelConnectionState.reconnecting,
      agent: AgentTurnState.speaking,
      microphone: MicrophoneState.muted,
    );

    expect(state.headline, '正在恢复语音连接…');
    expect(state.supportingText, contains('自动继续'));
    expect(state.connectionLabel, '语音重连中');
  });

  test('full duplex speaking state tells the user they can interrupt', () {
    final state = conversationState(agent: AgentTurnState.speaking);

    expect(state.headline, '正在回复');
    expect(state.supportingText, contains('直接说话打断'));
    expect(state.microphoneEnabled, isTrue);
  });

  test('muted microphone has explicit conversation feedback', () {
    final state = conversationState(microphone: MicrophoneState.muted);

    expect(state.headline, '麦克风已静音');
    expect(state.supportingText, contains('解除静音'));
    expect(state.microphoneEnabled, isFalse);
  });

  test('approval and binding phases expose distinct progress labels', () {
    const approval = ClientUiState(
      phase: ClientPhase.awaitingApproval,
      controlConnection: ChannelConnectionState.disconnected,
      voiceConnection: ChannelConnectionState.disconnected,
      agentTurn: AgentTurnState.idle,
      microphone: MicrophoneState.inactive,
      video: VideoState.audioOnly,
      busy: false,
    );
    const binding = ClientUiState(
      phase: ClientPhase.awaitingBinding,
      controlConnection: ChannelConnectionState.disconnected,
      voiceConnection: ChannelConnectionState.disconnected,
      agentTurn: AgentTurnState.idle,
      microphone: MicrophoneState.inactive,
      video: VideoState.audioOnly,
      busy: false,
    );

    expect(approval.connectionLabel, '待批准');
    expect(binding.connectionLabel, '待绑定');
    // These two sentences used to be asserted here verbatim: 「认领请求会自动向
    // 前推进，无需手动填写设备 ID」 and 「正在关联 Companion」. Neither was true of
    // any phone. Nothing was claiming Mobile, nothing advanced on its own, and
    // the second stood in for three different Admission stages including the
    // one where this version stops. The words a phone sees now come from its
    // standing — see mobile_body_standing_test.dart — and these two are only
    // the fallback for the legacy register path, which has no standing.
    expect(approval.supportingText, isNot(contains('自动向前推进')));
    expect(binding.headline, isNot(contains('正在关联 Companion')));
    expect(approval.supportingText, isNotEmpty);
    expect(binding.headline, isNotEmpty);
  });
}
