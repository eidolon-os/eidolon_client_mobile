import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final crop = _portraits[presetId];
    final fallback = Center(
      child: Text(name.characters.firstOrNull ?? '·',
          style: Theme.of(context).textTheme.headlineSmall),
    );
    return Semantics(
      image: true,
      label: '$name的角色形象',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox.square(
            dimension: size,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: crop == null
                  ? fallback
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
                                errorBuilder: (_, __, ___) => const SizedBox()),
                          ),
                        ]),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
