/// Why a claimed Body has no channel, when the Host said something about it.
///
/// Deliberately a separate axis from [MobileBodyStanding]. That enum answers
/// where this phone stands in *Admission*, and the answer here is `active` —
/// the claim is fine. What varies is the Host's answer to `configuration:pull`,
/// and folding a second question into the first enum is how three distinct
/// Admission stages once came to share one screen.
///
/// This exists because the phone was throwing the answer away. Device Control
/// refuses with a tagged reason — `STALE_GENERATION`, `CLAIM_NOT_ACTIVE`,
/// `MANIFEST_REVISION_CONFLICT` — and `mobile_conversation_provisioner.dart`
/// caught the refusal with a bare `on Exception` that did not even bind the
/// object, then reported every one of them, plus every timeout and every
/// unparseable body, as the same thing: 「已归属这个 Owner，还没有通话通道」.
/// That sentence went on to tell the person 「这两种情况主机的回答是一样的，
/// 这台手机分不出来」, which was the one part that was not true. The Host's
/// answers differ, and they differ in the only way that matters: **who has to
/// act next.**
///
/// A null refusal is not a fourth member here. It means the Host answered
/// without refusing and simply had no channel to give — a real state, with its
/// own sentence, and the only one where waiting is the right advice.
enum ChannelRefusal {
  /// `CLAIM_NOT_ACTIVE` — the Host will not serve this Body at all.
  ///
  /// Asking again with the same facts gets the same answer. Only the Owner can
  /// change it.
  claimNotActive,

  /// `STALE_GENERATION` or `MANIFEST_REVISION_CONFLICT` — the record this
  /// phone presented is not the one the Host holds.
  ///
  /// It no longer means "behind", which is what it used to mean and the only
  /// thing it ever said out loud. `configuration:pull` finds the Claim by
  /// identity and answers with the ref the Authority holds, so a ref that fell
  /// behind is corrected in the answer and re-pinned by
  /// `MobileConversationProvisioner` — it never reaches this enum. What is left
  /// under the tag is the Authority holding no Claim at this identity in this
  /// Owner Domain.
  ///
  /// A fresh Enrollment is what aligns them. Note what this must *not*
  /// promise: [MobileBodyStanding.claimActiveWithoutChannel] has
  /// `canProposeItself == false`, so no propose act is offered here, and a
  /// sentence claiming this phone will register itself would be a promise with
  /// no control behind it — the shape this file exists to remove. Nor may it
  /// send anyone to remove the device: that is not the Host's precondition for
  /// re-enrolling, and it costs the mount and the Owner's Companion binding.
  deviceFactsStale,

  /// No answer arrived: the request did not complete, or came back unreadable.
  ///
  /// Distinct from every refusal above because nothing was decided. Reporting
  /// it as 「已经问过主机了」 was false — the phone had not been answered.
  hostUnanswered;

  /// Whether waiting can end this by itself.
  ///
  /// The same question [MobileBodyStanding.advances] answers, and it gates the
  /// same things: whether the screen presents a wait, and whether the five
  /// second activation poll keeps running.
  ///
  /// False for the two refusals — a decision does not change because time
  /// passed, and polling in front of one is the retry-before-nothing this app
  /// keeps deleting. True for [hostUnanswered], where the request itself is
  /// what has not succeeded yet: there, asking again is precisely the remedy,
  /// and an earlier draft of this getter said false for all three, which would
  /// have stopped the poll exactly when it was the right thing to do.
  bool get advances => this == hostUnanswered;

  /// The [ChannelRefusal] a Device Control `detail` names, if this build knows
  /// it.
  ///
  /// An unrecognised tag returns null rather than guessing: a reason nobody has
  /// mapped is not evidence for any particular remedy, and inventing one is how
  /// a screen comes to advise an act that cannot help. The caller then says
  /// only what it knows.
  static ChannelRefusal? forDetail(String detail) => switch (detail.trim()) {
        'CLAIM_NOT_ACTIVE' => claimNotActive,
        'STALE_GENERATION' || 'MANIFEST_REVISION_CONFLICT' => deviceFactsStale,
        _ => null,
      };
}
