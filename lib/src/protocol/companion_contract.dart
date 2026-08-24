/// The Companion vocabulary, mirrored once for this app.
///
/// Source of truth: `eidolon_sdk/eidolon_sdk/biz/contracts/companion.py`, which
/// is itself downstream of the Companion authority (`eidolon_data`) — the values
/// are the producer's, and a change here that Data has not made is a lie about
/// what a Host will send.
///
/// Why this file exists at all: before it, the same four values were spelled out
/// three times inside this repository — twice as an identical private
/// `_lifecycleSentence` in the management surface, and once more as a badge
/// label in the star map, which had additionally drifted to a set the authority
/// never publishes. Upstream had just finished collapsing seven Python copies
/// and three JSON Schema copies for exactly this reason. One repository is not
/// exempt from the failure that motivated that.
///
/// Boundary: pure vocabulary and words. No Flutter, no feature imports, and in
/// particular no colour — a tone belongs to whichever surface is painting, and
/// `features/constellation` owns its own palette. Both the management surface
/// and the star map import from here; nothing here imports from them.
library;

const lifecycleActive = 'active';

/// On the way out, still present.
const lifecycleRetiring = 'retiring';

/// Put away by the Owner. Its memory is kept.
const lifecycleArchived = 'archived';

/// Deletion under way. Terminal, and not a state anything recovers from.
const lifecycleDeleting = 'deleting';

/// Ordered as the SDK orders them, so a generated document and a screen read
/// the same way.
const companionLifecycleStates = <String>{
  lifecycleActive,
  lifecycleRetiring,
  lifecycleArchived,
  lifecycleDeleting,
};

/// Whether this Companion is running. The only one of the four that is.
bool isCompanionActive(String lifecycleState) =>
    lifecycleState == lifecycleActive;

/// A full sentence, for a roster row or a detail screen.
///
/// An unfamiliar value is described as unknown rather than shown raw or treated
/// as active: the Host is entitled to grow this set, and a row must stay
/// readable when it does.
String companionLifecycleSentence(String lifecycleState) =>
    switch (lifecycleState) {
      lifecycleActive => '在这台 Host 上运行',
      lifecycleRetiring => '正在退出，暂时还在',
      lifecycleArchived => '你已归档，记忆还留着',
      lifecycleDeleting => '正在删除',
      _ => '这台 Host 说的状态，这个版本还不认识',
    };

/// Two or three characters, for a badge with no room for a sentence.
///
/// Same rule for an unfamiliar value, in the space available: named as unknown,
/// never shown raw and never assumed active.
String companionLifecycleLabel(String lifecycleState) =>
    switch (lifecycleState) {
      lifecycleActive => '在册',
      lifecycleRetiring => '退役中',
      lifecycleArchived => '已归档',
      lifecycleDeleting => '删除中',
      _ => '未知状态',
    };
