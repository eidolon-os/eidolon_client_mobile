import '../../generated/management_v1.dart';
import '../../protocol/companion_contract.dart';
import 'cockpit_models.dart';
import 'cockpit_wire.dart';

/// Joins the three answers the star map is drawn from.
///
/// Each fact has one authority, and the plan says which:
///
/// * `/context` — who the Owner is, and which Companion answers by default;
/// * the roster — which Companions exist, their names and lifecycle. Its
///   `kind` / `is_default` / `revision` / `lifecycle_state` are authority fields,
///   not projections;
/// * Mission Control — only what was observed, keyed by ids the caller already
///   holds. Its route takes `?companion_id=`, which is the tell.
///
/// So this is not "two sources on one screen" traded against convenience: it is
/// the division of labour the authorities already have. What made it safe to
/// draw was already here — a lane that did not read says so, so a Companion
/// whose runtime is unknown is drawn as a planet with 读不到 moons rather than as
/// one that looks idle.
///
/// It takes reads as functions rather than importing the management client: this
/// feature is not allowed to know a transport, and the client it would reach for
/// is being reshaped capability by capability in another line. The composition
/// root wires them.
typedef ContextRead = Future<ManagementContextView> Function();
typedef RosterRead = Future<CompanionRosterView> Function();

/// Mission Control's runtime read. Null while the management plane has no
/// producer for it — which is today: every runtime lane then reports
/// unavailable, with the reason, instead of the screen implying a quiet domain.
typedef RuntimeRead = Future<CockpitRuntime> Function();

class CockpitComposer {
  const CockpitComposer({
    required this.readContext,
    required this.readRoster,
    this.readRuntime,
    this.runtimeAbsentDetail = 'Mission Control 投影尚未在管理面提供',
  });

  final ContextRead readContext;
  final RosterRead readRoster;
  final RuntimeRead? readRuntime;

  /// Said out loud on every runtime lane while there is no producer. A reader
  /// who sees "读不到" is owed the reason, and "not built yet" is a reason.
  final String runtimeAbsentDetail;

  /// One composed reading. Identity failures throw — a star map with no Owner
  /// and no Companions has nothing to draw and must not pretend otherwise.
  /// Runtime failures do not: they land in the lanes, which is what lanes are
  /// for.
  Future<CockpitSnapshot> read() async {
    final context = await readContext();
    final roster = await readRoster();

    late final CockpitRuntime runtime;
    final runtimeRead = readRuntime;
    if (runtimeRead == null) {
      runtime = CockpitRuntime.unavailable(runtimeAbsentDetail);
    } else {
      try {
        runtime = await runtimeRead();
      } catch (error) {
        // Observation degraded, not a domain that stopped.
        runtime = CockpitRuntime.unavailable('$error');
      }
    }

    return attachRecall(
      CockpitSnapshot(
        provenance: CockpitProvenance.host,
        generatedAt: runtime.observedAt,
        cursor: runtime.cursor,
        ownerLane: CockpitLane<CockpitOwner?>.ok(
          CockpitOwner(
            ownerId: context.owner.ownerId,
            displayName: context.owner.displayName ?? '',
          ),
        ),
        companionsLane: CockpitLane<List<CockpitCompanion>>.ok(
          roster.companions
              .map(
                (row) => CockpitCompanion(
                  companionId: row.companionId,
                  displayName: row.displayName ?? '',
                  status: row.lifecycleState,
                  kind: row.kind,
                  genomeId: row.genomeId ?? '',
                  // Null is "the authority did not answer"; an empty string is
                  // the distinct, authoritative answer "no realm configured".
                  realmId: row.memoryRealmId,
                ),
              )
              .toList(growable: false),
        ),
        // The default pointer has two authorities that must agree, and the
        // roster page is the one that came with this roster. Falling back to
        // /context rather than preferring it, because a stale pointer next to a
        // fresh list would mark the wrong planet.
        defaultCompanionId:
            roster.defaultCompanionId ?? context.defaultCompanionId,
        devicesLane: runtime.devices,
        activitiesLane: runtime.activities,
        turnsLane: runtime.turns,
        jobsLane: runtime.jobs,
        memoryLane: runtime.memory,
        servicesLane: runtime.services,
        eventsLane: runtime.events,
        traceId: '—',
      ),
    );
  }
}

/// Companions the star map should not draw as planets.
///
/// A deleting Companion is on its way out of existence; drawing it as a planet
/// with unknown runtime would keep it on screen after the Owner asked for it to
/// go. Archived and retiring ones stay — the Owner put them there and their
/// lifecycle badge says which.
bool drawableOnMap(CockpitCompanion companion) =>
    companion.status != lifecycleDeleting;
