import '../../generated/management_v1.dart';
import '../../models/when.dart';

/// What is mine, right now — the one read this app makes when it opens.
///
/// **This is the Owner's view, and its subject is the Owner and their Eidolons —
/// plural.** It was not. The Host used to lead with `answering`: one Companion,
/// promoted, carrying every rich fact while the rest were a number. That put a
/// routing fallback ("who replies when nobody was named", explicitly *not* a
/// rank) at the centre of a person's own home screen, and it could not show two
/// Eidolons being live at once — which is ordinary, since a Host keeps runtime
/// context per Companion.
///
/// So what belongs here is what belongs to the *person*: their name, their
/// Eidolons, their memory (one Realm, shared by all of them), their devices,
/// their machine. What belongs to one Eidolon — its persona, its face, what it
/// has been through — belongs on that Eidolon's own page, or only the one that
/// happened to answer would have any of it.
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

/// One of this Owner's Eidolons, as the list shows it.
///
/// Deliberately thin. A row says which Eidolon this is, what state its life is
/// in, and when this person last spoke to it — enough to choose one. Everything
/// else is read when that one is opened, which is also what stops the list from
/// making N calls to fill in facts nobody has asked for yet.
class HostCompanion {
  const HostCompanion({
    required this.companionId,
    required this.displayName,
    required this.kind,
    required this.lifecycleState,
    required this.revision,
    required this.lastSpokenAt,
  });

  factory HostCompanion.fromView(CompanionSummaryView view) => HostCompanion(
        companionId: view.companionId,
        displayName: view.displayName ?? '',
        kind: view.kind,
        lifecycleState: view.lifecycleState,
        revision: view.revision,
        lastSpokenAt: parseInstant(view.lastActiveAt),
      );

  final String companionId;
  final String displayName;
  final String kind;

  /// active / retiring / archived / deleting, as the Host says it. A value this
  /// build does not know still renders — the Host may be newer than the app.
  final String lifecycleState;
  final int revision;

  /// When this person last spoke to it, or null when they never have.
  ///
  /// Null is only "never" when the answer it came from had no
  /// [HostHome.activityUnavailable]; with one, nobody could ask and a screen
  /// has nothing truthful to say about recency.
  ///
  /// It is not presence, and there is no field here for that. Nothing on the
  /// Host tracks whether a body is reachable, which is why devices still report
  /// their own online state as unknown. Two fields tried to stand in for it:
  /// 运行中 whenever the Owner had a default Companion — a routing setting read
  /// as runtime state — and then whether the Agent process happened to hold a
  /// live object, which emptied on every restart and printed 「未运行」 on
  /// Eidolons that were perfectly fine.
  final DateTime? lastSpokenAt;

  bool get isPutAway => lifecycleState == 'archived';
}

class HostHome {
  const HostHome({
    required this.ownerDisplayName,
    required this.ownerRevision,
    required this.companions,
    required this.defaultCompanionId,
    required this.activityUnavailable,
    required this.memory,
    required this.companionCounts,
    required this.devices,
    required this.machineAttention,
    required this.unavailable,
  });

  factory HostHome.fromView(HomeView view) => HostHome(
        ownerDisplayName: view.ownerDisplayName ?? '',
        ownerRevision: view.ownerRevision,
        companions: [
          for (final row in view.companions ?? const <CompanionSummaryView>[])
            HostCompanion.fromView(row),
        ],
        defaultCompanionId: view.defaultCompanionId,
        activityUnavailable: view.activityUnavailable ?? '',
        memory: view.memory ?? '',
        companionCounts: HostHomeCounts.fromView(view.companionCounts),
        devices: HostHomeCounts.fromView(view.devices),
        machineAttention: view.machineAttention ?? const [],
        unavailable: view.unavailable ?? const {},
      );

  final String ownerDisplayName;
  final int ownerRevision;

  /// This Owner's Eidolons. The first page of them, in the Host's order.
  final List<HostCompanion> companions;

  /// Which one replies when nobody was named — a setting this person made, and
  /// nothing more. Null is a real state (all put away, or none created yet) and
  /// this app must not resolve it by picking one.
  final String? defaultCompanionId;

  /// Why no row carries a [HostCompanion.lastSpokenAt], when none does. Empty
  /// means the Host asked and got an answer, so a row with no time is a row
  /// this person has never spoken to.
  final String activityUnavailable;

  /// What this Owner's memory holds, in words. **Theirs** — one Realm per
  /// Owner, every Eidolon reading and writing it through an audience. This used
  /// to hang off whichever Companion answered and be labelled 它的记忆.
  final String memory;

  final HostHomeCounts companionCounts;
  final HostHomeCounts devices;

  /// What the Host said needs attention, already phrased on that side. Empty
  /// means nothing did, which is different from not having been able to look.
  final List<String> machineAttention;

  /// Which parts the Host could not read, and why. A screen shows what it got
  /// and says this much is unknown — a blank with no explanation cannot be told
  /// from a blank that is true.
  final Map<String, String> unavailable;

  bool get sawEverything => unavailable.isEmpty;

  /// The Eidolon that replies when nobody was named, if this answer lists it.
  HostCompanion? get answering {
    final id = defaultCompanionId;
    if (id == null) return null;
    for (final row in companions) {
      if (row.companionId == id) return row;
    }
    return null;
  }

  /// Whether this answer includes the Companion the setup just produced.
  ///
  /// The cross-Owner half of the old check is structurally gone: the Owner is
  /// derived from the session and is not expressible by a caller. What is left
  /// worth checking is that the Eidolon this device just helped create is among
  /// the ones the Host says exist — a *membership* test now, where it used to
  /// ask whether it was the promoted one. A newly created Eidolon is not
  /// necessarily the one that answers, and treating that as a mismatch refused
  /// to show a person their own Host.
  bool answersFor(String? companionId) =>
      companionId == null ||
      companions.any((row) => row.companionId == companionId);
}
