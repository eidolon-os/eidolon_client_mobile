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
        headline: '将本机接入对话',
        detail: '先登记这台虚拟设备，再由你明确确认接入。完成后即可选择伙伴开始对话。$fingerprintClause',
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
    MobileBodyStanding.claimActiveWithoutChannel => MobileBodySentence(
        headline: switch (refusal) {
          ChannelRefusal.claimNotActive => '本机的对话授权暂不可用',
          ChannelRefusal.deviceFactsStale => '需要恢复本机接入',
          ChannelRefusal.hostUnanswered => '暂时无法连接对话服务',
          ChannelRefusal.proofRejected => '本机身份验证未通过',
          ChannelRefusal.invalidResponse => '对话服务返回了无效配置',
          ChannelRefusal.unknownRefusal => '对话服务拒绝了这次请求',
          ChannelRefusal.localClaimMissing => '本机接入记录需要恢复',
          ChannelRefusal.ownerMismatch => '本机保存的登记与此主机不一致',
          null => '正在准备对话通道',
        },
        detail: switch (refusal) {
          ChannelRefusal.claimNotActive => '请查看本机设备的授权状态，再继续对话。',
          ChannelRefusal.deviceFactsStale => '主机未找到对应的归属记录。请检查本机接入；无需先移除设备。',
          ChannelRefusal.hostUnanswered => '未能取得服务响应。请检查网络后重试，已完成的接入会保留。',
          ChannelRefusal.proofRejected => '请检查设备授权或服务配置。重复登记不会自动解决身份验证失败。',
          ChannelRefusal.invalidResponse => '配置未通过校验。请检查主机服务版本，具体原因可在诊断中查看。',
          ChannelRefusal.unknownRefusal => '服务已拒绝请求，原因可在诊断中查看。请检查主机服务。',
          ChannelRefusal.localClaimMissing => '可以核验并恢复此主机上已完成的设备登记。',
          ChannelRefusal.ownerMismatch => '如果本机曾在此主机完成接入，可以恢复已有登记；也可以返回选择原主机。',
          null => '暂未取得通道，服务尚未提供原因。稍后仍未就绪时，可以检查主机服务。',
        },
        connectionLabel: refusal == null ? '准备通道' : '需要处理',
      ),
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
