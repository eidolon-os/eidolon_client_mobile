import 'dart:async';

import 'package:flutter/material.dart';

import 'cockpit_deck.dart';
import 'cockpit_details.dart';
import 'cockpit_feed.dart';
import 'cockpit_header.dart';
import 'cockpit_mock_feed.dart';
import 'cockpit_models.dart';
import 'cockpit_theme.dart';
import 'cockpit_ambience.dart';
import 'companion_inspector.dart';
import 'constellation_geometry.dart';
import 'constellation_stage.dart';

/// The sovereign domain of one Host, as a satellite map.
///
/// The console cockpit's information model, drawn for a phone: owner core,
/// companion planets, three asset moons each, bodies as ports, and the light
/// that travels between them when something actually happens. What changes for
/// the phone is the interaction, not the instrument — you fly the map instead of
/// taking it all in at once, and detail arrives as you arrive.
///
/// It reads one [CockpitFeed]. Today that is a mock world, and the screen says
/// so in two places rather than letting a demo pass for a Host's word. When the
/// Owner-scoped projection lands, the adapter changes and this file does not.
class ConstellationCockpitPage extends StatefulWidget {
  const ConstellationCockpitPage({super.key, this.feed});

  /// Left null in the app; injected in tests so a scene can be pinned.
  final CockpitFeed? feed;

  @override
  State<ConstellationCockpitPage> createState() =>
      _ConstellationCockpitPageState();
}

