import 'channel_refusal.dart';
/// Where this phone actually stands as a Body in the Owner Domain.
///
/// One value per stage the Admission projection distinguishes, plus the stage
/// the projection cannot describe because there is nothing to project: no
/// Enrollment for this phone at all.
///
/// This enum exists because three of those stages used to be folded into one
/// screen that said 「正在关联 Companion」 and retried every five seconds. What
/// the fold removed was the only thing a person needed: **who has to act**. And
/// the stage it hid most expensively was the first one — a phone with no
/// Enrollment was shown 「主机正在认领 Mobile / 认领请求会自动向前推进」, which
/// described a claim that no party in the system was making, could make, or
/// would ever make. Only a device may propose itself.
///
/// Since 2026-09-06 this phone can. `features/device_setup/mobile_body_enrollment.dart`
/// runs the same chain a board runs, so the three stages that used to end in
/// 「这个版本还不会做这一步」 now end in something the person holding the phone
/// can do. [canProposeItself] is that bit, and it is deliberately separate from
/// [advances]: an action a person may take is not the same fact as a wait that
/// ends by itself, and the screen that conflated them is the one this enum
/// replaced.
enum MobileBodyStanding {
  /// No Enrollment for this phone exists. Nothing is in progress.
  notEnrolled,

  /// Proposed, waiting on a Decision — which this phone can give itself.
  pendingReview,

  /// Approved; this phone is collecting its ClaimGrant.
  approvedAwaitingHandoff,

  /// Grant collected; this phone is acknowledging it to the Host.
  grantDelivered,

  /// Claimed by this Owner, with no Channel to talk through.
  claimActiveWithoutChannel,

  /// This phone's Claim was revoked.
  claimRevoked,

  /// The Enrollment ended without a Claim: rejected, expired or canceled.
  admissionEnded;

  /// Whether waiting can end on its own.
  ///
  /// The one bit the old screen got wrong. `false` here means no amount of
  /// polling, retrying or waiting changes anything, so the screen must not
  /// offer any of the three — and must say what is missing instead.
  /// [claimActiveWithoutChannel] moved into this set on 2026-09-06. It used to
  /// be a version limit — the app could not ask for a channel — and a screen
  /// that offered to re-check would have been a retry in front of nothing. Now
  /// the app asks, the Host provisions the channel after the Claim, and asking
  /// again is how it arrives. What waiting cannot fix is a provisioning that
  /// was refused, and this edge cannot tell that apart; the sentence says so
  /// rather than the flag pretending to know.
  bool get advances => switch (this) {
        pendingReview ||
        approvedAwaitingHandoff ||
        grantDelivered ||
        claimActiveWithoutChannel =>
          true,
        notEnrolled || claimRevoked || admissionEnded => false,
      };

  /// Whether the Owner holding this phone can approve it from here.
  ///
  /// True for exactly one stage, and it is the one the phone used to poll in
  /// silence: it was waiting for an approval it is itself authorised to give.
  bool get awaitsThisControllersApproval => this == pendingReview;

  /// Whether this phone can propose itself from here, now.
  ///
  /// The three stages where nothing is in flight and nothing will start on its
  /// own. Each of them used to end with a sentence naming a missing capability;
  /// the capability exists, so each now ends with an action.
  ///
  /// Not the negation of [advances]: [claimActiveWithoutChannel] also does not
  /// advance, and proposing again there would be wrong — that phone already
  /// holds a Claim, and what it lacks is a Channel, which is the Host's to
  /// give. Offering enrollment there would be a button that undoes something.
  bool get canProposeItself => switch (this) {
        notEnrolled || claimRevoked || admissionEnded => true,
        pendingReview ||
        approvedAwaitingHandoff ||
        grantDelivered ||
        claimActiveWithoutChannel =>
          false,
      };
}

/// The Enrollment this phone has in flight, as the projection names it.
///
/// Carried beside the standing because two of the acts a person can take need
/// facts the standing alone cannot hold: withdrawing one needs its id, and an
/// Enrollment that can only expire needs the time it does. A screen without
/// them can name neither, and would fall back to the sentence this whole model
/// exists to delete — a wait with no end and no cause.
class MobileBodyEnrollmentRef {
  const MobileBodyEnrollmentRef({
    required this.enrollmentId,
    required this.proposalRevision,
    this.expiresAt,
  });

  final String enrollmentId;
  final int proposalRevision;

  /// When the Authority stops carrying this proposal.
  ///
  /// Nullable because a projection this build cannot read the time out of is a
  /// real possibility, and a screen that says 「会过期」 without a time is still
  /// truer than one that invents one or crashes.
  final DateTime? expiresAt;
}

/// What the screen says about a standing: what happened, what is missing, and
/// who can act. All three in every sentence, because a sentence missing the
/// third one is what 「正在关联 Companion」 was.
class MobileBodySentence {
  const MobileBodySentence({
    required this.headline,
    required this.detail,
    required this.connectionLabel,
  });

  final String headline;
  final String detail;
  final String connectionLabel;
}

