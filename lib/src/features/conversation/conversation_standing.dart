/// What this client actually knows about the far end of a conversation, and on
/// what evidence.
///
/// One value per distinct piece of evidence that can arrive, because the
/// screen's sentence has to be justified by one of them. This replaced a single
/// `bool conversationConfirmed`, which could only distinguish "asked" from
/// "answered" — and a boolean is the wrong shape here, because there are three
/// separate things a person can be told and two of them were being asserted
/// from the same flag.
///
/// The two the flag got wrong:
///
/// **「正在聆听」 was never evidence-backed.** `session_started` is published
/// after `session.start()`, so it does mean the far end is serving — but the
/// agent's `_warmup_stages` catches and logs every stage failure without
/// aborting (`shared/pipeline.py`, deliberately: a TTS warmup miss only costs
/// the first stream its handshake, and STT should still warm even if TTS
/// failed). So an agent whose STT is dead sends `session_started` and then sits
/// deaf, while this client said 「正在聆听 / 请直接说话」. A person talks into
/// nothing and every surface reads healthy. The evidence that the far end
/// hears is a final transcript of this device's own speech coming back, and
/// nothing weaker.
///
/// **A far end that leaves was indistinguishable from one that is thinking.**
/// If the agent dies mid-conversation it cannot publish `session_end` — the
/// channel is already gone, which the Provider now logs as INFO rather than a
/// fault — so no packet arrives and the flag stayed true. The screen held
/// 「对话中」 with the microphone open, indefinitely. Nobody being left in the
/// room is itself the evidence, and it needs no packet and no agent identity.
///
/// Deliberately *not* modelled: how long a wait may last before it is too
/// long. "Too long" is a number that has to agree across Bodies or two Bodies
/// will contradict each other about the same silence, so it belongs in the
/// contract, not in this enum.
enum ConversationStanding {
  /// `session_open` is published and nothing has replied.
  ///
  /// Not an error and not a failure — most conversations pass through here in
  /// well under a second. It is only a lie if the screen claims more.
  asked,

  /// The far end said it is serving this conversation (`session_started`), and
  /// that is the whole of what this client knows.
  accepted,

  /// The far end has demonstrably processed this device's own speech: a final
  /// transcript attributed to this device came back on `lk.transcription`.
  hearing,

  /// Nobody is left on the far end.
  ///
  /// Reached from any of the above. Distinct from a conversation that ended:
  /// this one was cut off, and a screen that quietly returned to standby would
  /// be the dead end this project keeps finding.
  farEndGone;

  /// Whether anything on the far end has answered at all.
  bool get answered => this == accepted || this == hearing;

  /// Whether this client may state that the far end hears the person.
  ///
  /// Only [hearing] — but note what this must *not* gate. [accepted] still has
  /// to invite the person to speak, because their first utterance is what
  /// produces this evidence; withholding the invitation until the evidence
  /// arrives would deadlock the conversation on itself. So the invitation is
  /// unconditional and the *claim* is not. That distinction is the whole point
  /// of the value.
  bool get hearsUs => this == hearing;
}
