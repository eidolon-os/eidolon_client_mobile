import '../../protocol/companion_contract.dart';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'cockpit_models.dart';

/// Where every node of the sovereign constellation sits.
///
/// Pure geometry, no widgets: the layout is the part most likely to be wrong in
/// a way a screenshot hides (a moon tucked under its planet, a body port off
/// the canvas), so it is computed somewhere a test can measure it.
///
/// The console lays its companions on a wide ellipse because it is drawn for a
/// wall. Here the ellipse is much taller than it is wide and the first companion
/// starts at the top, so a phone's vertical extent carries the domain instead of
/// leaving voids above and below.
///
/// The canvas is not a fixed rectangle either: it is the bounding box of what
/// was actually placed, plus a margin. A fixed canvas means dead bands whose
/// size depends on how many companions there are — one companion leaves two
/// thirds of the map empty and the whole thing is drawn small to fit nothing.
class ConstellationMetrics {
  const ConstellationMetrics({
    this.orbitRadiusX = 152,
    this.orbitRadiusY = 260,
    this.ownerRadius = 66,
    this.planetRadius = 48,
    this.moonRadius = 31,
    this.moonOrbit = 100,
    this.moonSpreadDegrees = 52,
    this.portRadius = 12,
    this.portOrbit = 54,
    this.beadOrbit = 44,
    this.startDegrees = -90,
    this.padding = 18,
    this.neighbourGap = 28,
  });

  final double orbitRadiusX;
  final double orbitRadiusY;
  final double ownerRadius;
  final double planetRadius;
  final double moonRadius;

  /// Distance from a planet's centre to its moons' centres. Large enough that a
  /// visible length of leg shows between the two: the wires are what make this a
  /// constellation rather than a scatter of circles, and a leg that is five
  /// pixels long is a leg nobody can see. It also keeps a moon off its planet's
  /// rim, which on a touch screen would make two different things one target.
  final double moonOrbit;
  final double moonSpreadDegrees;
  final double portRadius;
  final double portOrbit;
  final double beadOrbit;
  final double startDegrees;

  /// Breathing room between the outermost node and the edge of the map.
  final double padding;

  /// The least space allowed between two neighbouring planets' rims. Sized for
  /// a finger, not for the eye: two companions closer than this are one target.
  final double neighbourGap;

  /// The portrait orbit: much taller than wide, so a phone's vertical extent
  /// carries the domain.
  static const ConstellationMetrics portrait = ConstellationMetrics();

  /// The wide orbit, for a landscape phone, a tablet held sideways or any other
  /// short-and-broad stage. Not a scaled-down portrait map: a 684-unit-tall
  /// canvas in a 173-unit-tall stage fits at 0.25, which puts the moons at
  /// fifteen pixels. The orbit itself has to turn, and then the same nodes are
  /// twice the size on the same screen.
  static const ConstellationMetrics wide = ConstellationMetrics(
    orbitRadiusX: 290,
    orbitRadiusY: 150,
  );

  /// Which orbit suits a stage of this shape. Keyed on the aspect ratio rather
  /// than on the device orientation, because a short window and a landscape
  /// phone are the same problem.
  static ConstellationMetrics forStage(Size stage) =>
      stage.height <= 0 || stage.width / stage.height > 1.15 ? wide : portrait;
}

class MoonNode {
  const MoonNode({
    required this.kind,
    required this.unit,
    required this.center,
    required this.planetCenter,
    required this.value,
    required this.tone,
    required this.empty,
    this.unreadable = false,
  });

  final MoonKind kind;
  final CompanionUnit unit;
  final Offset center;
  final Offset planetCenter;
  final String value;
  final CockpitTone tone;
  final bool empty;
  final bool unreadable;

  String get key => '${unit.id}:${kind.name}';
}

class DevicePortNode {
  const DevicePortNode({
    required this.device,
    required this.unit,
    required this.center,
    required this.bodyCenter,
    required this.active,
  });

