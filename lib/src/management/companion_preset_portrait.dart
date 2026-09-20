import 'package:flutter/material.dart';

import '../theme/eidolon_theme.dart';

/// Presentation-only artwork. IDs select a region of the unchanged website
/// illustration; names and personality still come from the Host catalogue.
/// This is not a Companion face upload or a device expression resource.
class CompanionPresetPortrait extends StatelessWidget {
  const CompanionPresetPortrait({
    super.key,
    required this.presetId,
    required this.name,
    this.size = 88,
  });

  final String presetId;
  final String name;
  final double size;

  static const asset = 'assets/companions/five-companions.png';
  static const _imageSize = Size(1942, 809);
  static const _portraits = {
    'metal': Rect.fromLTWH(70, 255, 310, 310),
    'wood': Rect.fromLTWH(418, 90, 340, 340),
    'water': Rect.fromLTWH(750, 240, 350, 350),
    'fire': Rect.fromLTWH(1100, 170, 385, 385),
    'earth': Rect.fromLTWH(1525, 75, 400, 400),
  };

  /// One stable hue per Companion, so the same initial is the same colour
  /// everywhere it appears. Derived from the name rather than stored: this is
  /// presentation, and the Host has no opinion about it.
  static const _tints = [
    Neon.cyan,
    Neon.indigo,
    Neon.purple,
    Neon.magenta,
    Neon.ok,
  ];

  Color get _tint => _tints[name.hashCode.abs() % _tints.length];

  @override
  Widget build(BuildContext context) {
    final crop = _portraits[presetId];
    final fallback = Center(
      child: Text(name.characters.firstOrNull ?? '·',
          style: Theme.of(context).textTheme.headlineSmall),
    );
    // A bare letter on a flat grey square read as a placeholder nobody had
    // finished. Tinted and lettered properly, an Eidolon without artwork still
    // looks like somebody.
    final lettered = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _tint.withValues(alpha: .34),
            _tint.withValues(alpha: .10),
          ],
        ),
      ),
      child: Center(
        child: Text(name.characters.firstOrNull ?? '·',
            style: TextStyle(
                fontSize: size * .40,
                height: 1,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ),
    );
    return Semantics(
      image: true,
      label: '$name的角色形象',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Neon.hair),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox.square(
              dimension: size,
              child: ColoredBox(
                color: const Color(0xFF111729),
                child: crop == null
                    ? lettered
                    : FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: crop.width,
                          height: crop.height,
                          child: Stack(clipBehavior: Clip.hardEdge, children: [
                            Positioned.fill(child: fallback),
                            Positioned(
                              left: -crop.left,
                              top: -crop.top,
                              width: _imageSize.width,
                              height: _imageSize.height,
                              child: Image.asset(asset,
                                  fit: BoxFit.fill,
                                  excludeFromSemantics: true,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox()),
                            ),
                          ]),
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
