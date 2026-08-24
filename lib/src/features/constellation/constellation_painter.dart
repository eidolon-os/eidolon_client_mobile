import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';
import 'constellation_geometry.dart';

/// Everything between the nodes: the orbit rings, the ownership wires, the asset
/// legs, the body links, and the light that travels along them.
///
/// Wires are painted and nodes are widgets. That split is deliberate — the wires
/// are one repainting layer with no hit-testing, and the nodes need real touch
/// targets, focus and semantics. Drawing the nodes into the canvas too would
/// have been fewer objects and a worse screen.

/// A companion's internal circulation: one closed loop threading
/// body → brain → activity → brain → memory → brain → body, so a dot animating
/// along it returns to where it began with no teleport.
class FlowLoop {
  const FlowLoop({
    required this.companionId,
    required this.path,
    required this.periodSeconds,
  });

  final String companionId;
  final ui.Path path;

  /// Held at roughly constant speed regardless of how many legs are lit, so a
  /// companion with one body does not look calmer than one with three.
  final double periodSeconds;
}

/// One directed dart in flight along a single leg.
class LivePulse {
  const LivePulse({
    required this.pulse,
    required this.path,
    required this.progress,
  });

  final CockpitPulse pulse;
  final ui.Path path;

  /// 0..1 across the leg.
  final double progress;
}

/// The wire geometry, dashed once per snapshot instead of once per frame.
///
/// Dashing is done by walking a path's metrics and extracting segments, which is
/// the most expensive thing this screen does. The legs and body links only move
/// when the domain changes, so they are built here — in the stage's build, not
/// the painter's paint — and the per-frame painter only re-dashes the handful of
/// wires whose dash pattern actually travels.
class WireGeometry {
  WireGeometry({required this.layout, required Set<String> litLegs}) {
    for (final planet in layout.planets) {
      owner[planet.unit.id] = ui.Path()
        ..moveTo(layout.ownerCenter.dx, layout.ownerCenter.dy)
        ..lineTo(planet.center.dx, planet.center.dy);
      for (final moon in planet.moons) {
        final line = ui.Path()
          ..moveTo(planet.center.dx, planet.center.dy)
          ..lineTo(moon.center.dx, moon.center.dy);
        leg[moon.key] = line;
        if (!litLegs.contains(moon.key)) {
          legDash[moon.key] = dashPath(line, const [3, 3]);
        }
      }
      for (final port in planet.ports) {
        final line = ui.Path()
          ..moveTo(port.bodyCenter.dx, port.bodyCenter.dy)
          ..lineTo(port.center.dx, port.center.dy);
        portLine[port.device.deviceId] = line;
        portDash[port.device.deviceId] = dashPath(line, const [2, 3]);
      }
    }
  }

  final ConstellationLayout layout;
  final Map<String, ui.Path> owner = <String, ui.Path>{};
  final Map<String, ui.Path> leg = <String, ui.Path>{};
  final Map<String, ui.Path> legDash = <String, ui.Path>{};
  final Map<String, ui.Path> portLine = <String, ui.Path>{};
  final Map<String, ui.Path> portDash = <String, ui.Path>{};
}

class ConstellationWirePainter extends CustomPainter {
  const ConstellationWirePainter({
    required this.wires,
    required this.time,
    required this.flows,
    required this.pulses,
    required this.legBrightness,
    required this.pipelineActive,
    required this.focusedId,
    required this.animate,
    this.highlight,
  });

  final WireGeometry wires;

  /// Seconds since the cockpit opened. The single clock everything reads.
  final double time;
  final List<FlowLoop> flows;
  final List<LivePulse> pulses;

  /// `companionId:kind` → 0..1 for legs currently carrying signal.
  final Map<String, double> legBrightness;
  final bool pipelineActive;
  final String focusedId;
  final bool animate;

  /// The leg path of an event the reader is pointing at, drawn as a lit dash.
  final ui.Path? highlight;

  ConstellationLayout get layout => wires.layout;

  @override
  void paint(Canvas canvas, Size size) {
    final center = layout.ownerCenter;
    _paintOrbits(canvas, center);
    _paintOwnershipWires(canvas);
    _paintAssetLegs(canvas);
    _paintBodyLinks(canvas);
    _paintSunGlow(canvas, center);
    _paintHighlight(canvas);
    _paintFlows(canvas);
    _paintPulses(canvas);
  }

