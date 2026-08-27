import 'dart:async';

import 'package:flutter/material.dart';

import 'cockpit_deck.dart';
import 'cockpit_details.dart';
import 'cockpit_feed.dart';
import 'cockpit_header.dart';
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
/// It reads one [CockpitFeed]. When the Owner-scoped projection lands, the
/// adapter changes and this file does not.
class ConstellationCockpitPage extends StatefulWidget {
  const ConstellationCockpitPage({super.key, required this.openFeed});

  /// How to open the feed this screen observes — a factory, not an instance,
  /// because the observation's lifetime is exactly this screen's.
  ///
  /// Taking an instance made ownership a matter of opinion, and both halves of
  /// it went missing: nobody started the feed (a real Host showed a spinner
  /// forever) and nobody disposed it (a popped star map kept polling that Host
  /// every six seconds for the rest of the process). With a factory there is
  /// one owner, its four transitions live in one [State], and `dispose` is
  /// covered by the one the framework already calls.
  ///
  /// Required, and deliberately not defaulted to the mock: a screen that falls
  /// back to a staged world when nobody passed it one is a screen that can show
  /// fiction because of a missing argument.
  final CockpitFeed Function() openFeed;

  @override
  State<ConstellationCockpitPage> createState() =>
      _ConstellationCockpitPageState();
}