  final CockpitDevice device;
  final CompanionUnit unit;
  final Offset center;
  final Offset bodyCenter;

  /// Whether a live activity currently names this body as origin or target.
  final bool active;
}

class ActivityBeadNode {
  const ActivityBeadNode({
    required this.activity,
    required this.unit,
    required this.center,
    required this.label,
    required this.live,
  });

  final CockpitActivity activity;
  final CompanionUnit unit;
  final Offset center;
  final String label;
  final bool live;
}

class PlanetNode {
  const PlanetNode({
    required this.unit,
    required this.center,
    required this.moons,
    required this.ports,
    required this.beads,
    required this.angle,
  });

  final CompanionUnit unit;
  final Offset center;
  final List<MoonNode> moons;
  final List<DevicePortNode> ports;
  final List<ActivityBeadNode> beads;

  /// Radians from the owner core, for anything that needs to point outward.
  final double angle;

  bool get active => unit.activeActivity != null;

  MoonNode? moon(MoonKind kind) {
    for (final moon in moons) {
      if (moon.kind == kind) return moon;
    }
    return null;
  }
}

class ConstellationLayout {
  const ConstellationLayout({
    required this.metrics,
    required this.ownerCenter,
    required this.planets,
    required this.canvas,
    this.crowded = false,
  });

  final ConstellationMetrics metrics;
  final Offset ownerCenter;
  final List<PlanetNode> planets;

  /// The map's own size: the bounding box of everything placed on it.
  final Size canvas;

  /// Too many companions for every asset moon to be drawn at once, so only the
  /// focused companion carries its moons. Measured, not a companion count: which
  /// pairs come closest depends on how the angles land on the ellipse, and odd
  /// counts crowd differently from even ones.
  final bool crowded;

  Iterable<MoonNode> get moons => planets.expand((planet) => planet.moons);
  Iterable<DevicePortNode> get ports =>
      planets.expand((planet) => planet.ports);
  Iterable<ActivityBeadNode> get beads =>
      planets.expand((planet) => planet.beads);

  PlanetNode? planet(String companionId) {
    for (final planet in planets) {
      if (planet.unit.id == companionId) return planet;
    }
    return null;
  }
}

const double _deg = math.pi / 180;

/// How much the orbit has to grow to hold [count] companions.
///
/// The angular gap between neighbours shrinks as 1/N, so a fixed ellipse
/// eventually puts two planets on top of each other — measured at 6.2dp of rim
/// clearance for ten, and their moons overlapping by 17dp well before that. The
/// chord between neighbours is `2·R·sin(π/N)`, so this returns the factor that
/// makes that chord clear both planets plus [ConstellationMetrics.neighbourGap].
///
/// The smaller radius is the constraint, because that is the direction where the
/// ellipse is tightest; scaling both by the same factor keeps the portrait shape
/// the phone needs.
double orbitGrowth(int count, ConstellationMetrics metrics) {
  if (count < 2) return 1;
  final needed = (metrics.planetRadius * 2 + metrics.neighbourGap) /
      (2 * math.sin(math.pi / count));
  final tightest = math.min(metrics.orbitRadiusX, metrics.orbitRadiusY);
  return math.max(1, needed / tightest);
}

/// Which chrome arrangement shows the most map, and which orbit to draw in it.
///
/// There are two places the instruments can go — a deck under the map, or a rail
/// beside it — and two orbits to draw, portrait and wide. Rather than keying off
/// the reported orientation, all four combinations are measured and the one that
/// draws the map largest wins. That is the same answer for a landscape phone, a
/// short split-screen window and a tablet either way up, without a special case
/// for any of them.
class ChromeChoice {
  const ChromeChoice({
    required this.rail,
    required this.metrics,
    required this.stage,
    required this.fit,
  });

  /// True to put the instruments on a rail beside the map instead of under it.
  final bool rail;
  final ConstellationMetrics metrics;
  final Size stage;

  /// The scale the map will open at, for whoever wants to sanity-check it.
  final double fit;
}

