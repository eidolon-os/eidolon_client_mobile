import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'cockpit_theme.dart';

/// The ambient layers the cockpit sits in: a drifting starfield, soft nebulae,
/// a perspective floor grid, scanlines and a vignette.
///
/// They are cheap on purpose — three radial gradients, ~90 dots and a few dozen
/// lines per frame, all in one `CustomPaint` per layer with `isComplex` hints —
/// because on a phone the depth has to come out of a budget that also has to
/// animate the constellation on top of it. Everything reads the one clock the
/// page owns, so nothing drifts out of phase with anything else.
class StarField extends StatelessWidget {
  const StarField({super.key, required this.clock, this.seed = 20260824});

  final Animation<double> clock;
  final int seed;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: clock,
          builder: (context, child) => CustomPaint(
            painter: _StarFieldPainter(time: clock.value, seed: seed),
            isComplex: true,
            willChange: true,
            size: Size.infinite,
          ),
        ),
      );
}

class _Star {
  const _Star(this.fx, this.fy, this.r, this.z, this.tw, this.phase);

  final double fx;
  final double fy;
  final double r;
  final double z;
  final double tw;
  final double phase;
}

class _StarFieldPainter extends CustomPainter {
  _StarFieldPainter({required this.time, required this.seed});

  final double time;
  final int seed;

  static final Map<int, List<_Star>> _cache = <int, List<_Star>>{};

  List<_Star> _stars() => _cache.putIfAbsent(seed, () {
        final random = math.Random(seed);
        return List<_Star>.generate(96, (_) {
          final z = random.nextDouble();
          return _Star(
            random.nextDouble(),
            random.nextDouble(),
            0.4 + z * 1.5,
            z,
            0.4 + random.nextDouble() * 1.2,
            random.nextDouble() * math.pi * 2,
          );
        });
      });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final big = math.max(size.width, size.height);
    final nebulae = <List<double>>[
      [0.2, 0.16, big * 0.5, 0.6, 0],
      [0.84, 0.1, big * 0.44, 0.5, 1.5],
      [0.5, 0.8, big * 0.55, 0.4, 3.0],
    ];
    const hues = [Cockpit.cyan, Cockpit.magenta, Cockpit.purple];
    final blend = Paint()..blendMode = BlendMode.plus;
    for (var index = 0; index < nebulae.length; index += 1) {
      final nebula = nebulae[index];
      final cx = size.width * nebula[0] +
          math.sin(time * 0.05 * nebula[3] + nebula[4]) * 26;
      final cy = size.height * nebula[1] +
          math.cos(time * 0.04 * nebula[3] + nebula[4]) * 20;
      final radius = nebula[2];
      blend.shader = ui.Gradient.radial(
        Offset(cx, cy),
        radius,
        <Color>[
          hues[index].withValues(alpha: 0.085),
          hues[index].withValues(alpha: 0.03),
          hues[index].withValues(alpha: 0),
        ],
        const <double>[0, 0.5, 1],
      );
      canvas.drawRect(Offset.zero & size, blend);
    }

    final star = Paint();
    for (final item in _stars()) {
      final twinkle = 0.5 + 0.5 * math.sin(time * item.tw + item.phase);
      final alpha = (0.25 + 0.55 * twinkle) * (0.4 + item.z * 0.6);
      star.color = const Color(0xFFCFE8FF).withValues(alpha: alpha);
      canvas.drawCircle(
        Offset(item.fx * size.width, item.fy * size.height),
        item.r,
        star,
      );
    }
  }

  @override
  bool shouldRepaint(_StarFieldPainter old) =>
      old.time != time || old.seed != seed;
}

/// The floor grid, receding to a vanishing point and scrolling toward the
/// viewer. The console does this with a CSS 3D rotation; here the perspective is
/// computed, which is both cheaper and lets the horizon fade be exact.
class PerspectiveGrid extends StatelessWidget {
  const PerspectiveGrid({super.key, required this.clock});

  final Animation<double> clock;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: clock,
          builder: (context, child) => CustomPaint(
            painter: _GridPainter(clock.value),
            size: Size.infinite,
          ),
        ),
      );
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.time);

  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final horizon = size.height * 0.58;
    final depth = size.height - horizon;
    if (depth <= 0) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, horizon, size.width, depth));

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Verticals converge on the vanishing point; they do not move, so the eye
    // has something fixed to read the scrolling floor against.
    final vanishing = Offset(size.width / 2, horizon);
    for (var index = -7; index <= 7; index += 1) {
      final x = size.width / 2 + index * size.width * 0.26;
      paint.color = Cockpit.magenta.withValues(alpha: 0.07);
      canvas.drawLine(vanishing, Offset(x, size.height), paint);
    }

    // Horizontals: constant world spacing under a 1/z projection, phase-scrolled
    // so the floor advances at a steady rate rather than sliding linearly.
    const rows = 14;
    final phase = (time * 0.22) % 1;
    for (var index = 0; index < rows; index += 1) {
      final t = (index + phase) / rows;
      final y = horizon + depth * (t * t);
      final fade = (t * 1.5).clamp(0.0, 1.0);
      paint.color = Cockpit.cyan.withValues(alpha: 0.16 * fade);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.time != time;
}

/// Scanlines and the CRT flicker, as one layer so they cost one pass.
class ScanlineVeil extends StatelessWidget {
  const ScanlineVeil({super.key, required this.clock, this.animate = true});

  final Animation<double> clock;
  final bool animate;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: clock,
            builder: (context, child) => CustomPaint(
              painter: _ScanlinePainter(animate ? clock.value : 0),
              size: Size.infinite,
            ),
          ),
        ),
      );
}

class _ScanlinePainter extends CustomPainter {
  const _ScanlinePainter(this.time);

  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final line = Paint()..color = Colors.black.withValues(alpha: 0.16);
    for (var y = 0.0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), line);
    }
    // A 5-second flicker cycle with two brief dips, matching the console's
    // stepped keyframes. Small enough to feel like a tube, not a fault.
    final cycle = time % 5;
    final flicker = cycle > 4.85 && cycle < 4.9
        ? 0.05
        : cycle > 4.9 && cycle < 4.95
            ? 0.055
            : 0.018;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Cockpit.cyan.withValues(alpha: flicker),
    );
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.time != time;
}

/// Corner nebula glows and the edge vignette. Static: it is the frame, and a
/// frame that moves is just noise.
class CockpitVignette extends StatelessWidget {
  const CockpitVignette({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child:
            CustomPaint(painter: const _VignettePainter(), size: Size.infinite),
      );
}

class _VignettePainter extends CustomPainter {
  const _VignettePainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint();
    paint.shader = ui.Gradient.radial(
      Offset(size.width * 0.18, 0),
      size.width * 0.9,
      <Color>[
        Cockpit.magenta.withValues(alpha: 0.13),
        Cockpit.magenta.withValues(alpha: 0),
      ],
    );
    canvas.drawRect(Offset.zero & size, paint);
    paint.shader = ui.Gradient.radial(
      Offset(size.width * 0.86, size.height * 0.06),
      size.width * 0.85,
      <Color>[
        Cockpit.cyan.withValues(alpha: 0.12),
        Cockpit.cyan.withValues(alpha: 0),
      ],
    );
    canvas.drawRect(Offset.zero & size, paint);
    paint.shader = ui.Gradient.radial(
      Offset(size.width / 2, size.height / 2),
      size.longestSide * 0.62,
      <Color>[
        const Color(0x00000000),
        Colors.black.withValues(alpha: 0.55),
      ],
      const <double>[0.55, 1],
    );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_VignettePainter old) => false;
}
