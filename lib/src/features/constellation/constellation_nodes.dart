import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';
import 'constellation_geometry.dart';
import 'constellation_painter.dart' show dashPath;

/// The touchable bodies of the constellation.
///
/// Nodes are widgets, not paint: on a phone every one of them is a target, and
/// a canvas-drawn circle has no target, no semantics and no ink. Sizes are in
/// the canvas's own coordinates and the whole stage is scaled by the viewer, so
/// a node is defined once and stays crisp at any zoom.
///
/// `detail` is the zoom the stage is currently at. Text that would be unreadable
/// at the overview zoom is not drawn small — it is not drawn. A label rendered
/// at four pixels is worse than an honest glyph.

/// Legibility thresholds. Below the first, nodes are shapes and colour; above
/// the second, they carry their full label set.
const double kDetailValue = 0.62;
const double kDetailLabel = 0.8;

/// Node interiors are fixed-geometry instruments, so their contents are fitted
/// rather than allowed to push past the rim. Between this and the clamped text
/// scaling the stage applies, a reader who has set a large system font gets a
/// map that still draws — and the honest way to read it larger is the zoom this
/// screen already has.
class _NodeContent extends StatelessWidget {
  const _NodeContent({required this.diameter, required this.child});

  final double diameter;
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(diameter * 0.08),
          child: FittedBox(fit: BoxFit.scaleDown, child: child),
        ),
      );
}

class OwnerCore extends StatelessWidget {
  const OwnerCore({
    super.key,
    required this.name,
    required this.companionCount,
    required this.companionsReadable,
    required this.clock,
    required this.pipelineActive,
    required this.igniting,
    required this.animate,
    required this.onTap,
    this.diameter = 132,
  });

  final String name;
  final int companionCount;

  /// False when the companions lane did not read. "0 位伙伴" would then be a
  /// claim nobody made — the core says the count is unknown instead.
  final bool companionsReadable;
  final Animation<double> clock;
  final bool pipelineActive;