class _ConstellationCockpitPageState extends State<ConstellationCockpitPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final CockpitFeed _feed;
  late final AnimationController _clock = AnimationController.unbounded(
    vsync: this,
  );
  late final ValueNotifier<CockpitSnapshot?> _snapshot;
  final _stage = GlobalKey<ConstellationStageState>();
  final List<CockpitPulse> _pulses = <CockpitPulse>[];
  final List<Timer> _pulseTimers = <Timer>[];
  StreamSubscription<CockpitSnapshot>? _snapshotSub;
  StreamSubscription<CockpitPulse>? _pulseSub;
  StreamSubscription<CockpitObservation>? _observationSub;
  Timer? _secondHand;
  Timer? _igniteTimer;

  /// How well this screen is observing, as opposed to what it observed. The
  /// feed's own channel — an unread domain is not a quiet one, and the map on
  /// screen after a failure is a memory, not an observation.
  late CockpitObservation _observation;

  String? get _readFailure =>
      _observation.healthy || _observation.state == ObservationState.connecting
          ? null
          : (_observation.detail.isEmpty ? '流已中断' : _observation.detail);
  DateTime? get _lastRead => _observation.lastReadAt;

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
    WidgetsBinding.instance.addObserver(this);
    _feed = widget.openFeed();
    _snapshot = ValueNotifier<CockpitSnapshot?>(_feed.snapshot);
    _observation = _feed.observation;
    _snapshotSub = _feed.updates.listen(_onSnapshot, onError: _onFeedError);
    _pulseSub = _feed.pulses.listen(_onPulse, onError: _onFeedError);
    _observationSub = _feed.observations.listen(
      (observation) {
        if (mounted) setState(() => _observation = observation);
      },
      onError: _onFeedError,
    );
    _secondHand = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _clockText = formatClock(DateTime.now()));
    });
    // Subscribed first, started second: these are broadcast streams, so a feed
    // that publishes its first read synchronously would publish it to nobody.
    _feed.start();
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
    // Read from the feed, not invented here. Fabricating `live` on every
    // snapshot clobbered the feed's own graded verdict: a reading where six of
    // seven lanes came back unreadable was published as `degraded` and then
    // overwritten, so the header said ONLINE over a screen full of 读不到.
    setState(() => _observation = _feed.observation);
  }

  void _onFeedError(Object error) {
    if (!mounted) return;
    setState(() {
      _observation = CockpitObservation(
        // The stream failing does not mean the domain stopped — only that this
        // screen stopped being able to see it.
        state: ObservationState.lost,
        detail: '$error',
        lastReadAt: _observation.lastReadAt,
        cursor: _observation.cursor,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Nobody is looking: stop consuming. A cockpit that keeps a stream open in
    // the background is a cockpit that spends a battery to observe nothing.
    if (state == AppLifecycleState.resumed) {
      _feed.resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _feed.pause();
    }
  }

  Future<void> _refresh() async {
    try {
      await _feed.refresh();
    } catch (error) {
      _onFeedError(error);
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _snapshotSub?.cancel();
    _pulseSub?.cancel();
    _observationSub?.cancel();
    // This screen opened the feed, so this screen closes it. Anything else
    // leaves a poll running against a Host nobody is looking at.
    _feed.dispose();
    _clock.dispose();
    _snapshot.dispose();
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
          isDefault: snapshot.defaultCompanionId == companion.companionId,
          jobs: snapshot.jobs
              .where(
                (job) =>
                    job.companionId == companion.companionId &&
                    (job.status == 'running' || job.status == 'pending'),
              )
              .toList(growable: false),
          bodiesReadable: snapshot.devicesLane.readable,
          activitiesReadable: snapshot.activitiesLane.readable,
          recallReadable: snapshot.turnsLane.readable,
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
            ValueListenableBuilder<CockpitSnapshot?>(
          valueListenable: _snapshot,
          builder: (context, live, _) {
            if (live == null) return const SizedBox.shrink();
            return CockpitDeckSheet(
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
            );
          },
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

  /// The interaction this activity is, if the reading still carries it.
  ///
  /// Null is ordinary rather than a failure: the turns lane is bounded, so an
  /// older activity outlives the turn it came from. The sheet then shows the
  /// route without the timings, which is what is actually known.
  CockpitTurn? _turnOf(CockpitSnapshot snapshot, CockpitActivity activity) {
    if (activity.turnId.isEmpty) return null;
    for (final turn in snapshot.turns) {
      if (turn.turnId == activity.turnId) return turn;
    }
    return null;
  }

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
        turn: _turnOf(snapshot, activity),
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
        kicker: unit.isDefault ? 'DEFAULT' : 'COMPANION',
        accent: unit.isDefault ? Cockpit.sun : Cockpit.cyan,
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
        companionsReadable: snapshot.companionsLane.readable,
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
    if (snapshot == null) {
      // No read has landed. This is not an empty domain and must not look like
      // one, so the map is not drawn at all until there is something to draw.
      return _FirstReadScreen(
        clock: _clock,
        observation: _observation,
        onBack: () => Navigator.of(context).maybePop(),
        onRetry: _refresh,
      );
    }
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
                                  readFailed: _readFailure != null,
                                  onBack: () =>
                                      Navigator.of(context).maybePop(),
                                  onRefresh: _refresh,
                                  onOwnerTap: () => _openOwner(snapshot),
                                ),
                                if (_readFailure case final failure?)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      10,
                                      8,
                                      10,
                                      0,
                                    ),
                                    child: _ReadFailureStrip(
                                      state: _observation.state,
                                      failure: failure,
                                      lastRead: _lastRead,
                                      onRetry: _refresh,
                                    ),
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
                            readFailed: _readFailure != null,
                            onBack: () => Navigator.of(context).maybePop(),
                            onRefresh: _refresh,
                            onOwnerTap: () => _openOwner(snapshot),
                          ),
                          if (_readFailure case final failure?)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                              child: _ReadFailureStrip(
                                state: _observation.state,
                                failure: failure,
                                lastRead: _lastRead,
                                onRetry: _refresh,
                              ),
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

/// What a failed read looks like. It sits over the map rather than replacing it,
/// because the map is still the last thing that was true — but it says so, with
/// the time of that reading, and it never lets the screen imply that a domain
/// nobody could read is a domain where nothing is happening.
/// Two different pieces of bad news, and they are not interchangeable.
///
/// `degraded` means the read landed and part of it came back unreadable: what is
/// on screen is current, and some of it is unknown. `lost` means the reading
/// itself stopped: what is on screen is a memory. This strip was written for
/// `lost` only, and once the feed's graded verdict actually reached the screen
/// it started telling a Host that answered five seconds ago that its map was
/// stale — the same class of lie, pointed the other way.
class _ReadFailureStrip extends StatelessWidget {
  const _ReadFailureStrip({
    required this.state,
    required this.failure,
    required this.lastRead,
    required this.onRetry,
  });

  final ObservationState state;
  final String failure;
  final DateTime? lastRead;
  final VoidCallback onRetry;

  bool get _partial => state == ObservationState.degraded;

  @override
  Widget build(BuildContext context) => CockpitSlab(
        key: const Key('cockpit-read-failure'),
        accent: _partial ? Cockpit.yellow : Cockpit.magenta,
        borderOpacity: 0.7,
        fill: (_partial ? const Color(0xFF191203) : const Color(0xFF1A0413))
            .withValues(alpha: 0.95),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          children: [
            CockpitLed(
              color: _partial ? Cockpit.yellow : Cockpit.bad,
              size: 7,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _partial ? '这一屏有读不到的部分' : '读不到这台主机的运行投影',
                    style: Cockpit.sans(
                      size: 12.5,
                      color: _partial ? Cockpit.yellow : Cockpit.bad,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _partial
                        ? '${lastRead == null ? '刚刚' : formatClock(lastRead!)}'
                            ' 这一次读取成功了，但不完整。$failure。'
                            '它们的状态是未知，不是正常。'
                        : lastRead == null
                            ? '屏幕上没有任何一次成功的读取。$failure'
                            : '屏幕上是 ${formatClock(lastRead!)} 那一次读取的样子，'
                                '不是现在。$failure',
                    style: Cockpit.mono(
                      size: 9.5,
                      weight: FontWeight.w600,
                      color: Cockpit.ink,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              key: const Key('retry-cockpit-read'),
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(color: Cockpit.magenta),
                ),
                child: Text(
                  '重试',
                  style: Cockpit.mono(size: 10, color: Cockpit.bad),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Before the first read.
///
/// Deliberately not the map with nothing on it. A constellation drawn from no
/// data looks exactly like a domain where nothing exists, and this screen's
/// whole job is to keep those two apart. So it says which it is, and if the
/// first read failed it says that instead of waiting forever.
class _FirstReadScreen extends StatelessWidget {
  const _FirstReadScreen({
    required this.clock,
    required this.observation,
    required this.onBack,
    required this.onRetry,
  });

  final Animation<double> clock;
  final CockpitObservation observation;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = observation.state == ObservationState.lost ||
        observation.state == ObservationState.degraded;
    return Scaffold(
      key: const Key('constellation-first-read'),
      backgroundColor: Cockpit.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(child: StarField(clock: clock)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: onBack,
                    child: Text(
                      '‹ 返回',
                      style: Cockpit.mono(size: 11, color: Cockpit.inkDim),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'EIDOLON 星图',
                    style: Cockpit.mono(
                      size: 13,
                      weight: FontWeight.w900,
                      color: Colors.white,
                      tracking: 0.16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    failed ? '没能读到这台主机的运行投影' : '正在读取这台主机的运行投影',
                    style: Cockpit.sans(
                      size: 17,
                      color: failed ? Cockpit.bad : Cockpit.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    failed
                        ? '${observation.detail}\n'
                            '这一屏还没有过任何一次成功的读取，所以它什么都不画 —— '
                            '空的星图和读不到的星图，不该长成同一张。'
                        : '还没有事实到达。星图会在第一次读取落地后出现。',
                    style: Cockpit.mono(
                      size: 10,
                      weight: FontWeight.w600,
                      color: Cockpit.inkDim,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (failed)
                    GestureDetector(
                      key: const Key('retry-first-read'),
                      onTap: onRetry,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Cockpit.cyan),
                          color: Cockpit.cyan.withValues(alpha: 0.08),
                        ),
                        child: Text(
                          '重试',
                          style: Cockpit.mono(size: 11, color: Cockpit.cyan),
                        ),
                      ),
                    )
                  else
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(Cockpit.cyan),
                      ),
                    ),
                  const Spacer(flex: 2),
                ],
              ),
            ),
          ),
          const IgnorePointer(child: CockpitVignette()),
        ],
      ),
    );
  }
}