  void _paintOrbits(Canvas canvas, Offset center) {
    final metrics = layout.metrics;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // The companion orbit, turning slowly enough that you notice it only if you
    // stay.
    final orbit = ui.Path()
      ..addOval(
        Rect.fromCenter(
          center: center,
          width: metrics.orbitRadiusX * 2,
          height: metrics.orbitRadiusY * 2,
        ),
      );
    stroke.color = Cockpit.cyan.withValues(alpha: 0.2);
    canvas.drawPath(
      dashPath(orbit, const [3, 6], phase: animate ? time * 4 : 0),
      stroke,
    );

    // Two counter-rotating rings around the core, the console's own signature.
    for (final ring in const [
      [96.0, 28.0, 4.0, 6.0],
      [122.0, -40.0, 2.0, 10.0],
    ]) {
      final radius = ring[0];
      final period = ring[1];
      final angle = animate ? (time / period) * 2 * math.pi : 0.0;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      final path = ui.Path()
        ..addOval(Rect.fromCircle(center: Offset.zero, radius: radius));
      stroke.color = radius > 110
          ? Cockpit.purple.withValues(alpha: 0.22)
          : Cockpit.cyan.withValues(alpha: 0.24);
      canvas.drawPath(dashPath(path, [ring[2], ring[3]]), stroke);
      canvas.restore();
    }
  }