  /// One flare when a turn takes the pipeline idle → live. The core does not
  /// blink continuously to say "something happened"; it fires once, then settles.
  final bool igniting;
  final bool animate;
  final VoidCallback onTap;
  final double diameter;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '主人 $name，$companionCount 位伙伴',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedBuilder(
            animation: clock,
            builder: (context, child) {
              final breath = animate
                  ? 0.5 + 0.5 * math.sin(clock.value * (2 * math.pi / 5))
                  : 0.5;
              final swell = pipelineActive ? 0.18 : 0.0;
              return Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Cockpit.magenta.withValues(alpha: 0.6),
                    width: 2,
                  ),
                  // The radius is half the box on purpose: a wider gradient
                  // never reaches its dark stop inside the circle, and the core
                  // becomes one flat bright disc with unreadable text on it.
                  gradient: RadialGradient(
                    center: const Alignment(-0.16, -0.32),
                    radius: 0.62,
                    colors: <Color>[
                      Colors.white.withValues(alpha: 0.34),
                      Cockpit.magenta.withValues(alpha: 0.34),
                      Cockpit.purple.withValues(alpha: 0.3),
                      const Color(0xFF0A0618).withValues(alpha: 0.96),
                    ],
                    stops: const <double>[0, 0.34, 0.6, 0.94],
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color:
                          Colors.white.withValues(alpha: 0.38 + 0.12 * breath),
                      blurRadius: 14 + 6 * breath,
                    ),
                    BoxShadow(
                      color: Cockpit.magenta
                          .withValues(alpha: 0.44 + 0.16 * breath + swell),
                      blurRadius: 42 + 18 * breath,
                    ),
                    BoxShadow(
                      color:
                          Cockpit.purple.withValues(alpha: 0.22 + 0.1 * breath),
                      blurRadius: 96 + 34 * breath,
                    ),
                  ],
                ),
                child: child,
              );
            },
            child: AnimatedScale(
              scale: igniting ? 1.09 : 1,
              duration: igniting ? Cockpit.fast : Cockpit.slow,
              curve: Cockpit.easeOut,
              child: _NodeContent(
                diameter: diameter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'OWNER · 主人',
                      style: Cockpit.mono(
                        size: 8.5,
                        color: Colors.white.withValues(alpha: 0.82),
                        tracking: 0.14,
                      ),
                    ),
                    const SizedBox(height: 5),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: diameter - 26),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Cockpit.sans(size: 20).copyWith(
                          shadows: <Shadow>[
                            Shadow(
                              color: Cockpit.magenta.withValues(alpha: 0.6),
                              blurRadius: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      companionsReadable ? '$companionCount 位伙伴' : '伙伴读不到',
                      style: Cockpit.mono(
                        size: 9,
                        weight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.66),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class CompanionPlanet extends StatelessWidget {
  const CompanionPlanet({
    super.key,
    required this.planet,
    required this.clock,
    required this.focused,
    required this.dimmed,
    required this.animate,
    required this.detail,
    required this.onTap,
    this.diameter = 96,
  });

  final PlanetNode planet;
  final Animation<double> clock;
  final bool focused;

  /// Another companion holds the focus. Siblings recede rather than disappear:
  /// the domain is still the domain.
  final bool dimmed;
  final bool animate;
  final double detail;
  final VoidCallback onTap;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final unit = planet.unit;
    final badge = runtimeBadge(unit);
    final primary = unit.isPrimary;
    final accent = primary ? Cockpit.sun : Cockpit.cyan;
    final showBadge = detail >= kDetailValue;

    return Semantics(
      button: true,
      selected: focused,
      label: '伙伴 ${unit.name}，${badge.text}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: dimmed ? 0.32 : 1,
          duration: Cockpit.base,
          curve: Cockpit.easeOut,
          child: AnimatedScale(
            scale: focused ? 1.12 : 1,
            duration: Cockpit.base,
            curve: Cockpit.easeSpring,
            child: _NodePulse(
              clock: clock,
              active: animate && planet.active,
              color: accent,
              baseBlur: focused ? 44 : 24,
              child: Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accent,
                    width: focused ? 2 : 1.5,
                  ),
                  gradient: RadialGradient(
                    center: const Alignment(-0.2, -0.32),
                    radius: 0.62,
                    colors: <Color>[
                      accent.withValues(alpha: 0.26),
                      const Color(0xFF080514).withValues(alpha: 0.96),
                    ],
                    stops: const <double>[0, 0.9],
                  ),
                ),
                child: _NodeContent(
                  diameter: diameter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CockpitLed(
                        // Lifecycle has its own four-value vocabulary; the
                        // generic status mapping collapsed three of them to one
                        // grey.
                        color: toneColor(
                          companionLifecycleTone(unit.companion.status),
                        ),
                        size: 7,
                      ),
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: diameter - 16),
                        child: Text(
                          primary ? '★ ${unit.name}' : unit.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Cockpit.sans(size: 15, height: 1.05),
                        ),
                      ),
                      if (showBadge) ...[
                        const SizedBox(height: 4),
                        _BadgePill(text: badge.text, tone: badge.tone),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({required this.text, required this.tone});

  final String text;
  final CockpitTone tone;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(tone);
    return Container(
      constraints: const BoxConstraints(maxWidth: 92),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: tone == CockpitTone.idle ? 0.06 : 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Cockpit.mono(size: 8.5, color: color, height: 1.35),
      ),
    );
  }
}

class AssetMoon extends StatelessWidget {
  const AssetMoon({
    super.key,
    required this.moon,
    required this.clock,
    required this.selected,
    required this.dimmed,
    required this.stageHere,
    required this.animate,
    required this.detail,
    required this.onTap,
    this.diameter = 62,
  });

  final MoonNode moon;
  final Animation<double> clock;
  final bool selected;
  final bool dimmed;

  /// The signal is at this asset right now. The moon rings in step with the rest
  /// of the screen, so the constellation, the deck and the route agree about
  /// where the moment is.
  final bool stageHere;
  final bool animate;
  final double detail;
  final VoidCallback onTap;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final accent = switch (moon.kind) {
      MoonKind.body => Cockpit.cyan,
      MoonKind.mem => Cockpit.yellow,
      MoonKind.act => Cockpit.magenta,
    };
    final off = moon.tone == CockpitTone.off;
    final color = off ? Cockpit.inkDim : accent;
    final showValue = detail >= kDetailValue;
    final showLabel = detail >= kDetailLabel;

    return Semantics(
      button: true,
      label: '${moon.unit.name} 的${moonLabel(moon.kind)}：${moon.value}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: dimmed ? 0.2 : (off ? 0.66 : 1),
          duration: Cockpit.base,
          curve: Cockpit.easeOut,
          child: AnimatedScale(
            scale: selected ? 1.14 : 1,
            duration: Cockpit.base,
            curve: Cockpit.easeSpring,
            child: _NodePulse(
              clock: clock,
              active: animate && (stageHere || moon.tone == CockpitTone.live),
              color: color,
              baseBlur: moon.tone == CockpitTone.bad ? 22 : 0,
              // An asset that does not exist yet gets a dashed rim, not a
              // dimmer solid one: "not opened" and "opened but quiet" must not
              // be the same drawing.
              child: CustomPaint(
                foregroundPainter: off
                    ? _DashedRingPainter(color.withValues(alpha: 0.7))
                    : null,
                child: Container(
                  width: diameter,
                  height: diameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: off
                        ? null
                        : Border.all(
                            color: color,
                            width: selected ? 2 : (stageHere ? 1.5 : 1),
                          ),
                    gradient: RadialGradient(
                      center: const Alignment(-0.16, -0.28),
                      radius: 0.92,
                      colors: <Color>[
                        color.withValues(alpha: off ? 0.05 : 0.16),
                        const Color(0xFF080514).withValues(alpha: 0.95),
                      ],
                      stops: const <double>[0, 0.7],
                    ),
                  ),
                  child: _NodeContent(
                    diameter: diameter,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          moonGlyph(moon.kind),
                          style: TextStyle(
                            fontSize: 16,
                            height: 1,
                            color: color,
                            // Tightened after reading it on glass: a wider halo
                            // washed over the label a couple of pixels below.
                            shadows: <Shadow>[
                              Shadow(
                                  color: color.withValues(alpha: 0.7),
                                  blurRadius: 6),
                            ],
                          ),
                        ),
                        if (showLabel) ...[
                          const SizedBox(height: 3.5),
                          Text(
                            moonLabel(moon.kind),
                            style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
                          ),
                        ],
                        if (showValue) ...[
                          const SizedBox(height: 1),
                          ConstrainedBox(
                            constraints:
                                BoxConstraints(maxWidth: diameter - 12),
                            child: Text(
                              moon.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Cockpit.sans(
                                size: 10.5,
                                color: off
                                    ? Cockpit.inkDim
                                    : const Color(0xFFEAF6FF),
                                height: 1.05,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rim of an asset that has not been opened yet.
class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Path()
      ..addOval(
        Rect.fromCircle(
          center: size.center(Offset.zero),
          radius: size.shortestSide / 2 - 0.5,
        ),
      );
    canvas.drawPath(
      dashPath(ring, const [4, 4]),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}

class DevicePortDot extends StatelessWidget {
  const DevicePortDot({
    super.key,
    required this.port,
    required this.clock,
    required this.dimmed,
    required this.animate,
    required this.onTap,
    this.diameter = 26,
  });

  final DevicePortNode port;
  final Animation<double> clock;
  final bool dimmed;
  final bool animate;
  final VoidCallback onTap;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final device = port.device;
    final color = port.active
        ? Cockpit.cyan
        : device.online
            ? Cockpit.green
            : Cockpit.inkDim;
    return Semantics(
      button: true,
      label: '${deviceShortName(device)} · ${devicePresenceLabel(device)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: dimmed ? 0.34 : 1,
          duration: Cockpit.base,
          child: _NodePulse(
            clock: clock,
            active: animate && port.active,
            color: color,
            child: Container(
              width: diameter,
              height: diameter,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF080514).withValues(alpha: 0.94),
                border: Border.all(color: color.withValues(alpha: 0.85)),
              ),
              child: Text(
                device.online ? '●' : '○',
                style: TextStyle(fontSize: 8, height: 1, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ActivityBead extends StatelessWidget {
  const ActivityBead({
    super.key,
    required this.bead,
    required this.clock,
    required this.dimmed,
    required this.animate,
    required this.onTap,
  });

  final ActivityBeadNode bead;
  final Animation<double> clock;
  final bool dimmed;
  final bool animate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = bead.live
        ? CockpitTone.live
        : bead.activity.outcome == 'failure'
            ? CockpitTone.bad
            : bead.activity.outcome == 'denied'
                ? CockpitTone.warn
                : CockpitTone.ok;
    final color = toneColor(tone);
    return Semantics(
      button: true,
      label:
          '${activityKindLabel(bead.activity.kind)} · ${activityStatusLabel(bead.activity.status)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: dimmed ? 0.3 : 1,
          duration: Cockpit.base,
          child: _NodePulse(
            clock: clock,
            active: animate && bead.live,
            color: color,
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF080514).withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: color.withValues(alpha: 0.85)),
              ),
              child: Text(
                bead.label,
                style: Cockpit.mono(size: 9, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared breath. Every pulsing node in the cockpit rides this one cycle, so
/// a screenful of them reads as one instrument rather than as several clocks.
class _NodePulse extends StatelessWidget {
  const _NodePulse({
    required this.clock,
    required this.active,
    required this.color,
    required this.child,
    this.baseBlur = 0,
  });

  final Animation<double> clock;
  final bool active;
  final Color color;
  final Widget child;
  final double baseBlur;

  @override
  Widget build(BuildContext context) {
    if (!active) {
      if (baseBlur <= 0) return child;
      return DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: baseBlur,
            ),
          ],
        ),
        child: child,
      );
    }
    return AnimatedBuilder(
      animation: clock,
      builder: (context, inner) {
        final breath = 0.5 +
            0.5 *
                math.sin(
                  clock.value *
                      (2 * math.pi / (Cockpit.breath.inMilliseconds / 1000)),
                );
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: color.withValues(alpha: 0.4 + 0.3 * breath),
                blurRadius: math.max(baseBlur, 16) + 14 * breath,
              ),
            ],
          ),
          child: inner,
        );
      },
      child: child,
    );
  }
}