ChromeChoice chooseChrome({
  required Size viewport,
  required List<CompanionUnit> units,
  required double headerFull,
  required double headerCompact,
  required double deck,
  required double rail,
  double minRail = 200,
}) {
  ChromeChoice? best;
  for (final withRail in const [false, true]) {
    final stage = withRail
        ? Size(viewport.width - rail, viewport.height - headerCompact)
        : Size(viewport.width, viewport.height - headerFull - deck);
    if (stage.width <= 0 || stage.height <= 0) continue;
    // A rail narrower than this cannot hold a service chip, and one that leaves
    // the map less than 300dp has taken more than it gave. Both then lose to the
    // deck even where the arithmetic on map size alone would prefer them.
    if (withRail && (rail < minRail || stage.width < 300)) continue;
    for (final metrics in const [
      ConstellationMetrics.portrait,
      ConstellationMetrics.wide,
    ]) {
      final canvas = buildConstellationLayout(
        units: units,
        metrics: metrics,
      ).canvas;
      if (canvas.isEmpty) continue;
      final fit = math.min(
        stage.width / canvas.width,
        stage.height / canvas.height,
      );
      // Ties go to the phone-native arrangement, which is listed first.
      if (best == null || fit > best.fit * 1.02) {
        best = ChromeChoice(
          rail: withRail,
          metrics: metrics,
          stage: stage,
          fit: fit,
        );
      }
    }
  }
  return best ??
      ChromeChoice(
        rail: false,
        metrics: ConstellationMetrics.portrait,
        stage: viewport,
        fit: 1,
      );
}

