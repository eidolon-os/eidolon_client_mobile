import 'package:eidolon_client_mobile/src/models/client_ui_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_standing.dart';

void main() {
  /// A conversation the far end has confirmed.
  ///
  /// `confirmed` defaults to true because these tests are about what a live
  /// conversation says, and the unconfirmed case has its own tests below. It
  /// is a parameter rather than an assumption for the same reason it exists at
  /// all: asked and answered are two different states, and a helper that could
  /// only build one of them was how every assertion here silently described
  /// the confirmed case while the product showed the same copy for both.
  ClientUiState conversationState({
    ChannelConnectionState voice = ChannelConnectionState.connected,
    AgentTurnState agent = AgentTurnState.idle,
    MicrophoneState microphone = MicrophoneState.enabled,
    ConversationStanding standing = ConversationStanding.hearing,
  }) {
    return ClientUiState(
      phase: ClientPhase.conversation,
      controlConnection: ChannelConnectionState.connected,
      voiceConnection: voice,
      agentTurn: agent,
      microphone: microphone,
      video: VideoState.audioOnly,
      busy: false,
      conversationStanding: standing,
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

  group('a conversation that has been asked for but not confirmed', () {
    // Found on hardware, twice over. The screen read 「正在聆听」 from the moment
    // this client published `session_open`: once while the Channel Provider
    // was silently discarding the request for want of a `conversation_id`, and
    // again while an agent joined the room and died a millisecond later. Both
    // times the Owner spoke several sentences into a room with nothing in it,
    // and every surface said the conversation was live.
    //
    // The microphone genuinely was open, so the old copy was not a lie about
    // the phone. It was a claim about the far end that the phone had no
    // grounds for.
    test('does not claim to be listening', () {
      final state = conversationState(
        agent: AgentTurnState.listening,
        standing: ConversationStanding.asked,
      );

      expect(state.headline, '正在接通对话…');
      expect(state.headline, isNot('正在聆听'));
      expect(state.connectionLabel, '接通中');
    });

    test('does not instruct the person to speak', () {
      // 「请直接说话」 is an instruction. Given before anything has confirmed it
      // is listening, it is what sends someone talking into an empty room.
      final state = conversationState(
        agent: AgentTurnState.listening,
        standing: ConversationStanding.asked,
      );

      expect(state.supportingText, isNot(contains('请直接说话')));
      expect(state.supportingText, contains('正在等主机接入'));
    });

    test('a mute is not the interesting fact yet', () {
      // Muted *and* unconfirmed: whether the microphone is on does not matter
      // while nobody has said there is anything on the other end, so the
      // unconfirmed sentence wins.
      final state = conversationState(
        microphone: MicrophoneState.muted,
        standing: ConversationStanding.asked,
      );

      expect(state.headline, '正在接通对话…');
    });

    test('a reconnect still outranks it', () {
      // Losing the channel is a bigger fact than not having been answered,
      // and the existing precedence is deliberate.
      final state = conversationState(
        voice: ChannelConnectionState.reconnecting,
        standing: ConversationStanding.asked,
      );

      expect(state.headline, '正在恢复语音连接…');
      expect(state.connectionLabel, '语音重连中');
    });

    test('confirmation is what turns it into a conversation', () {
      expect(
        conversationState(agent: AgentTurnState.listening).headline,
        '正在聆听',
      );
      expect(
        conversationState(agent: AgentTurnState.listening).connectionLabel,
        '对话中',
      );
    });
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
