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
    required this.moreCompanions,
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
        moreCompanions: view.moreCompanions ?? false,
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

  /// Whether this Owner has more Eidolons than [companions] carries.
  ///
  /// The home is one page of the roster and [companionCounts] counts the page,
  /// so a screen that printed the total without this said the page size was how
  /// many somebody has. This answer cannot be paged — the list screen is where
  /// the rest are — so what arrives is the fact, not a cursor.
  final bool moreCompanions;

  final HostHomeCounts devices;

  /// What the Host said needs attention, already phrased on that side. Empty
  /// means nothing did, which is different from not having been able to look.
  final List<String> machineAttention;

  /// Which parts the Host could not read, and why. A screen shows what it got
  /// and says this much is unknown — a blank with no explanation cannot be told
  /// from a blank that is true.
  ///
  /// The values are the Host's own diagnostic sentences and are not rendered:
  /// what a screen needs is *which* part is missing, and it says that in its
  /// own words. The keys are the Host's names for the five reads this answer
  /// is composed from.
  final Map<String, String> unavailable;

  bool get sawEverything => unavailable.isEmpty;

  /// True when nobody could read this Owner's roster.
  ///
  /// [companions] and [companionCounts] are then empty because the Host could
  /// not look, not because there is nothing to find. A screen that cannot tell
  /// those apart shows 「还没有伙伴，去新建第一位」 to somebody who has three —
  /// which is not only wrong but an invitation to do the wrong thing.
  bool get companionsUnread => unavailable.containsKey('companions');

  /// True when nobody could read the Owner's memory.
  ///
  /// [memory] is then empty for the same reason, and 「还没记下什么」 in front of
  /// a person whose Eidolon has been remembering for months is the same mistake
  /// in a more reassuring voice.
  bool get memoryUnread => unavailable.containsKey('memory');

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

/// What the 你的伙伴 row says under its name.
///
/// Read order matters and it is not the obvious one. A roster nobody could read
/// arrives as an empty list and a zero count — the same shape as an Owner who
/// genuinely has none — so the unread case is answered first. Getting that
/// backwards put 「还没有伙伴，去新建第一位」 in front of people with three of
/// them: not only a false statement but an invitation to act on it.
///
/// How many is the row's badge, and this line does not repeat it. What is left
/// is who answers when nobody was named, and the one thing still in motion.
String companionsSummaryLine(HostHome? home) {
  if (home == null) return '查看、新建和管理你的伙伴';
  if (home.companionsUnread) return '这台主机这次没能读到你的伙伴';
  if (home.companionCounts.total == 0) return '还没有伙伴，去新建第一位';

  final parts = <String>[];
  final answering = home.answering;
  if (answering != null) {
    final name =
        answering.displayName.isEmpty ? '未命名伙伴' : answering.displayName;
    parts.add('默认应答：$name');
  } else if (home.defaultCompanionId == null) {
    parts.add('尚未设置默认应答伙伴');
  } else {
    parts.add('已设置默认应答伙伴');
  }
  if (home.companionCounts.waiting > 0) {
    parts.add('${home.companionCounts.waiting} 位正在准备');
  }
  return parts.join(' · ');
}

/// What the 你的记忆 row says under its name.
///
/// The words for what is in there are the Host's. It already says 「还没记下什么」
/// for a memory nothing has been written into, and a second copy of that
/// sentence on this side would be a second place for it to drift. What this
/// adds is where it lives, and the one thing the Host's sentence cannot carry:
/// that there was no sentence.
///
/// An empty summary and a declared failure are treated the same way, because
/// the Host only leaves the summary empty when the read failed. A blank that
/// arrived without being declared is still a blank nobody can vouch for, and
/// 「还没记下什么」 over it would be inventing an answer on the one screen a
/// person opens to check their memory is still there.
///
/// [failed] distinguishes the two ways there is no answer yet at all: a read
/// still in flight, and one that came back refused.
String memorySummaryLine(HostHome? home, {required bool failed}) {
  if (home == null) return failed ? '暂时无法读取记忆概览' : '正在读取记忆概览';
  if (home.memoryUnread || home.memory.isEmpty) {
    return '这台主机这次没能读到记忆概览';
  }
  return '${home.memory}，留在这台主机上，没有离开过';
}