  void _paintOwnershipWires(Canvas canvas) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final planet in layout.planets) {
      final hot = planet.active;
      final selected = planet.unit.id == focusedId;
      final path = wires.owner[planet.unit.id]!;
      stroke
        ..strokeWidth = hot || selected ? 1.7 : 1.2
        ..color = selected
            ? Cockpit.cyan.withValues(alpha: 0.8)
            : Cockpit.purple.withValues(alpha: hot ? 0.85 : 0.58);
      if (hot || selected) {
        stroke.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2);
        canvas.drawPath(
            dashPath(path, const [3, 6], phase: animate ? -time * 14 : 0),
            stroke);
        stroke.maskFilter = null;
      }
      canvas.drawPath(
        dashPath(path, const [3, 6], phase: animate ? -time * 14 : 0),
        stroke,
      );
    }
  }

  void _paintAssetLegs(Canvas canvas) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15;
    for (final planet in layout.planets) {
      for (final moon in planet.moons) {
        final path = wires.leg[moon.key]!;
        final bright = legBrightness[moon.key];
        final hue = _legColor(moon.kind);
        if (bright != null) {
          // A lit leg reads as an energised conduit: solid, brighter, glowing —
          // not the same dashed hairline with more opacity.
          stroke
            ..color = hue.withValues(alpha: 0.55 + 0.35 * bright)
            ..strokeWidth = 1.35
            ..maskFilter =
                MaskFilter.blur(BlurStyle.normal, 1.4 + 1.6 * bright);
          canvas.drawPath(path, stroke);
          stroke.maskFilter = null;
          canvas.drawPath(path, stroke);
          continue;
        }
        stroke
          ..maskFilter = null
          ..strokeWidth = 1.15
          ..color = moon.empty
              ? const Color(0xFF6D6A99).withValues(alpha: 0.3)
              : hue.withValues(alpha: planet.unit.id == focusedId ? 0.75 : 0.5);
        canvas.drawPath(wires.legDash[moon.key] ?? path, stroke);
      }
    }
  }

  void _paintBodyLinks(Canvas canvas) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    for (final port in layout.ports) {
      final path = wires.portLine[port.device.deviceId]!;
      if (port.active) {
        stroke
          ..color = Cockpit.cyan
          ..strokeWidth = 1.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
        canvas.drawPath(path, stroke);
        stroke.maskFilter = null;
        canvas.drawPath(path, stroke);
        continue;
      }
      stroke
        ..maskFilter = null
        ..strokeWidth = 0.9
        ..color = port.device.online
            ? Cockpit.cyan.withValues(alpha: 0.42)
            : const Color(0xFF6D6A99).withValues(alpha: 0.34);
      canvas.drawPath(wires.portDash[port.device.deviceId]!, stroke);
    }
  }

  void _paintSunGlow(Canvas canvas, Offset center) {
    // The sovereign core's corona. Breathes on the shared 5s cycle and swells a
    // little while the pipeline is live.
    // Sized against the orbit, not in absolute pixels: a corona wide enough to
    // reach the planets would erase every ownership wire on the way, and the
    // wires are the point.
    final breath =
        animate ? 0.5 + 0.5 * math.sin(time * (2 * math.pi / 5)) : 0.5;
    final reach =
        math.min(layout.metrics.orbitRadiusX, layout.metrics.orbitRadiusY);
    final radius = reach * 0.58 + (pipelineActive ? 10 : 0) + breath * 8;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(center.dx, center.dy - radius * 0.08),
          radius,
          <Color>[
            Colors.white.withValues(alpha: 0.30 + 0.08 * breath),
            Cockpit.magenta.withValues(alpha: 0.34 + 0.1 * breath),
            Cockpit.purple.withValues(alpha: 0.20),
            Cockpit.purple.withValues(alpha: 0),
          ],
          const <double>[0, 0.34, 0.7, 1],
        ),
    );
  }

  void _paintHighlight(Canvas canvas) {
    final path = highlight;
    if (path == null) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.85)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawPath(
      dashPath(path, const [8, 5], phase: animate ? -time * 40 : 0),
      stroke,
    );
  }

  void _paintFlows(Canvas canvas) {
    if (!animate) return;
    final dot = Paint()..color = const Color(0xFFEAFCFF);
    final halo = Paint()
      ..color = Cockpit.cyan.withValues(alpha: 0.55)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    for (final flow in flows) {
      final metrics = flow.path.computeMetrics().toList(growable: false);
      if (metrics.isEmpty) continue;
      final total = metrics.fold<double>(0, (sum, item) => sum + item.length);
      if (total <= 0) continue;
      // Two dots half a loop apart, so the circuit reads as circulating rather
      // than as one dot being fired repeatedly.
      for (final offset in const [0.0, 0.5]) {
        final t = ((time / flow.periodSeconds) + offset) % 1;
        final point = _pointAt(metrics, total * t);
        if (point == null) continue;
        canvas.drawCircle(point, 4.6, halo);
        canvas.drawCircle(point, 2.6, dot);
      }
    }
  }

  void _paintPulses(Canvas canvas) {
    // Under reduced motion the travelling darts are not slowed, they are gone:
    // a dart frozen mid-leg reads as a fault rather than as a signal. The lit
    // legs stay lit, which is the motion-free version of the same fact.
    if (!animate) return;
    for (final live in pulses) {
      final metrics = live.path.computeMetrics().toList(growable: false);
      if (metrics.isEmpty) continue;
      final total = metrics.fold<double>(0, (sum, item) => sum + item.length);
      if (total <= 0) continue;
      final progress = live.progress.clamp(0.0, 1.0);
      final head = _pointAt(metrics, total * progress);
      if (head == null) continue;
      final color = _pulseColor(live.pulse);
      // A short comet tail: the dart's own recent path, so direction is legible
      // from a still frame as well as from motion.
      final tailStart = math.max(0.0, progress - 0.16);
      final tail = ui.Path();
      var first = true;
      for (var t = tailStart; t <= progress; t += 0.02) {
        final point = _pointAt(metrics, total * t);
        if (point == null) continue;
        if (first) {
          tail.moveTo(point.dx, point.dy);
          first = false;
        } else {
          tail.lineTo(point.dx, point.dy);
        }
      }
      final fade = 1 - (progress - 0.7).clamp(0.0, 0.3) / 0.3;
      canvas.drawPath(
        tail,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.5 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
      );
      canvas.drawCircle(
        head,
        6.4,
        Paint()
          ..color = color.withValues(alpha: 0.55 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawCircle(
          head, 3.4, Paint()..color = color.withValues(alpha: fade));
    }
  }

  static Offset? _pointAt(List<ui.PathMetric> metrics, double distance) {
    var remaining = distance;
    for (final metric in metrics) {
      if (remaining <= metric.length) {
        return metric.getTangentForOffset(remaining)?.position;
      }
      remaining -= metric.length;
    }
    return metrics.last.getTangentForOffset(metrics.last.length)?.position;
  }

  @override
  bool shouldRepaint(ConstellationWirePainter old) =>
      old.time != time ||
      old.wires != wires ||
      old.pulses != pulses ||
      old.flows != flows ||
      old.legBrightness != legBrightness ||
      old.focusedId != focusedId ||
      old.pipelineActive != pipelineActive ||
      old.highlight != highlight ||
      old.animate != animate;
}

Color _legColor(MoonKind kind) => switch (kind) {
      MoonKind.body => Cockpit.cyan,
      MoonKind.mem => Cockpit.yellow,
      MoonKind.act => Cockpit.magenta,
    };

/// A normal dart takes its leg's hue; warn and bad override to the alarm
/// palette, so a failure reads at a glance no matter which leg it is on.
Color _pulseColor(CockpitPulse pulse) => switch (pulse.tone) {
      PulseTone.normal => switch (pulse.leg) {
          MoonKind.body => const Color(0xFF9FF0FF),
          MoonKind.mem => const Color(0xFFFBFF9F),
          MoonKind.act => const Color(0xFFFF8AC8),
        },
      PulseTone.warn => Cockpit.yellow,
      PulseTone.bad => Cockpit.magenta,
    };

/// Dash a path by walking its metrics. Flutter has no dashed stroke, and doing
/// it here (rather than faking it with an image shader) keeps dashes crisp under
/// the pinch-zoom this screen is built around.
ui.Path dashPath(ui.Path source, List<double> pattern, {double phase = 0}) {
  if (pattern.isEmpty) return source;
  final result = ui.Path();
  final cycle = pattern.reduce((a, b) => a + b);
  if (cycle <= 0) return source;
  for (final metric in source.computeMetrics()) {
    var distance = -(phase % cycle);
    var index = 0;
    var draw = true;
    while (distance < metric.length) {
      final length = pattern[index % pattern.length];
      final end = distance + length;
      if (draw && end > 0) {
        result.addPath(
          metric.extractPath(
              math.max(0, distance), math.min(end, metric.length)),
          Offset.zero,
        );
      }
      distance = end;
      index += 1;
      draw = !draw;
    }
  }
  return result;
}

/// The closed circulation loop for one companion's lit legs.
ui.Path? buildFlowPath(PlanetNode planet, FlowLegs legs) {
  final ordered = <MoonNode>[];
  for (final entry in <(bool, MoonKind)>[
    (legs.body, MoonKind.body),
    (legs.act, MoonKind.act),
    (legs.mem, MoonKind.mem),
  ]) {
    if (!entry.$1) continue;
    final moon = planet.moon(entry.$2);
    if (moon != null) ordered.add(moon);
  }
  if (ordered.isEmpty) return null;
  final path = ui.Path()
    ..moveTo(ordered.first.center.dx, ordered.first.center.dy);
  for (var index = 1; index < ordered.length; index += 1) {
    path
      ..lineTo(planet.center.dx, planet.center.dy)
      ..lineTo(ordered[index].center.dx, ordered[index].center.dy);
  }
  path
    ..lineTo(planet.center.dx, planet.center.dy)
    ..lineTo(ordered.first.center.dx, ordered.first.center.dy);
  return path;
}

/// How many legs a loop has, which is what sets its period.
int flowSegments(FlowLegs legs) {
  final lit = (legs.body ? 1 : 0) + (legs.mem ? 1 : 0) + (legs.act ? 1 : 0);
  return lit <= 1 ? 2 : lit * 2;
}

/// A dart's path: inward travels moon → brain, outward brain → moon. When the
/// event named a body, the path extends to that body's own port, so "which
/// device" is answered by where the light starts.
ui.Path buildPulsePath({
  required PlanetNode planet,
  required MoonNode moon,
  required PulseDirection direction,
  DevicePortNode? port,
}) {
  final stops = <Offset>[
    if (port != null) port.center,
    moon.center,
    planet.center,
  ];
  final ordered =
      direction == PulseDirection.inward ? stops : stops.reversed.toList();
  final path = ui.Path()..moveTo(ordered.first.dx, ordered.first.dy);
  for (final point in ordered.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  return path;
}
