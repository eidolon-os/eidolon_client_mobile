import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:eidolon_client_mobile/src/models/client_ui_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/channel_refusal.dart';

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

  test('a standing that does not advance offers an act, or names a gap', () {
    // This test used to assert that all three of these said 「还不会」, because
    // this app could not propose an Enrollment for itself. It can now, so what
    // is asserted is the invariant that outlived the gap: a standing that will
    // not move on its own must give the reader something to do or something to
    // know — never a reason to wait.
    for (final standing in MobileBodyStanding.values) {
      if (standing.advances) continue;
      final detail = mobileBodySentence(standing).detail;
      if (standing.canProposeItself) {
        expect(
          detail,
          contains('登记'),
          reason: '$standing can act, so its sentence must name the act',
        );
        // And must not promise the act is enough. On this path the same
        // person still has to approve what they just proposed — the weakening
        // W1 accepts on condition that it stays visible.
        expect(
          detail,
          contains('批准'),
          reason: '$standing must say an approval still follows',
        );
      } else {
        expect(
          detail,
          contains('当前版本'),
          reason: '$standing cannot act, so its sentence must name the gap',
        );
      }
    }
  });

  test('the phone is not offered enrollment where it already holds a Claim',
      () {
    // `claimActiveWithoutChannel` also does not advance, and offering to
    // propose there would be a button that undoes something: that phone is a
    // Body already, and what it lacks is a Channel, which is the Host's to
    // give.
    expect(
      MobileBodyStanding.claimActiveWithoutChannel.canProposeItself,
      isFalse,
    );
    expect(
      mobileBodySentence(MobileBodyStanding.claimActiveWithoutChannel).detail,
      isNot(contains('重新登记')),
    );
  });

  group('a channel refusal is said as the refusal it is', () {
    MobileBodySentence sentenceFor(ChannelRefusal? refusal) => mobileBodySentence(
          MobileBodyStanding.claimActiveWithoutChannel,
          refusal: refusal,
        );

    test('no sentence tells a person the answers are indistinguishable', () {
      // The line this group exists to delete: 「这两种情况主机的回答是一样的，
      // 这台手机分不出来」. The Host tags its refusal, and this phone was
      // discarding the tag before saying it could not tell.
      for (final refusal in <ChannelRefusal?>[null, ...ChannelRefusal.values]) {
        expect(
          sentenceFor(refusal).detail,
          isNot(contains('分不出来')),
          reason: '$refusal still claims the phone cannot tell',
        );
      }
    });

    test('an unanswered request does not claim the Host was asked', () {
      // Nothing was decided, so 「已经问过主机了」 was false — and it is the
      // half that made a network fault look like a Host decision.
      final detail = sentenceFor(ChannelRefusal.hostUnanswered).detail;

      expect(detail, isNot(contains('已经问过主机')));
      expect(detail, contains('没有完成'));
    });

    test('each refusal reads as a different answer', () {
      final labels = <String>{
        for (final refusal in <ChannelRefusal?>[null, ...ChannelRefusal.values])
          sentenceFor(refusal).connectionLabel,
      };

      expect(
        labels.length,
        4,
        reason: 'four facts arrived here wearing one label',
      );
    });

    test('only the unrefused case advises waiting', () {
      expect(sentenceFor(null).detail, contains('再问一次可能就有了'));
      for (final refusal in ChannelRefusal.values) {
        expect(
          sentenceFor(refusal).detail,
          isNot(contains('可能就有了')),
          reason: '$refusal is a decision, not a wait',
        );
      }
    });

    test('no refusal promises an act this standing does not offer', () {
      // `claimActiveWithoutChannel.canProposeItself` is false, so no propose
      // control is drawn here. A sentence saying this phone will register
      // itself would be a promise with nothing behind it — which is what the
      // first draft of the stale-record copy did.
      expect(MobileBodyStanding.claimActiveWithoutChannel.canProposeItself,
          isFalse);
      for (final refusal in ChannelRefusal.values) {
        expect(
          sentenceFor(refusal).detail,
          isNot(contains('这台手机自己就能提出')),
          reason: '$refusal promises a control that is not drawn',
        );
      }
    });
  });

  test('acting and advancing are never the same standing', () {
    // Two different facts about the same screen: whether a person may do
    // something, and whether waiting ends by itself. Collapsing them is what
    // put 「立即检查状态」 in front of an event that was never coming.
    for (final standing in MobileBodyStanding.values) {
      expect(
        standing.advances && standing.canProposeItself,
        isFalse,
        reason: '$standing claims both a wait and an act',
      );
    }
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
