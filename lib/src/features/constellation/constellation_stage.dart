import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';
import 'constellation_geometry.dart';
import 'constellation_nodes.dart';
import 'constellation_painter.dart';

/// The satellite map itself: owner core at the centre, companion planets on the
/// orbit, three asset moons each, bodies as ports on the body moon.
///
/// A phone cannot hold a wall's constellation at one zoom, so this is a map you
/// move: pinch, drag, and tap a planet to be flown to it. That is not a reduced
/// version of the console's single-screen view — it is the same information
/// model given the interaction a hand actually has. Detail appears as you
/// arrive: at overview zoom the nodes are shapes and colour, and labels fade in
/// only where they can be read.
class ConstellationStage extends StatefulWidget {
  const ConstellationStage({
    super.key,
    required this.units,
    required this.ownerName,
    this.companionsReadable = true,
    required this.unboundDevices,
    required this.pulses,
    required this.clock,
    required this.pipelineActive,
    required this.animate,
    this.igniting = false,
    this.bottomInset = 0,
    this.focusedId = '',
    this.selectedKind,
    this.highlightPulse,
    this.metrics,
    this.onOwnerTap,
    this.onCompanionTap,
    this.onMoonTap,
    this.onDeviceTap,
    this.onActivityTap,
    this.onBackgroundTap,
  });

  final List<CompanionUnit> units;
  final String ownerName;

  /// Passed through to the core: a count of zero and an unread count are not
  /// the same statement.
  final bool companionsReadable;
  final List<CockpitDevice> unboundDevices;

  /// Darts fired since the last frame, with their own launch times.
  final List<CockpitPulse> pulses;
  final Animation<double> clock;
  final bool pipelineActive;
  final bool animate;

  /// True for the moment a turn takes the pipeline idle → live, so the core can
  /// flare once instead of pulsing for as long as anything is running.
  final bool igniting;

  /// How much of the stage's bottom edge is under a system gesture area. The map
  /// may bleed into it; the controls sitting on top of the map may not.
  final double bottomInset;
  final String focusedId;
  final MoonKind? selectedKind;

  /// A leg the reader is pointing at from the event list, drawn as a lit path.
  final CockpitPulse? highlightPulse;

  /// Forced orbit shape. Null lets the stage pick from its own aspect ratio,
  /// which is what the app wants: the same screen rotated is a different map.
  final ConstellationMetrics? metrics;
  final VoidCallback? onOwnerTap;
  final void Function(CompanionUnit unit)? onCompanionTap;
  final void Function(MoonNode moon)? onMoonTap;
  final void Function(DevicePortNode port)? onDeviceTap;
  final void Function(ActivityBeadNode bead)? onActivityTap;
  final VoidCallback? onBackgroundTap;

  @override
  State<ConstellationStage> createState() => ConstellationStageState();
}

