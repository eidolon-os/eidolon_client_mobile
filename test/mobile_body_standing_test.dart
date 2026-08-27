import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/models/client_ui_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen has to say which of these it is, and who has to act.
///
/// It used to say three of them with one sentence — 「正在关联 Companion」 — and
/// the fourth, the one this phone was actually in, with 「主机正在认领 Mobile /
/// 认领请求会自动向前推进，无需手动填写设备 ID」. Nothing was claiming it, nothing
/// was advancing, and the only control on the screen was 「立即检查状态」.
void main() {
  test('every standing says something different', () {
    final headlines = <String>{};
    final details = <String>{};
    final labels = <String>{};

    for (final standing in MobileBodyStanding.values) {
      final sentence = mobileBodySentence(standing);
      headlines.add(sentence.headline);
      details.add(sentence.detail);
      labels.add(sentence.connectionLabel);
    }

    expect(headlines, hasLength(MobileBodyStanding.values.length));
    expect(details, hasLength(MobileBodyStanding.values.length));
    expect(labels, hasLength(MobileBodyStanding.values.length));
  });

  test('a standing that cannot advance never says it is in progress', () {
    // The precise failure this guards. 「正在…」 in front of something that will
    // not happen is what turned an unimplemented feature into a progress
    // indicator, and a person into someone pressing refresh.
    for (final standing in MobileBodyStanding.values) {
      if (standing.advances) continue;
      final sentence = mobileBodySentence(standing);
      expect(
        sentence.headline.startsWith('正在'),
        isFalse,
        reason: '$standing cannot advance, so its headline must not be 「正在…」',
      );
      expect(
        sentence.connectionLabel.contains('中'),
        isFalse,
        reason: '$standing cannot advance, so its badge must not read as busy',
      );
    }
  });

  test('a dead end names what is missing rather than inviting a retry', () {
    for (final standing in const [
      MobileBodyStanding.notEnrolled,
      MobileBodyStanding.claimRevoked,
      MobileBodyStanding.admissionEnded,
    ]) {
      expect(mobileBodySentence(standing).detail, contains('还不会'));
    }
    expect(
      mobileBodySentence(MobileBodyStanding.claimActiveWithoutChannel).detail,
      contains('当前版本'),
    );
  });

  test('exactly one standing is the Owner\'s to act on from this phone', () {
    final actionable = MobileBodyStanding.values
        .where((standing) => standing.awaitsThisControllersApproval)
        .toList();

    expect(actionable, [MobileBodyStanding.pendingReview]);
    // And it has to say so. The phone holding this screen is the Controller
        // entitled to give the approval it was silently polling for.
    expect(
      mobileBodySentence(MobileBodyStanding.pendingReview).detail,
      contains('你自己就能给'),
    );
  });

  test('the fingerprint reaches the person who has to compare it', () {
    // Approval on a software Body is the same person on the same device, so
    // the one thing that distinguishes this phone's proposal from a stranger's
    // is the key fingerprint. See 「知情接受的弱化 W1」 in
    // docs/跨系统/纯软件Body准入身份裁决.md.
    final sentence = mobileBodySentence(
      MobileBodyStanding.pendingReview,
      fingerprint: 'p256:5cd252fb',
    );

    expect(sentence.detail, contains('p256:5cd252fb'));
  });

  group('the screen', () {
    ClientUiState state(ClientPhase phase, MobileBodyStanding? standing) =>
        ClientUiState(
          phase: phase,
          controlConnection: ChannelConnectionState.disconnected,
          voiceConnection: ChannelConnectionState.disconnected,
          agentTurn: AgentTurnState.idle,
          microphone: MicrophoneState.inactive,
          video: VideoState.audioOnly,
          busy: false,
          bodyStanding: standing,
        );

    test('renders the standing, not the phase', () {
      final unenrolled =
          state(ClientPhase.bodyBlocked, MobileBodyStanding.notEnrolled);
      final noChannel = state(
        ClientPhase.bodyBlocked,
        MobileBodyStanding.claimActiveWithoutChannel,
      );

      expect(unenrolled.headline, isNot(noChannel.headline));
      expect(unenrolled.supportingText, isNot(noChannel.supportingText));
      expect(unenrolled.connectionLabel, isNot(noChannel.connectionLabel));
    });

    test('the two waiting phases still differ by standing', () {
      final approved = state(
        ClientPhase.awaitingBinding,
        MobileBodyStanding.approvedAwaitingHandoff,
      );
      final delivered = state(
        ClientPhase.awaitingBinding,
        MobileBodyStanding.grantDelivered,
      );

      expect(approved.headline, isNot(delivered.headline));
    });

    test('a phase with no standing keeps its own words', () {
      // The legacy Hub register path never knew a standing, and must not start
      // borrowing sentences written about Admission projections.
      final legacy = state(ClientPhase.awaitingApproval, null);

      expect(legacy.headline, isNotEmpty);
      expect(legacy.supportingText, isNotEmpty);
      expect(legacy.connectionLabel, '待批准');
    });

    test('no phase is left without words', () {
      for (final phase in ClientPhase.values) {
        final blank = state(phase, null);
        expect(blank.headline, isNotEmpty, reason: '$phase has no headline');
        expect(
          blank.supportingText,
          isNotEmpty,
          reason: '$phase has no supporting text',
        );
        expect(
          blank.connectionLabel,
          isNotEmpty,
          reason: '$phase has no badge',
        );
      }
    });
  });
}