/// Build the layout for one snapshot's companions.
ConstellationLayout buildConstellationLayout({
  required List<CompanionUnit> units,
  ConstellationMetrics metrics = const ConstellationMetrics(),
  DateTime? now,
  String focusedId = '',
}) {
  final at = now ?? DateTime.now();
  final count = units.isEmpty ? 1 : units.length;
  final growth = orbitGrowth(count, metrics);
  final radiusX = metrics.orbitRadiusX * growth;
  final radiusY = metrics.orbitRadiusY * growth;

  // First pass: place everything around an origin at (0, 0).
  final placements = <_Placement>[];
  for (var index = 0; index < units.length; index += 1) {
    final unit = units[index];
    final angle = (metrics.startDegrees + (index * 360) / count) * _deg;
    final center = Offset(
      radiusX * math.cos(angle),
      radiusY * math.sin(angle),
    );

    // Moons fan outward from the core, so the crowded side of a planet always
    // faces empty sky rather than the sun.
    final outward = math.atan2(center.dy, center.dx);
    final moons = <MoonKind, Offset>{};
    const order = [MoonKind.body, MoonKind.mem, MoonKind.act];
    for (var slot = 0; slot < order.length; slot += 1) {
      final moonAngle = outward + (slot - 1) * metrics.moonSpreadDegrees * _deg;
      moons[order[slot]] = Offset(
        center.dx + metrics.moonOrbit * math.cos(moonAngle),
        center.dy + metrics.moonOrbit * math.sin(moonAngle),
      );
    }

    final body = moons[MoonKind.body]!;
    final shown = unit.devices.take(5).toList(growable: false);
    final ports = <Offset>[];
    for (var portIndex = 0; portIndex < shown.length; portIndex += 1) {
      // A fan centred on the body moon's own outward direction: one body sits
      // straight out, several spread evenly across a 150° arc.
      final span = shown.length == 1 ? 0.0 : 150.0;
      final step = shown.length == 1 ? 0.0 : span / (shown.length - 1);
      final portAngle = outward -
          metrics.moonSpreadDegrees * _deg +
          (-span / 2 + step * portIndex) * _deg;
      ports.add(
        Offset(
          body.dx + metrics.portOrbit * math.cos(portAngle),
          body.dy + metrics.portOrbit * math.sin(portAngle),
        ),
      );
    }

    final activity = moons[MoonKind.act]!;
    final groups = summarizeActivityBeads(unit.activities, at);
    final beads = <Offset>[];
    for (var beadIndex = 0; beadIndex < groups.length; beadIndex += 1) {
      final beadAngle = outward +
          metrics.moonSpreadDegrees * _deg +
          (-42 + beadIndex * 42) * _deg;
      beads.add(
        Offset(
          activity.dx + metrics.beadOrbit * math.cos(beadAngle),
          activity.dy + metrics.beadOrbit * math.sin(beadAngle),
        ),
      );
    }

    placements.add(
      _Placement(
        unit: unit,
        center: center,
        angle: outward,
        moons: moons,
        ports: ports,
        beads: beads,
        devices: shown,
        groups: groups,
      ),
    );
  }

  // Do the asset clusters of different companions collide? Growing the orbit
  // separates the planets, but a cluster reaches 131dp past its planet, so
  // clearing those too would need a canvas wide enough to shrink every moon to
  // twenty pixels — measured, which is why this is a density rule and not a
  // bigger ellipse. When they collide, only the focused companion keeps its
  // moons; the others stay planets until tapped, which is the affordance this
  // screen already has.
  var crowded = false;
  for (var i = 0; i < placements.length && !crowded; i += 1) {
    for (var j = i + 1; j < placements.length && !crowded; j += 1) {
      for (final a in placements[i].moons.values) {
        for (final b in placements[j].moons.values) {
          if ((a - b).distance - metrics.moonRadius * 2 <
              metrics.neighbourGap) {
            crowded = true;
            break;
          }
        }
        if (crowded) break;
      }
    }
  }
  if (crowded) {
    for (var index = 0; index < placements.length; index += 1) {
      final placement = placements[index];
      if (placement.unit.id == focusedId) continue;
      placements[index] = placement.withoutAssets();
    }
  }

  // Second pass: the map is the bounding box of what was placed. Each node
  // contributes its own footprint, so nothing ends up half over the edge.
  var bounds =
      Rect.fromCircle(center: Offset.zero, radius: metrics.ownerRadius);
  Rect grow(Rect box, Offset point, double radius) =>
      box.expandToInclude(Rect.fromCircle(center: point, radius: radius));
  for (final placement in placements) {
    bounds = grow(bounds, placement.center, metrics.planetRadius);
    for (final moon in placement.moons.values) {
      bounds = grow(bounds, moon, metrics.moonRadius);
    }
    for (final port in placement.ports) {
      bounds = grow(bounds, port, metrics.portRadius);
    }
    for (final bead in placement.beads) {
      // A bead is a pill, wider than tall; its width is bounded by the label.
      bounds = bounds.expandToInclude(
        Rect.fromCenter(center: bead, width: 64, height: 22),
      );
    }
  }
  bounds = bounds.inflate(metrics.padding);
  final shift = -bounds.topLeft;

  final planets = <PlanetNode>[];
  for (final placement in placements) {
    final unit = placement.unit;
    final center = placement.center + shift;
    final moons = <MoonNode>[];
    for (final kind in const [MoonKind.body, MoonKind.mem, MoonKind.act]) {
      if (!placement.moons.containsKey(kind)) continue;
      final facts = moonFacts(unit, kind);
      moons.add(
        MoonNode(
          kind: kind,
          unit: unit,
          center: placement.moons[kind]! + shift,
          planetCenter: center,
          value: facts.value,
          tone: facts.tone,
          empty: facts.empty,
          unreadable: facts.unreadable,
        ),
      );
    }
    final body = moons.where((moon) => moon.kind == MoonKind.body).firstOrNull;
    final activeDeviceIds = <String>{
      for (final activity in unit.activities)
        if (isActiveActivity(activity)) ...[
          activity.originDeviceId,
          ...activity.targetDeviceIds,
        ],
    }..removeWhere((id) => id.isEmpty);

    final ports = <DevicePortNode>[];
    for (var index = 0;
        index < placement.devices.length && body != null;
        index += 1) {
      final device = placement.devices[index];
      ports.add(
        DevicePortNode(
          device: device,
          unit: unit,
          center: placement.ports[index] + shift,
          bodyCenter: body.center,
          active: activeDeviceIds.contains(device.deviceId),
        ),
      );
    }

    final beads = <ActivityBeadNode>[];
    for (var index = 0; index < placement.groups.length; index += 1) {
      final group = placement.groups[index];
      beads.add(
        ActivityBeadNode(
          activity: group.activity,
          unit: unit,
          center: placement.beads[index] + shift,
          label: group.label,
          live: isActiveActivity(group.activity),
        ),
      );
    }

    planets.add(
      PlanetNode(
        unit: unit,
        center: center,
        moons: moons,
        ports: ports,
        beads: beads,
        angle: placement.angle,
      ),
    );
  }

  return ConstellationLayout(
    metrics: metrics,
    ownerCenter: shift,
    planets: planets,
    canvas: bounds.size,
    crowded: crowded,
  );
}