class ConstellationStageState extends State<ConstellationStage>
    with SingleTickerProviderStateMixin {
  final _viewer = TransformationController();
  late final AnimationController _camera = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  Animation<Matrix4>? _cameraTween;
  final _zoom = ValueNotifier<double>(1);
  Size _viewport = Size.zero;
  Size _canvas = Size.zero;
  double _fitScale = 1;
  var _framed = false;
  String _cameraFocus = '';

  @override
  void initState() {
    super.initState();
    _viewer.addListener(() => _zoom.value = _viewer.value.getMaxScaleOnAxis());
    _camera.addListener(() {
      final tween = _cameraTween;
      if (tween != null) _viewer.value = tween.value;
    });
  }

  @override
  void dispose() {
    _camera.dispose();
    _viewer.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _frame(Size viewport, ConstellationLayout layout) {
    if (viewport.isEmpty) return;
    // A rotation changes both, and either alone invalidates the framing: the map
    // is re-shaped as well as re-sized. Focus is the exception — taking a
    // companion's moons back out of hiding also changes the canvas, and
    // re-framing there would snap the camera a frame before the fly-to moves it.
    final reshaped = layout.canvas != _canvas;
    final changed = viewport != _viewport ||
        (reshaped && widget.focusedId.isEmpty && _cameraFocus.isEmpty);
    _viewport = viewport;
    _canvas = layout.canvas;
    _fitScale = math.min(
      viewport.width / layout.canvas.width,
      viewport.height / layout.canvas.height,
    );
    if (!_framed || changed) {
      _framed = true;
      _viewer.value = _matrixFor(
        layout.canvas.center(Offset.zero),
        _openingScale,
        viewport,
        Alignment.center,
      );
    }
  }

  /// Where the map opens: the whole domain, as large as it goes without cutting
  /// anything off. Opening zoomed-in past the edges was tried and rejected —
  /// two labelled moons clipped on the first frame reads as a broken screen,
  /// not as an invitation to pan. Capped so a tablet does not blow the nodes up
  /// to poster size.
  double get _openingScale => math.min(_fitScale, 1.45);

  /// The transform that puts [target] (in canvas coordinates) at [anchor] of the
  /// viewport at scale [scale].
  Matrix4 _matrixFor(
    Offset target,
    double scale,
    Size viewport,
    Alignment anchor,
  ) {
    final view = Offset(
      viewport.width * (anchor.x + 1) / 2,
      viewport.height * (anchor.y + 1) / 2,
    );
    return Matrix4.identity()
      ..translateByDouble(
        view.dx - target.dx * scale,
        view.dy - target.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _flyTo(Matrix4 target) {
    _cameraTween = Matrix4Tween(begin: _viewer.value, end: target).animate(
      CurvedAnimation(parent: _camera, curve: Cockpit.easeOut),
    );
    _camera
      ..reset()
      ..forward();
  }

  /// Fly to a companion so its whole cluster is on screen and readable, sitting
  /// a little above centre to leave the inspector its room.
  void focusOn(PlanetNode planet, Size viewport) {
    final scale = math.max(_fitScale * 1.4, 0.95).clamp(_fitScale, 2.2);
    _flyTo(
      _matrixFor(
        planet.center,
        scale.toDouble(),
        viewport,
        const Alignment(0, -0.34),
      ),
    );
  }

  /// Back to the whole domain in one frame.
  ///
  /// Centres the map, not the owner core. The two are not the same point: the
  /// canvas hugs its contents, and with companions spread up the portrait orbit
  /// there is far more map above the core than below it. Centring the core put
  /// the top of the map off screen — which on a tablet meant moons painting over
  /// the header.
  void showWholeDomain(ConstellationLayout layout) {
    _flyTo(
      _matrixFor(
        layout.canvas.center(Offset.zero),
        _fitScale,
        _viewport,
        Alignment.center,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          final layout = buildConstellationLayout(
            units: widget.units,
            metrics: widget.metrics ?? ConstellationMetrics.forStage(viewport),
          );
          // Framing is a layout consequence, not a build product: doing it here
          // keeps the first frame correct instead of one frame late.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _frame(viewport, layout);
            final focused = widget.focusedId;
            if (focused != _cameraFocus) {
              _cameraFocus = focused;
              final planet = layout.planet(focused);
              if (planet != null) {
                focusOn(planet, viewport);
              } else if (focused.isEmpty && _framed) {
                showWholeDomain(layout);
              }
            }
          });

          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onBackgroundTap,
                child: InteractiveViewer(
                  transformationController: _viewer,
                  minScale: 0.35,
                  maxScale: 2.6,
                  boundaryMargin: const EdgeInsets.all(160),
                  // Clipped to the stage: the map is allowed to be bigger than
                  // the viewport, and anything hanging past the edge must stop
                  // there rather than paint over the header and the deck.
                  clipBehavior: Clip.hardEdge,
                  // The map is bigger than the viewport by design: constraining
                  // the child to the viewport would squeeze the canvas and leave
                  // half the nodes painted where no finger can reach them.
                  constrained: false,
                  child: SizedBox(
                    width: layout.canvas.width,
                    height: layout.canvas.height,
                    child: _StageContent(
                      layout: layout,
                      zoom: _zoom,
                      fitScale: _fitScale,
                      widgetRef: widget,
                    ),
                  ),
                ),
              ),
              if (widget.unboundDevices.isNotEmpty)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: _UnboundBadge(devices: widget.unboundDevices),
                ),
              Positioned(
                left: 10,
                bottom: 10,
                child: _ZoomControls(
                  onFit: () => showWholeDomain(layout),
                  zoom: _zoom,
                ),
              ),
            ],
          );
        },
      );
}

class _StageContent extends StatelessWidget {
  const _StageContent({
    required this.layout,
    required this.zoom,
    required this.fitScale,
    required this.widgetRef,
  });

  final ConstellationLayout layout;
  final ValueNotifier<double> zoom;
  final double fitScale;
  final ConstellationStage widgetRef;