class _ConstellationCockpitPageState extends State<ConstellationCockpitPage>
    with SingleTickerProviderStateMixin {
  late final CockpitFeed _feed = widget.feed ?? MockCockpitFeed();
  late final AnimationController _clock = AnimationController.unbounded(
    vsync: this,
  );
  late final ValueNotifier<CockpitSnapshot> _snapshot =
      ValueNotifier<CockpitSnapshot>(_feed.snapshot);
  final _stage = GlobalKey<ConstellationStageState>();
  final List<CockpitPulse> _pulses = <CockpitPulse>[];
  final List<Timer> _pulseTimers = <Timer>[];
  StreamSubscription<CockpitSnapshot>? _snapshotSub;
  StreamSubscription<CockpitPulse>? _pulseSub;
  Timer? _secondHand;
  Timer? _igniteTimer;

  String _focusedId = '';
  InspectorTab _tab = InspectorTab.overview;
  CockpitPulse? _highlight;
  var _igniting = false;
  var _wasActive = false;
  var _clockText = '';

  @override
  void initState() {
    super.initState();
    _clockText = formatClock(DateTime.now());
    _snapshotSub = _feed.updates.listen(_onSnapshot);
    _pulseSub = _feed.pulses.listen(_onPulse);
    _secondHand = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _clockText = formatClock(DateTime.now()));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // One clock for the whole cockpit, in seconds. Under reduced motion it is
    // never started, so every painter renders one honest static frame instead of
    // a frozen animation.
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduced && !_clock.isAnimating) {
      _clock.repeat(min: 0, max: 3600, period: const Duration(seconds: 3600));
    } else if (reduced && _clock.isAnimating) {
      _clock.stop();
    }
  }

  bool get _animate => !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  void _onSnapshot(CockpitSnapshot snapshot) {
    if (!mounted) return;
    final active = snapshot.pipelineActive;
    if (active && !_wasActive) {
      _igniting = true;
      _igniteTimer?.cancel();
      _igniteTimer = Timer(Cockpit.ambient, () {
        if (mounted) setState(() => _igniting = false);
      });
    }
    _wasActive = active;
    _snapshot.value = snapshot;
    setState(() {});
  }

  void _onPulse(CockpitPulse pulse) {
    if (!mounted) return;
    setState(() => _pulses.add(pulse));
    // A dart is a moment. It leaves when it lands, and nothing re-fires it on
    // the next snapshot.
    final timer = Timer(Cockpit.slow, () {
      if (!mounted) return;
      setState(() => _pulses.remove(pulse));
    });
    _pulseTimers.add(timer);
  }

  @override
  void dispose() {
    for (final timer in _pulseTimers) {
      timer.cancel();
    }
    _igniteTimer?.cancel();
    _secondHand?.cancel();
    _snapshotSub?.cancel();
    _pulseSub?.cancel();
    _clock.dispose();
    _snapshot.dispose();
    if (widget.feed == null) _feed.dispose();
    super.dispose();
  }

  List<CompanionUnit> _units(CockpitSnapshot snapshot) => snapshot.companions
      .map(
        (companion) => CompanionUnit(
          companion: companion,
          devices: snapshot.devices
              .where((device) => device.companionId == companion.companionId)
              .toList(growable: false),
          activities: snapshot.activities
              .where(
                  (activity) => activity.companionId == companion.companionId)
              .toList(growable: false),
          turns: snapshot.turns
              .where((turn) => turn.companionId == companion.companionId)
              .toList(growable: false),
          jobs: snapshot.jobs
              .where(
                (job) =>
                    job.companionId == companion.companionId &&
                    (job.status == 'running' || job.status == 'pending'),
              )
              .toList(growable: false),
        ),
      )
      .toList(growable: false);

  String _companionName(CockpitSnapshot snapshot, String companionId) {
    for (final companion in snapshot.companions) {
      if (companion.companionId == companionId) {
        return companion.displayName.isEmpty
            ? compactId(companion.companionId)
            : companion.displayName;
      }
    }
    return '';
  }

  void _focus(String companionId, InspectorTab tab) {
    setState(() {
      _focusedId = companionId;
      _tab = tab;
    });
  }

  void _clearFocus() {
    if (_focusedId.isEmpty) return;
    setState(() {
      _focusedId = '';
      _tab = InspectorTab.overview;
    });
  }

  void _openDeck(CockpitSnapshot snapshot, int tab) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.32,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, controller) =>
            ValueListenableBuilder<CockpitSnapshot>(
          valueListenable: _snapshot,
          builder: (context, live, _) => CockpitDeckSheet(
            controller: controller,
            snapshot: live,
            scopeName:
                _focusedId.isEmpty ? '' : _companionName(live, _focusedId),
            initialTab: tab,
            onActivityTap: (activity) {
              Navigator.of(sheetContext).pop();
              _openActivity(live, activity);
            },
            onEventTap: (event) {
              Navigator.of(sheetContext).pop();
              _openEvent(live, event);
            },
            onServiceTap: (service) {
              Navigator.of(sheetContext).pop();
              _openService(service);
            },
          ),
        ),
      ),
    );
  }

  void _openOwner(CockpitSnapshot snapshot) {
    _clearFocus();
    showCockpitSheet(
      context,
      title: snapshot.owner.displayName,
      kicker: 'OWNER · 主人',
      accent: Cockpit.magenta,
      child: ownerSheetBody(snapshot),
    );
  }

  void _openService(CockpitService service) => showCockpitSheet(
        context,
        title: service.name,
        kicker: service.code,
        accent: toneColor(service.tone),
        child: serviceSheetBody(service),
      );

  void _openActivity(CockpitSnapshot snapshot, CockpitActivity activity) {
    if (activity.companionId.isNotEmpty) {
      _focus(activity.companionId, InspectorTab.activity);
    }
    showCockpitSheet(
      context,
      title: activityKindLabel(activity.kind),
      kicker: activityStatusLabel(activity.status),
      accent: isActiveActivity(activity) ? Cockpit.cyan : Cockpit.purple,
      child: activitySheetBody(
        activity,
        _companionName(snapshot, activity.companionId),
      ),
    );
  }

  void _openEvent(CockpitSnapshot snapshot, CockpitEvent event) {
    final pulse = eventToPulse(event);
    if (pulse != null && event.companionId.isNotEmpty) {
      setState(() {
        _highlight = CockpitPulse(
          id: event.eventId,
          companionId: event.companionId,
          leg: pulse.leg,
          direction: pulse.direction,
          tone: eventTone(event.severity, event.outcome),
          firedAt: event.ts,
          deviceId: event.deviceId,
        );
      });
    }
    showCockpitSheet(
      context,
      title: event.type,
      kicker: event.source.toUpperCase(),
      accent: Cockpit.source[event.source] ?? Cockpit.cyan,
      child: eventSheetBody(
        event,
        companionName: _companionName(snapshot, event.companionId),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _highlight = null);
    });
  }

  void _openDevice(CockpitSnapshot snapshot, CockpitDevice device) =>
      showCockpitSheet(
        context,
        title: deviceShortName(device),
        kicker: devicePresenceLabel(device),
        accent: toneColor(devicePresenceTone(device)),
        child: deviceSheetBody(
          device,
          companionName: _companionName(snapshot, device.companionId),
        ),
      );

  void _openCompanion(CompanionUnit unit) => showCockpitSheet(
        context,
        title: unit.name,
        kicker: unit.isPrimary ? 'PRIMARY' : 'COMPANION',
        accent: unit.isPrimary ? Cockpit.sun : Cockpit.cyan,
        child: companionSheetBody(unit),
      );

  /// The stage, wherever it ends up. The orbit shape is decided once for the
  /// whole page (see [chooseChrome]) and handed down, so the chrome and the map
  /// cannot disagree about which way round this screen is.
  Widget _stageFor(
    CockpitSnapshot snapshot,
    List<CompanionUnit> units,
    ConstellationMetrics metrics, {
    double bottomInset = 0,
  }) =>
      ConstellationStage(
        key: _stage,
        metrics: metrics,
        bottomInset: bottomInset,
        units: units,
        ownerName: snapshot.owner.displayName,
        unboundDevices: snapshot.unboundDevices,
        pulses: _pulses,
        clock: _clock,
        pipelineActive: snapshot.pipelineActive,
        igniting: _igniting,
        animate: _animate,
        focusedId: _focusedId,
        selectedKind: moonForTab(_tab),
        highlightPulse: _highlight,
        onOwnerTap: () => _openOwner(snapshot),
        onCompanionTap: (unit) => _focus(unit.id, InspectorTab.overview),
        onMoonTap: (moon) => _focus(moon.unit.id, tabForMoon(moon.kind)),
        onDeviceTap: (port) => _openDevice(snapshot, port.device),
        onActivityTap: (bead) => _openActivity(snapshot, bead.activity),
        onBackgroundTap: _clearFocus,
      );

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot.value;
    final units = _units(snapshot);
    final focused = units.where((unit) => unit.id == _focusedId).firstOrNull;
    // Measured, not assumed: both arrangements are costed against this window
    // and the one that draws the map largest wins. A landscape phone, a short
    // split-screen window and a tablet either way up all fall out of the same
    // comparison.
    final padding = MediaQuery.paddingOf(context);
    final scale = chromeScale(context);
    // A fixed 268 rail eats half of a small landscape phone, so it gives ground
    // on narrow windows — and the same number is what the choice is costed with.
    final railWidth =
        (MediaQuery.sizeOf(context).width * 0.38).clamp(200.0, 268.0);
    final chrome = chooseChrome(
      viewport: Size(
        MediaQuery.sizeOf(context).width,
        MediaQuery.sizeOf(context).height - padding.top,
      ),
      units: units,
      headerFull: 52 * scale + 38 * scale + 14,
      headerCompact: 52 * scale + 12,
      deck: kDeckHeight * scale + padding.bottom,
      rail: railWidth,
    );
    final landscape = chrome.rail;

    return Scaffold(
      key: const Key('constellation-cockpit-page'),
      backgroundColor: Cockpit.bg,
      // The instrument chrome is bounded; the drill-down sheets are not. They
      // are pushed on the Navigator above this subtree, so they keep the
      // reader's full font size — which is right, since reading is what they
      // are for.
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Builder(
          builder: (context) => Stack(
            fit: StackFit.expand,
            children: [
              // Ambient depth, behind everything and never hit-testable.
              IgnorePointer(child: StarField(clock: _clock)),
              IgnorePointer(child: PerspectiveGrid(clock: _clock)),
              SafeArea(
                bottom: false,
                right: !landscape,
                child: landscape
                    // Sideways: instruments on a rail, map keeps the height.
                    ? Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                CockpitHeader(
                                  snapshot: snapshot,
                                  clockText: _clockText,
                                  compact: true,
                                  onBack: () =>
                                      Navigator.of(context).maybePop(),
                                  onRefresh: _feed.refresh,
                                  onOwnerTap: () => _openOwner(snapshot),
                                ),
                                Expanded(
                                  child: _stageFor(
                                    snapshot,
                                    units,
                                    chrome.metrics,
                                    // Sideways the stage reaches the bottom of
                                    // the screen, gesture bar included.
                                    bottomInset: padding.bottom,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          CockpitRail(
                            width: railWidth,
                            snapshot: snapshot,
                            onExpand: () => _openDeck(snapshot, 0),
                            onServiceTap: _openService,
                            onEventTap: (event) => _openEvent(snapshot, event),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          CockpitHeader(
                            snapshot: snapshot,
                            clockText: _clockText,
                            onBack: () => Navigator.of(context).maybePop(),
                            onRefresh: _feed.refresh,
                            onOwnerTap: () => _openOwner(snapshot),
                          ),
                          Expanded(
                              child:
                                  _stageFor(snapshot, units, chrome.metrics)),
                          KernelDeck(
                            snapshot: snapshot,
                            onExpand: () => _openDeck(snapshot, 0),
                            onServiceTap: _openService,
                            onEventTap: (event) => _openEvent(snapshot, event),
                          ),
                        ],
                      ),
              ),
              // The focus card floats over the lower map; the camera has already
              // lifted the focused planet above it.
              Positioned(
                left: 10,
                right: landscape ? null : 10,
                width: landscape ? 344 : null,
                bottom: landscape ? 10 : deckHeight(context) + 10,
                child: IgnorePointer(
                  ignoring: focused == null,
                  child: AnimatedSlide(
                    offset:
                        focused == null ? const Offset(0, 1.2) : Offset.zero,
                    duration: Cockpit.slow,
                    curve: Cockpit.easeOut,
                    child: AnimatedOpacity(
                      opacity: focused == null ? 0 : 1,
                      duration: Cockpit.base,
                      child: focused == null
                          ? const SizedBox(height: 1)
                          : CompanionInspectorCard(
                              unit: focused,
                              tab: _tab,
                              onTab: (tab) => setState(() => _tab = tab),
                              onClose: _clearFocus,
                              onDetails: () => _openCompanion(focused),
                            ),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                  child: ScanlineVeil(clock: _clock, animate: _animate)),
              const IgnorePointer(child: CockpitVignette()),
            ],
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