/// One companion's raw geometry, before the map is centred on its own contents.
class _Placement {
  const _Placement({
    required this.unit,
    required this.center,
    required this.angle,
    required this.moons,
    required this.ports,
    required this.beads,
    required this.devices,
    required this.groups,
  });

  final CompanionUnit unit;
  final Offset center;
  final double angle;
  final Map<MoonKind, Offset> moons;
  final List<Offset> ports;
  final List<Offset> beads;
  final List<CockpitDevice> devices;
  final List<ActivityBeadGroup> groups;

  /// The same companion as a planet with nothing hanging off it.
  _Placement withoutAssets() => _Placement(
        unit: unit,
        center: center,
        angle: angle,
        moons: const <MoonKind, Offset>{},
        ports: const <Offset>[],
        beads: const <Offset>[],
        devices: const <CockpitDevice>[],
        groups: const <ActivityBeadGroup>[],
      );
}

/// What one moon says, in the two or three words it has room for.
class MoonFacts {
  const MoonFacts({
    required this.value,
    required this.tone,
    required this.empty,
    this.unreadable = false,
  });

  final String value;
  final CockpitTone tone;
  final bool empty;

  /// The lane this asset is drawn from did not read. Distinct from [empty]:
  /// "no bodies" and "could not ask about bodies" are different facts and this
  /// screen exists to keep them apart.
  final bool unreadable;
}

MoonFacts moonFacts(CompanionUnit unit, MoonKind kind) {
  switch (kind) {
    case MoonKind.body:
      if (!unit.bodiesReadable) return _unreadable;
      final total = unit.devices.length;
      if (total == 0) {
        return const MoonFacts(
          value: '未绑定',
          tone: CockpitTone.off,
          empty: true,
        );
      }
      return MoonFacts(
        value: '$total 个身体',
        tone: unit.devices.any((device) => device.online)
            ? CockpitTone.ok
            : CockpitTone.idle,
        empty: false,
      );
    case MoonKind.mem:
      final realm = unit.realm;
      if (realm == null) {
        // Nobody asked. "无空间" would be a claim about this Eidolon's memory
        // made out of a field the roster never carried.
        return const MoonFacts(
          value: '读不到',
          tone: CockpitTone.warn,
          empty: false,
        );
      }
      if (realm.isEmpty) {
        return const MoonFacts(
          value: '无空间',
          tone: CockpitTone.off,
          empty: true,
        );
      }
      final recall = unit.companion.recallHits;
      return MoonFacts(
        // The realm is known from the companion itself; only the recall count
        // comes from the turns lane, so a failure there costs the number and
        // not the whole fact.
        value: !unit.recallReadable
            ? '已配置 · 召回未知'
            : recall == null
                ? '已配置'
                : '$recall 召回',
        tone: CockpitTone.ok,
        empty: false,
      );
    case MoonKind.act:
      if (!unit.activitiesReadable) return _unreadable;
      final active = unit.activeActivity;
      if (active != null) {
        return MoonFacts(
          value: activityKindLabel(active.kind),
          tone: CockpitTone.live,
          empty: false,
        );
      }
      if (unit.activities.isEmpty) {
        return const MoonFacts(value: '空闲', tone: CockpitTone.off, empty: true);
      }
      return MoonFacts(
        value: '${unit.activities.length} 条',
        tone: unit.activities.any((item) => item.outcome == 'failure')
            ? CockpitTone.bad
            : CockpitTone.ok,
        empty: false,
      );
  }
}