  @override
  Widget build(BuildContext context) {
    final units = widgetRef.units;
    final focusedId = widgetRef.focusedId;
    final activeCount =
        units.where((unit) => unit.activeActivity != null).length;

    final flows = <FlowLoop>[];
    final legBrightness = <String, double>{};
    // The stage rebuilds on snapshot changes; the wires rebuild with it, so the
    // dashing cost is paid per change rather than per frame.
    final stageHere = <String>{};
    for (final planet in layout.planets) {
      final unit = planet.unit;
      final legs = flowLegs(unit);
      if (shouldFlow(
        companionId: unit.id,
        focusedId: focusedId,
        hasActivity: unit.activeActivity != null,
        activeCount: activeCount,
      )) {
        final path = buildFlowPath(planet, legs);
        if (path != null) {
          flows.add(
            FlowLoop(
              companionId: unit.id,
              path: path,
              periodSeconds:
                  flowSegments(legs) * Cockpit.ambient.inMilliseconds / 1000,
            ),
          );
          if (legs.body) legBrightness['${unit.id}:body'] = 1;
          if (legs.act) legBrightness['${unit.id}:act'] = 1;
          if (legs.mem) legBrightness['${unit.id}:mem'] = legs.memBright;
        }
      }
      final activity = unit.activeActivity;
      final stageKey = activity != null
          ? currentActivityHop(activity)?.stage ?? ''
          : currentStageKey(unit.turn);
      final moon = stageMoon(stageKey);
      if (moon != null) stageHere.add('${unit.id}:${moon.name}');
    }

    final geometry = WireGeometry(
      layout: layout,
      litLegs: legBrightness.keys.toSet(),
    );

    final wires = AnimatedBuilder(
      animation: widgetRef.clock,
      builder: (context, _) {
        final now = DateTime.now();
        final pulses = <LivePulse>[];
        for (final pulse in widgetRef.pulses) {
          final planet = layout.planet(pulse.companionId);
          final moon = planet?.moon(pulse.leg);
          if (planet == null || moon == null) continue;
          DevicePortNode? port;
          if (pulse.leg == MoonKind.body && pulse.deviceId.isNotEmpty) {
            for (final candidate in planet.ports) {
              if (candidate.device.deviceId == pulse.deviceId) {
                port = candidate;
                break;
              }
            }
          }
          final elapsed =
              now.difference(pulse.firedAt).inMilliseconds.toDouble();
          final progress = elapsed / Cockpit.slow.inMilliseconds;
          if (progress < 0 || progress > 1) continue;
          pulses.add(
            LivePulse(
              pulse: pulse,
              path: buildPulsePath(
                planet: planet,
                moon: moon,
                direction: pulse.direction,
                port: port,
              ),
              progress: progress,
            ),
          );
        }

        final highlight = widgetRef.highlightPulse;
        return CustomPaint(
          painter: ConstellationWirePainter(
            wires: geometry,
            time: widgetRef.clock.value,
            flows: flows,
            pulses: pulses,
            legBrightness: legBrightness,
            pipelineActive: widgetRef.pipelineActive,
            focusedId: focusedId,
            animate: widgetRef.animate,
            highlight:
                highlight == null ? null : _highlightPath(layout, highlight),
          ),
          isComplex: true,
          willChange: true,
          size: layout.canvas,
        );
      },
    );

    // Wires repaint every frame; nodes rebuild only when the zoom or the
    // selection changes. Keeping them apart is the difference between a
    // constellation that animates and one that rebuilds three dozen widgets
    // sixty times a second.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: wires),
        Positioned.fill(
          child: ValueListenableBuilder<double>(
            valueListenable: zoom,
            builder: (context, scale, _) => _StageNodes(
              layout: layout,
              detail: scale,
              stageHere: stageHere,
              widgetRef: widgetRef,
            ),
          ),
        ),
      ],
    );
  }
}

Path? _highlightPath(ConstellationLayout layout, CockpitPulse pulse) {
  final planet = layout.planet(pulse.companionId);
  final moon = planet?.moon(pulse.leg);
  if (planet == null || moon == null) return null;
  DevicePortNode? port;
  if (pulse.leg == MoonKind.body && pulse.deviceId.isNotEmpty) {
    for (final candidate in planet.ports) {
      if (candidate.device.deviceId == pulse.deviceId) {
        port = candidate;
        break;
      }
    }
  }
  return buildPulsePath(
    planet: planet,
    moon: moon,
    direction: pulse.direction,
    port: port,
  );
}

class _StageNodes extends StatelessWidget {
  const _StageNodes({
    required this.layout,
    required this.detail,
    required this.stageHere,
    required this.widgetRef,
  });

  final ConstellationLayout layout;
  final double detail;
  final Set<String> stageHere;
  final ConstellationStage widgetRef;

