import 'package:flutter/material.dart';

import 'eidolon_theme.dart';

/// The state vocabulary shared by every status indicator in the app, so a
/// green dot means the same thing on the host list as it does in a device
/// sheet.
enum NeonTone { accent, ok, warn, bad, idle }

Color neonToneColor(NeonTone tone) => switch (tone) {
      NeonTone.accent => Neon.cyan,
      NeonTone.ok => Neon.ok,
      NeonTone.warn => Neon.warn,
      NeonTone.bad => Neon.bad,
      NeonTone.idle => Neon.inkFaint,
    };

/// Status as a dot and one word, not a coloured sentence.
///
/// The old surfaces printed the status inline with the body copy, which meant
/// the one line a user scans for was the same size and weight as the four
/// lines they do not. A pill separates it from the prose entirely.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label,
      {super.key, this.tone = NeonTone.idle, this.busy = false, this.color});

  final String label;
  final NeonTone tone;

  /// Hollow dot for work in flight, solid for a settled state.
  final bool busy;

  /// Overrides the tone's colour where the caller already resolved one.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? neonToneColor(tone);
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: busy ? Colors.transparent : color,
              border: busy ? Border.all(color: color, width: 1.5) : null,
              boxShadow: busy ? null : Neon.glow(color, blur: 6, alpha: .8),
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
              child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: .2,
              height: 1.2,
            ),
          )),
        ],
      ),
    );
  }
}

/// A rounded, lit glyph tile. Replaces the flat circle avatars that made every
/// list row look like a contacts app.
class GlyphBadge extends StatelessWidget {
  const GlyphBadge(this.icon,
      {super.key, this.color = Neon.cyan, this.size = 44});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .32),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: .22),
              color.withValues(alpha: .05)
            ],
          ),
          border: Border.all(color: color.withValues(alpha: .32)),
          boxShadow: Neon.glow(color, blur: 16, alpha: .16),
        ),
        child: Icon(icon, color: color, size: size * .46),
      );
}

/// A panel with a lit top edge.
///
/// Cards used to be a flat fill with a uniform border, which reads as a box.
/// One bright hairline along the top edge is enough to suggest a light source
/// and give a stack of panels depth without any of them casting a shadow over
/// the backdrop.
class NeonPanel extends StatelessWidget {
  const NeonPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Neon.s5),
    this.accent,
    this.onTap,
    this.glow = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Tints the top hairline and the border. Null keeps the neutral panel.
  final Color? accent;
  final VoidCallback? onTap;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? Neon.cyan;
    final radius = BorderRadius.circular(Neon.radiusL);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: Neon.panelGradient,
        border: Border.all(
            color: accent == null ? Neon.hair : tint.withValues(alpha: .24)),
        boxShadow: glow ? Neon.glow(tint, blur: 36, alpha: .14) : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 1,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      Colors.transparent,
                      tint.withValues(alpha: accent == null ? .34 : .6),
                      Colors.transparent,
                    ]),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Eyebrow, title and an optional glyph — the one heading shape used by every
/// panel, so sections are recognisable before they are read.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.eyebrow,
    this.icon,
    this.trailing,
    this.color = Neon.cyan,
  });

  final String title;
  final String? eyebrow;
  final IconData? icon;
  final Widget? trailing;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = eyebrow;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          GlyphBadge(icon!, color: color, size: 38),
          const SizedBox(width: Neon.s3),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null) ...[
                NeonEyebrow(label, color: color),
                const SizedBox(height: 5),
              ],
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontSize: 17)),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Neon.s3), trailing!],
      ],
    );
  }
}

/// Technical values, set as an instrument readout: monospaced, dimmer than
/// prose, and gathered behind one accent rule so the eye can skip the whole
/// block when it is looking for something else.
class MetaReadout extends StatelessWidget {
  const MetaReadout(this.lines, {super.key, this.color = Neon.inkDim});

  final List<String> lines;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.only(left: Neon.s3),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Neon.hairStrong, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Text(line, style: Neon.mono(size: 12, color: color)),
        ],
      ),
    );
  }
}

/// Puts a coloured bloom under a primary action.
///
/// Material's own elevation cannot do this: the gradient lozenge is painted by
/// the button's background builder, and an elevation shadow needs an opaque
/// Material colour underneath it to cast from.
class NeonCta extends StatelessWidget {
  const NeonCta(
      {super.key,
      required this.child,
      this.color = Neon.cyan,
      this.enabled = true});

  final Widget child;
  final Color color;
  final bool enabled;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Neon.radiusS + 2),
          boxShadow: enabled ? Neon.glow(color, blur: 28, alpha: .30) : null,
        ),
        child: child,
      );
}

/// A row of selectable pills.
///
/// Stock [ChoiceChip]s are sized for a filter bar: small text, tight padding,
/// and a selected state that differs from the unselected one by a barely
/// visible tint. These are touch-sized, and the selected pill is lit.
class NeonChoice extends StatelessWidget {
  const NeonChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = selected ? Neon.cyan : Neon.inkDim;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: selected
            ? Neon.cyan.withValues(alpha: .13)
            : Colors.white.withValues(alpha: .035),
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(99),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                  color:
                      selected ? Neon.cyan.withValues(alpha: .55) : Neon.hair),
              boxShadow:
                  selected ? Neon.glow(Neon.cyan, blur: 14, alpha: .18) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: enabled ? color : Neon.inkFaint),
                  const SizedBox(width: 7),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .1,
                    color: enabled
                        ? (selected ? Neon.cyanSoft : Neon.inkDim)
                        : Neon.inkFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
