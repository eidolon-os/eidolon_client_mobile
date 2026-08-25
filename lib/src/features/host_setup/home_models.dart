import '../../generated/management_v1.dart';

/// What is mine, right now — the one read this app makes when it opens.
///
/// It replaced a single-Companion runtime projection whose shape assumed there
/// was one Eidolon and one of everything under it. What changed is not only the
/// count: the Host now answers in words a person can act on — which chapter its
/// persona is on rather than a genome id, how much it remembers rather than a
/// realm identifier — and names the parts it could not read instead of leaving
/// them blank.
class HostHomeCounts {
  const HostHomeCounts({
    required this.total,
    required this.ready,
    required this.waiting,
    required this.putAway,
  });

  factory HostHomeCounts.fromView(HomeCountsView view) => HostHomeCounts(
        total: view.total,
        ready: view.ready,
        waiting: view.waiting,
        putAway: view.putAway,
      );

  final int total;

  /// Usable right now.
  final int ready;

  /// There, and waiting for something the person has to decide — a device
  /// nothing answers through, an Eidolon mid-move.
  final int waiting;

  /// There, and deliberately not in use.
  final int putAway;
}

/// The Eidolon that answers when nobody was named.
class HostHomeCompanion {
  const HostHomeCompanion({
    required this.companionId,
    required this.displayName,
    required this.lifecycleState,
    required this.revision,
    required this.hasFace,
    required this.personaChapter,
    required this.memory,
    required this.personaGenomeId,
  });

  factory HostHomeCompanion.fromView(HomeCompanionView view) =>
      HostHomeCompanion(
        companionId: view.companionId,
        displayName: view.displayName ?? '',
        lifecycleState: view.lifecycleState,
        revision: view.revision,
        hasFace: view.hasFace ?? false,
        personaChapter: view.personaChapter ?? '',
        memory: view.memory ?? '',
        personaGenomeId: view.personaGenomeId ?? '',
      );

  final String companionId;
  final String displayName;
  final String lifecycleState;
  final int revision;
  final bool hasFace;

  /// Which chapter it is on, in words — 「第 3 章 · 我发现你不喜欢被打断」. Empty
  /// when the Host could not read the history, which is not the same as an
  /// Eidolon that has never changed; that difference is in [HostHome.unavailable].
  final String personaChapter;

  /// What it remembers, as a count rather than a place. Empty when unread.
  final String memory;

  /// For the technical corner of a screen, and for reading out when asking for
  /// help. Never what a person is shown first.
  final String personaGenomeId;
}

class HostHome {
  const HostHome({
    required this.ownerDisplayName,
    required this.ownerRevision,
    required this.answering,
    required this.companions,
    required this.devices,
    required this.machineAttention,
    required this.unavailable,
  });

  factory HostHome.fromView(HomeView view) => HostHome(
        ownerDisplayName: view.ownerDisplayName ?? '',
        ownerRevision: view.ownerRevision,
        answering: view.answering == null
            ? null
            : HostHomeCompanion.fromView(view.answering!),
        companions: HostHomeCounts.fromView(view.companions),
        devices: HostHomeCounts.fromView(view.devices),
        machineAttention: view.machineAttention ?? const [],
        unavailable: view.unavailable ?? const {},
      );

  final String ownerDisplayName;
  final int ownerRevision;

  /// Null is a real state — every Eidolon put away, or none created yet — and
  /// this app must not resolve it by picking one.
  final HostHomeCompanion? answering;
  final HostHomeCounts companions;
  final HostHomeCounts devices;

  /// What the Host said needs attention, already phrased on that side. Empty
  /// means nothing did, which is different from not having been able to look.
  final List<String> machineAttention;

  /// Which parts the Host could not read, and why. A screen shows what it got
  /// and says this much is unknown — a blank with no explanation cannot be told
  /// from a blank that is true.
  final Map<String, String> unavailable;

  bool get sawEverything => unavailable.isEmpty;

  /// Whether this answer describes the Companion the setup just produced.
  ///
  /// The cross-Owner half of the old check is structurally gone: the Owner is
  /// derived from the session and is not expressible by a caller. What is left
  /// worth checking is that the Eidolon named here is the one this device just
  /// helped create.
  bool answersFor(String? companionId) =>
      companionId == null || answering?.companionId == companionId;
}