/// What a moon says when its lane did not read.
const _unreadable = MoonFacts(
  value: '读不到',
  tone: CockpitTone.warn,
  empty: false,
  unreadable: true,
);

/// A companion's runtime state, in the one line its planet can hold.
class RuntimeBadge {
  const RuntimeBadge({required this.text, required this.tone});

  final String text;
  final CockpitTone tone;
}

RuntimeBadge runtimeBadge(CompanionUnit unit) {
  // Lifecycle first. An archived Companion is not idle and a retiring one is
  // not resting; showing either as 空闲 would put a Companion on its way out
  // next to a live one wearing the same words.
  final lifecycle = unit.companion.status;
  if (!isCompanionActive(lifecycle)) {
    return RuntimeBadge(
      text: companionLifecycleLabel(lifecycle),
      tone: companionLifecycleTone(lifecycle),
    );
  }
  if (!unit.activitiesReadable) {
    // "空闲" would be a claim nobody made.
    return const RuntimeBadge(text: '活动读不到', tone: CockpitTone.warn);
  }
  final activity = unit.activeActivity;
  if (activity != null) {
    if (activity.kind == 'voice_turn') {
      // The stage first, and for the same reason every other kind shows it: it
      // is the half that moves. A turn still running has no total latency to
      // report — the Host only knows one once there is an end to measure to —
      // so this branch used to read 「对话中」 and nothing else for the whole
      // length of a conversation, which is the one place on this screen where
      // something is actually happening.
      final hop = currentActivityHop(activity)?.label;
      if (hop != null && hop.isNotEmpty) {
        return RuntimeBadge(text: '对话中 · $hop', tone: CockpitTone.live);
      }
      final latency = unit.activeVoiceTurn?.latencyMs;
      return RuntimeBadge(
        text: latency == null ? '对话中' : '对话中 · ${formatLatency(latency)}',
        tone: CockpitTone.live,
      );
    }
    final hop = currentActivityHop(activity);
    return RuntimeBadge(
      text:
          '${activityKindLabel(activity.kind)} · ${hop?.label ?? activity.status}',
      tone: CockpitTone.live,
    );
  }
  if (unit.jobs.isNotEmpty) {
    return RuntimeBadge(
        text: '${unit.jobs.length} 个任务', tone: CockpitTone.warn);
  }
  return const RuntimeBadge(text: '空闲', tone: CockpitTone.idle);
}

/// The activity beads one planet shows: live ones first, then the most recent,
/// capped at three so a busy companion does not bury its own planet.
class ActivityBeadGroup {
  const ActivityBeadGroup({required this.activity, required this.label});

  final CockpitActivity activity;
  final String label;
}

List<ActivityBeadGroup> summarizeActivityBeads(
  List<CockpitActivity> activities,
  DateTime now,
) {
  final ordered = [...activities]..sort((a, b) {
      final liveA = isActiveActivity(a) ? 0 : 1;
      final liveB = isActiveActivity(b) ? 0 : 1;
      if (liveA != liveB) return liveA - liveB;
      final atA = a.updatedAt ?? a.startedAt ?? now;
      final atB = b.updatedAt ?? b.startedAt ?? now;
      return atB.compareTo(atA);
    });
  return ordered
      .take(3)
      .map(
        (activity) => ActivityBeadGroup(
          activity: activity,
          label: activityKindLabel(activity.kind),
        ),
      )
      .toList(growable: false);
}

extension _FirstOrNullMoons<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