  @override
  Widget build(BuildContext context) {
    final focusedId = widgetRef.focusedId;
    final hasFocus = focusedId.isNotEmpty;
    final children = <Widget>[];

    for (final planet in layout.planets) {
      final dimmed = hasFocus && planet.unit.id != focusedId;
      if (detail >= kDetailValue) {
        for (final port in planet.ports) {
          children.add(
            _At(
              port.center,
              DevicePortDot(
                port: port,
                diameter: layout.metrics.portRadius * 2 + 2,
                clock: widgetRef.clock,
                dimmed: hasFocus && !port.active && planet.unit.id != focusedId,
                animate: widgetRef.animate,
                onTap: () => widgetRef.onDeviceTap?.call(port),
              ),
            ),
          );
        }
        for (final bead in planet.beads) {
          children.add(
            _At(
              bead.center,
              ActivityBead(
                bead: bead,
                clock: widgetRef.clock,
                dimmed: dimmed,
                animate: widgetRef.animate,
                onTap: () => widgetRef.onActivityTap?.call(bead),
              ),
            ),
          );
        }
      }
      for (final moon in planet.moons) {
        children.add(
          _At(
            moon.center,
            AssetMoon(
              moon: moon,
              diameter: layout.metrics.moonRadius * 2,
              clock: widgetRef.clock,
              selected: planet.unit.id == focusedId &&
                  widgetRef.selectedKind == moon.kind,
              dimmed: dimmed,
              stageHere: stageHere.contains(moon.key),
              animate: widgetRef.animate,
              detail: detail,
              onTap: () => widgetRef.onMoonTap?.call(moon),
            ),
          ),
        );
      }
    }

    for (final planet in layout.planets) {
      children.add(
        _At(
          planet.center,
          CompanionPlanet(
            planet: planet,
            diameter: layout.metrics.planetRadius * 2,
            clock: widgetRef.clock,
            focused: planet.unit.id == focusedId,
            dimmed: hasFocus && planet.unit.id != focusedId,
            animate: widgetRef.animate,
            detail: detail,
            onTap: () => widgetRef.onCompanionTap?.call(planet.unit),
          ),
        ),
      );
    }

    children.add(
      _At(
        layout.ownerCenter,
        OwnerCore(
          diameter: layout.metrics.ownerRadius * 2,
          name: widgetRef.ownerName,
          companionCount: widgetRef.units.length,
          companionsReadable: widgetRef.companionsReadable,
          clock: widgetRef.clock,
          pipelineActive: widgetRef.pipelineActive,
          igniting: widgetRef.igniting,
          animate: widgetRef.animate,
          onTap: () => widgetRef.onOwnerTap?.call(),
        ),
      ),
    );

    // The chrome honours the reader's system font size; the nodes cannot. A
    // circle is a fixed shape, and past about 1.15 the three lines inside a moon
    // stop fitting no matter how they are laid out. Clamped here and fitted in
    // the node, so a large-font device gets a map that draws instead of one
    // striped with overflow warnings — the zoom is how you read it larger.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }
}

/// Place a node by its centre, whatever size it turns out to be.
class _At extends StatelessWidget {
  const _At(this.center, this.child);

  final Offset center;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
        left: center.dx,
        top: center.dy,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: child,
        ),
      );
}

class _UnboundBadge extends StatelessWidget {
  const _UnboundBadge({required this.devices});

  final List<CockpitDevice> devices;

  @override
  Widget build(BuildContext context) => CockpitSlab(
        accent: Cockpit.yellow,
        borderOpacity: 0.4,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        fill: Cockpit.yellow.withValues(alpha: 0.06),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CockpitLed(color: Cockpit.warn, size: 7),
            const SizedBox(width: 7),
            Text(
              '待认领设备',
              style: Cockpit.mono(size: 10.5, color: Cockpit.yellow),
            ),
            const SizedBox(width: 7),
            Text(
              '${devices.length}',
              style: Cockpit.mono(size: 13, weight: FontWeight.w900),
            ),
          ],
        ),
      );
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({required this.onFit, required this.zoom});

  final VoidCallback onFit;
  final ValueNotifier<double> zoom;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onFit,
        child: CockpitSlab(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('⤢', style: Cockpit.mono(size: 12, color: Cockpit.cyan)),
              const SizedBox(width: 6),
              Text('全域', style: Cockpit.mono(size: 10, color: Cockpit.cyan)),
              const SizedBox(width: 8),
              ValueListenableBuilder<double>(
                valueListenable: zoom,
                builder: (context, scale, _) => Text(
                  '${(scale * 100).round()}%',
                  style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim),
                ),
              ),
            ],
          ),
        ),
      );
}
