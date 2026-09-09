/// Local classification of Device Control outcomes. Wire codes stay intact.
enum ChannelRefusal {
  claimNotActive,
  deviceFactsStale,
  hostUnanswered,
  proofRejected,
  invalidResponse,
  unknownRefusal,
  localClaimMissing,
  ownerMismatch;

  bool get advances => this == hostUnanswered;

  static ChannelRefusal forDetail(String detail) => switch (detail.trim()) {
        'CLAIM_NOT_ACTIVE' => claimNotActive,
        'STALE_GENERATION' => deviceFactsStale,
        'MANIFEST_REVISION_CONFLICT' => invalidResponse,
        _ => unknownRefusal,
      };
}
