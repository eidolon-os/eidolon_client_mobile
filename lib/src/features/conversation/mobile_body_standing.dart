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
/// would ever make. Only a device may propose itself, and this app cannot yet
/// do it (see `docs/跨系统/纯软件Body准入身份裁决.md`).
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
  bool get advances => switch (this) {
        pendingReview || approvedAwaitingHandoff || grantDelivered => true,
        notEnrolled ||
        claimActiveWithoutChannel ||
        claimRevoked ||
        admissionEnded =>
          false,
      };

  /// Whether the Owner holding this phone can approve it from here.
  ///
  /// True for exactly one stage, and it is the one the phone used to poll in
  /// silence: it was waiting for an approval it is itself authorised to give.
  bool get awaitsThisControllersApproval => this == pendingReview;
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

MobileBodySentence mobileBodySentence(
  MobileBodyStanding standing, {
  String fingerprint = '',
}) {
  final fingerprintClause =
      fingerprint.isEmpty ? '' : '这台手机的密钥指纹是 $fingerprint。';
  return switch (standing) {
    MobileBodyStanding.notEnrolled => MobileBodySentence(
        headline: '这台手机还不是一个身体',
        detail: '它没有向主机提出过登记，所以不在「认领待接入设备」队列里 —— 队列是空的，'
            '不是没轮到它。只有设备本人能替自己提出，而这个版本的手机还不会做这一步，'
            '所以这里没有可以重试的动作。$fingerprintClause',
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
    MobileBodyStanding.claimActiveWithoutChannel => MobileBodySentence(
        headline: '已归属这个 Owner，还没有通话通道',
        detail: '归属这一步已经完成。主机还没有给这台手机分配通话通道 —— '
            '这是当前版本到此为止，不是正在进行中，等下去不会变。',
        connectionLabel: '缺通话通道',
      ),
    MobileBodyStanding.claimRevoked => MobileBodySentence(
        headline: '这台手机的归属已被撤销',
        detail: '要重新用它对话，得重新登记一次。这个版本的手机还不会替自己提出登记，'
            '所以这里也没有可以重试的动作。',
        connectionLabel: '归属已撤销',
      ),
    MobileBodyStanding.admissionEnded => MobileBodySentence(
        headline: '这次登记没有走完',
        detail: '它被拒绝、过期或取消了，不会再向前推进。重新登记需要这台手机自己提出，'
            '而这个版本还不会做这一步。',
        connectionLabel: '登记已结束',
      ),
  };
}