/// What to say about an Enrollment this phone can no longer finish.
///
/// The Authority cannot describe this, and that is why it is a separate
/// function rather than another standing: from where Admission sits the
/// proposal is healthy and progressing. What it cannot see is that the
/// collection challenge and the one-shot handoff key existed only in the
/// process that proposed, and that process is gone.
///
/// [expiresAt] is the whole difference between this and the sentence it
/// replaces. 「正在领取归属凭证 / 不需要你做什么」 is a claim about the present
/// that is false. A wait is honest only when it names its end.
MobileBodySentence unfinishableEnrollmentSentence({
  required bool withdrawable,
  DateTime? expiresAt,
  String fingerprint = '',
}) {
  final fingerprintClause =
      fingerprint.isEmpty ? '' : '这台手机的密钥指纹是 $fingerprint。';
  final cause = '领取归属凭证要用的一次性密钥和挑战只存在于提出登记的那次运行里，'
      '它们已经不在了 —— 不是这台手机弄丢了权限，是这份凭证任何一方都再打不开。';
  if (withdrawable) {
    return MobileBodySentence(
      headline: '这次登记已经无法完成',
      detail: '$cause这一次还没有被批准，所以可以撤回，然后重新登记一次。'
          '$fingerprintClause',
      connectionLabel: '需要撤回',
    );
  }
  final deadline = expiresAt == null
      ? '它会自己过期 —— 这个版本读不出具体时刻。'
      : '它会在 ${_localTimestamp(expiresAt)} 过期。';
  return MobileBodySentence(
    headline: '这次登记已经无法完成',
    // Saying it cannot be withdrawn is not an apology, it is the fact that
    // decides what to do next: the Authority allows no transition from
    // approved to canceled, so nothing here or anywhere can end it early.
    detail: '$cause它已经被批准，而已批准的登记不能撤回，$deadline'
        '过期之后可以重新登记。$fingerprintClause',
    connectionLabel: '等待过期',
  );
}

String _localTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

MobileBodySentence mobileBodySentence(
  MobileBodyStanding standing, {
  String fingerprint = '',
  ChannelRefusal? refusal,
}) {
  final fingerprintClause =
      fingerprint.isEmpty ? '' : '这台手机的密钥指纹是 $fingerprint。';
  return switch (standing) {
    MobileBodyStanding.notEnrolled => MobileBodySentence(
        headline: '这台手机还不是一个身体',
        detail: '它没有向主机提出过登记，所以不在「认领待接入设备」队列里 —— 队列是空的，'
            '不是没轮到它。只有设备本人能替自己提出，而这一步现在可以做：'
            '登记之后，还需要你自己批准它。$fingerprintClause',
        connectionLabel: '未登记',
      ),
    MobileBodyStanding.pendingReview => MobileBodySentence(
        headline: '等你批准这台手机',
        detail: '登记已经提出，主机在等一个批准。这个批准你自己就能给 —— '
            '你手上这台手机就是这个 Owner 的 Controller。$fingerprintClause',
        connectionLabel: '待你批准',
      ),
    MobileBodyStanding.approvedAwaitingHandoff => MobileBodySentence(
        headline: '已批准，正在领取归属凭证',
        detail: '这一步在这台手机上跑，通常几秒钟。不需要你做什么。',
        connectionLabel: '领取凭证中',
      ),
    MobileBodyStanding.grantDelivered => MobileBodySentence(
        headline: '凭证已领取，正在向主机确认',
        detail: '这一步在这台手机上跑。确认之后这台手机就归属这个 Owner 了。',
        connectionLabel: '确认归属中',
      ),
    // Four different facts used to arrive here wearing one sentence. The
    // Host's refusal carries a tag, and this phone was discarding it before
    // going on to tell the person the answers were indistinguishable. They are
    // not, and they differ in the only way that matters: who acts next.
    MobileBodyStanding.claimActiveWithoutChannel => switch (refusal) {
        ChannelRefusal.claimNotActive => MobileBodySentence(
            headline: '主机不给这台手机通话通道',
            detail: '主机说这台手机的归属现在不生效，所以不分配通道 —— 再问一次是'
                '同样的答案，等下去不会变。这一步要在管理端处理：确认这台设备仍然'
                '归属这个 Owner，并且指定了由谁应答。$fingerprintClause',
            connectionLabel: '主机已拒绝',
          ),
        ChannelRefusal.deviceFactsStale => MobileBodySentence(
            headline: '这台手机存的记录比主机旧了',
            detail: '主机认得这台设备，但它手上那份记录已经不是当前那一份，所以主机'
                '不按它分配通道 —— 带着同一份记录再问，答案一样，等下去不会变。'
                '要让它重新登记一次才能对齐：在管理端的「设备」里移除这台设备，'
                '它下一次连接会自己重新提出登记。$fingerprintClause',
            connectionLabel: '记录已过期',
          ),
        ChannelRefusal.hostUnanswered => MobileBodySentence(
            headline: '没能问到主机',
            detail: '这一次请求没有完成，所以还不知道主机会不会给通道 —— 这和'
                '「主机说没有」是两件事。通常是网络或者主机正忙，再试一次是有意义的。',
            connectionLabel: '没问到主机',
          ),
        // Nothing was refused: the Host answered and had no channel to give.
        // The one case where waiting is honest advice, and the only one this
        // sentence was ever true for.
        null => MobileBodySentence(
            headline: '已归属这个 Owner，还没有通话通道',
            detail: '归属这一步已经完成，这台手机也已经问过主机了 —— 主机没有拒绝，'
                '只是现在没有通道给它。通道由主机在归属之后分配，所以再问一次'
                '可能就有了。',
            connectionLabel: '缺通话通道',
          ),
      },
    MobileBodyStanding.claimRevoked => MobileBodySentence(
        headline: '这台手机的归属已被撤销',
        detail: '要重新用它对话，得重新登记一次 —— 这一步这台手机自己就能提出，'
            '提出之后仍然要你批准。撤销是主机上发生的事，重新登记不会把它撤回。',
        connectionLabel: '归属已撤销',
      ),
    MobileBodyStanding.admissionEnded => MobileBodySentence(
        headline: '这次登记没有走完',
        detail: '它被拒绝、过期或取消了，这一次不会再向前推进 —— 等下去不会变。'
            '可以重新提出一次登记，那是一次新的登记，仍然要你批准。',
        connectionLabel: '登记已结束',
      ),
  };
}
