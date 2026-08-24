import 'package:flutter/material.dart';

import 'cockpit_models.dart';

/// Design tokens for the constellation cockpit.
///
/// A direct translation of the console cockpit's `cockpit.tokens.css` — same
/// hues, same motion scale — so the two surfaces read as one instrument even
/// though one is drawn for a wall and this one for a hand. Nothing here is
/// re-derived per widget: a glow that drifts a shade between two components is
/// how a cockpit stops looking machined.
class Cockpit {
  const Cockpit._();

  // Core neon palette.
  static const cyan = Color(0xFF00EAFF);
  static const magenta = Color(0xFFFF2E88);
  static const yellow = Color(0xFFF7FF4A);
  static const purple = Color(0xFFA44BFF);
  static const green = Color(0xFF37F5B3);

  /// Sovereignty core — the one incandescent point (owner sun + master
  /// companion). Aliased to magenta so identity reads as one hue and yellow is
  /// left free for agent / warn.
  static const sun = magenta;

  // Surfaces & ink.
  static const bg = Color(0xFF060210);
  static const panel = Color(0xE60A0618);
  static const panelSoft = Color(0x99080418);
  static const ink = Color(0xFFD9E6FF);
  static const inkDim = Color(0xFF8B88BA);
  static const hair = Color(0x2400EAFF);
  static const hairStrong = Color(0x6600EAFF);

  // Semantic state tones.
  static const ok = green;
  static const warn = yellow;
  static const bad = magenta;
  static const idle = inkDim;

  /// One stable hue per runtime source, so a service's glow, its LED and the
  /// event row that mentions it agree.
  static const Map<String, Color> source = {
    'hub': cyan,
    'channel': Color(0xFF38BDF8),
    'agent': yellow,
    'memory': green,
    'livekit': cyan,
    'nats': purple,
    'mementos': inkDim,
    'data': inkDim,
    'admin': purple,
    'permission': magenta,
  };

  // Motion — mirrors the console's motion tokens so the two never drift.
  static const fast = Duration(milliseconds: 160);
  static const base = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 420);
  static const ambient = Duration(milliseconds: 900);

  /// One shared breath for every idle / hot node pulse, so nothing drifts out
  /// of phase against its neighbours.
  static const breath = Duration(milliseconds: 1600);

  static const easeOut = Cubic(0.16, 1, 0.3, 1);
  static const easeInOut = Cubic(0.65, 0, 0.35, 1);
  static const easeSpring = Cubic(0.34, 1.56, 0.64, 1);

  static const List<String> _monoFallback = <String>[
    'monospace',
    'Menlo',
    'Roboto Mono',
    'Courier New',
  ];

  /// Instrument type: monospaced with tabular figures, so a number that changes
  /// does not shove its neighbours sideways.
  static TextStyle mono({
    double size = 10,
    FontWeight weight = FontWeight.w700,
    Color color = ink,
    double tracking = 0.06,
    double height = 1.1,
  }) =>
      TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: _monoFallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: size * tracking,
        height: height,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle sans({
    double size = 13,
    FontWeight weight = FontWeight.w800,
    Color color = Colors.white,
    double tracking = 0,
    double height = 1.1,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: tracking,
        height: height,
      );
}

Color toneColor(CockpitTone tone) => switch (tone) {
      CockpitTone.ok => Cockpit.ok,
      CockpitTone.live => Cockpit.cyan,
      CockpitTone.warn => Cockpit.warn,
      CockpitTone.bad => Cockpit.bad,
      CockpitTone.idle => Cockpit.idle,
      CockpitTone.off => Cockpit.inkDim,
    };

/// A hairline-framed slab with the cockpit's clipped corner. Used for every
/// panel so the chrome is defined once.
class CockpitSlab extends StatelessWidget {
  const CockpitSlab({
    super.key,
    required this.child,
    this.accent = Cockpit.cyan,
    this.padding = const EdgeInsets.all(12),
    this.fill,
    this.notch = 10,
    this.borderOpacity = 0.28,
  });

  final Widget child;
  final Color accent;
  final EdgeInsets padding;
  final Color? fill;
  final double notch;
  final double borderOpacity;

  @override
  Widget build(BuildContext context) => ClipPath(
        clipper: _NotchClipper(notch),
        child: CustomPaint(
          painter: _SlabBorderPainter(
            accent.withValues(alpha: borderOpacity),
            notch,
          ),
          child: Container(
            padding: padding,
            color: fill ?? Cockpit.panelSoft,
            child: child,
          ),
        ),
      );
}

class _NotchClipper extends CustomClipper<Path> {
  const _NotchClipper(this.notch);

  final double notch;

  @override
  Path getClip(Size size) => _notchPath(size, notch);

  @override
  bool shouldReclip(_NotchClipper oldClipper) => oldClipper.notch != notch;
}

class _SlabBorderPainter extends CustomPainter {
  const _SlabBorderPainter(this.color, this.notch);

  final Color color;
  final double notch;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _notchPath(size, notch),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SlabBorderPainter old) =>
      old.color != color || old.notch != notch;
}

Path _notchPath(Size size, double notch) {
  final n = notch.clamp(0.0, size.shortestSide / 2);
  return Path()
    ..moveTo(0, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height - n)
    ..lineTo(size.width - n, size.height)
    ..lineTo(0, size.height)
    ..close();
}

/// The LED every status in this cockpit is stated with: a dot that carries its
/// own glow, so a colour never has to be read against the background alone.
class CockpitLed extends StatelessWidget {
  const CockpitLed(
      {super.key, required this.color, this.size = 8, this.glow = 1});

  final Color color;
  final double size;
  final double glow;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: glow <= 0
              ? null
              : [
                  BoxShadow(
                    color: color.withValues(alpha: 0.75 * glow),
                    blurRadius: size * 1.3 * glow,
                    spreadRadius: size * 0.1 * glow,
                  ),
                ],
        ),
      );
}
