import 'dart:async';

import 'cockpit_feed.dart';
import 'cockpit_models.dart';
import 'cockpit_wire.dart';

/// The star map, reading a real Host by polling one snapshot read.
///
/// Named for what it does, not for the surface it reads. It was
/// `LocalApiCockpitFeed`, which encoded the plane `/api/local/v1` — the Owner
/// product surface the convergence plan deletes — into a class name. It takes a
/// read function and owns no transport, so the name had no business claiming
/// one.
///
/// One read, repeated — and darts for the moments that arrived between two of
/// them.
///
/// It used to fire nothing, on the grounds that a dart invented from a snapshot
/// diff claims a direction and a moment nobody observed. That reasoning holds,
/// and it is about *state*: two readings differing in how many bodies are
/// online say nothing about when or how that changed. It does not apply to the
/// events lane, which is the Host's audit tail — each row an id, a moment, a
/// subject and an outcome the Host recorded, ordered by a sequence it assigned.
/// A row that was not in the last reading and is in this one happened in
/// between, and firing a dart for it reports an observation rather than
/// inventing one.
///
/// Two rules keep that honest, both in [eventsAfter]: a reading with no
/// predecessor fires nothing, because its backlog is history rather than now;
/// and a row with no sequence is skipped, because a Host that keeps no order
/// cannot say whether one of its events is new.
///
/// What it does carry is the discipline the contract asks for: a failed read is
/// an observation state and not a fabricated snapshot, the last good snapshot
/// stays on screen while being labelled as a memory, polling stops when nobody
/// is looking, and a cursor is remembered for the stream that will exist.
/// The next delay after a failed read: the floor once, then doubling, capped.
///
/// Pure so the policy can be pinned without measuring wall-clock in a test —
/// timing assertions are the flakiest kind, and what matters here is the
/// sequence, not that a particular millisecond elapsed.
Duration nextReadBackoff(
  Duration previous, {
  required Duration floor,
  required Duration ceiling,
}) {
  if (previous <= Duration.zero) return floor;
  final doubled = previous.inMilliseconds * 2;
  return Duration(
    milliseconds: doubled.clamp(floor.inMilliseconds, ceiling.inMilliseconds),
  );
}

class PolledCockpitFeed implements CockpitFeed {
  PolledCockpitFeed({
    required this.read,
    this.interval = const Duration(seconds: 6),
    this.retryFloor = const Duration(seconds: 2),
    this.retryCeiling = const Duration(seconds: 45),
  });

  /// One authenticated read of the projection. Kept as a function so this feed
  /// owns no session, no base URL and no pinning policy — the Host session that
  /// already holds those hands one in.
  final Future<CockpitSnapshot> Function() read;

  /// How often to re-read while someone is looking.
  final Duration interval;

  /// Bounded backoff after a failure. A cockpit that retries a dead Host every
  /// two seconds forever is a battery complaint with extra steps.
  final Duration retryFloor;
  final Duration retryCeiling;

  final _updates = StreamController<CockpitSnapshot>.broadcast();
  final _pulses = StreamController<CockpitPulse>.broadcast();
  final _observations = StreamController<CockpitObservation>.broadcast();

  CockpitSnapshot? _snapshot;

  /// The highest event sequence this feed has already reported. Null until the
  /// first reading lands, which is what makes that reading a baseline rather
  /// than a hundred darts.
  int? _watermark;
  CockpitObservation _observation =
      const CockpitObservation(state: ObservationState.connecting);
  Timer? _timer;
  Duration _backoff = Duration.zero;

  /// Whether this feed's observation is open at all.
  ///
  /// Not "has `start` been called": [refresh] is a caller asking too, and it
  /// keeps the schedule alive, so it opens the observation just as legitimately.
  /// What must never open it is construction.
  var _observing = false;
  var _paused = false;
  var _disposed = false;
  var _reading = false;

  @override
  CockpitSnapshot? get snapshot => _snapshot;

  @override
  CockpitObservation get observation => _observation;

  @override
  Stream<CockpitSnapshot> get updates => _updates.stream;

  @override
  Stream<CockpitPulse> get pulses => _pulses.stream;

  @override
  Stream<CockpitObservation> get observations => _observations.stream;

  /// Start reading. Safe to call twice — a second call is a no-op rather than a
  /// second polling schedule racing the first.
  ///
  /// The first read's failure is swallowed here, not because it does not matter
  /// but because it has already been reported on [observations] and there is no
  /// caller to rethrow it to. Only [refresh] has one: the reader who pressed
  /// retry.
  @override
  void start() {
    if (_disposed || _observing) return;
    _observing = true;
    if (_paused) return;
    unawaited(refresh().catchError((_) {}));
  }

  @override
  Future<void> refresh() async {
    if (_disposed || _reading) return;
    _reading = true;
    _observing = true;
    try {
      final snapshot = await read();
      if (_disposed) return;
      final fresh = snapshot.eventsLane.readable
          ? eventsAfter(_watermark, snapshot.events)
          : const <CockpitEvent>[];
      _watermark = snapshot.eventsLane.readable
          ? highestSequence(_watermark, snapshot.events)
          // An unreadable lane is not an empty one: keep the mark, so the gap
          // is reported as darts once the lane answers again rather than
          // silently skipped.
          : _watermark;
      _snapshot = snapshot;
      _backoff = Duration.zero;
      _publish(
        CockpitObservation(
          state: _stateFor(snapshot),
          detail: _detailFor(snapshot),
          lastReadAt: snapshot.generatedAt,
          cursor: snapshot.cursor?.toString() ?? _observation.cursor,
        ),
      );
      _updates.add(snapshot);
      for (final event in fresh) {
        final pulse = _pulseFor(event);
        if (pulse != null) _pulses.add(pulse);
      }
      _schedule(interval);
    } catch (error) {
      if (_disposed) return;
      _backoff = nextReadBackoff(
        _backoff,
        floor: retryFloor,
        ceiling: retryCeiling,
      );
      _publish(
        CockpitObservation(
          // What is on screen, if anything, is a memory now. The domain did not
          // stop; this screen stopped being able to see it.
          state: ObservationState.lost,
          detail: '$error',
          lastReadAt: _observation.lastReadAt,
          cursor: _observation.cursor,
        ),
      );
      _schedule(_backoff);
      rethrow;
    } finally {
      _reading = false;
    }
  }

  /// One observed moment, as a dart — or nothing, when this kind of moment does
  /// not travel a leg of the map. Not every event is a journey: a lifecycle
  /// change or a policy decision is worth a row in the event list and nothing on
  /// the glass, and drawing one anyway would put motion where none happened.
  CockpitPulse? _pulseFor(CockpitEvent event) {
    final directed = eventToPulse(event);
    if (directed == null) return null;
    return CockpitPulse(
      id: event.eventId,
      companionId: event.companionId,
      leg: directed.leg,
      direction: directed.direction,
      tone: eventTone(event.severity, event.outcome),
      // The moment the Host observed, not the moment this screen heard about
      // it. A dart stamped with now would make a six-second-old event look
      // like it is happening as you watch.
      firedAt: event.ts,
      deviceId: event.deviceId,
    );
  }

  /// A snapshot in which nothing could be read is not a healthy observation,
  /// even though the request succeeded.
  ObservationState _stateFor(CockpitSnapshot snapshot) =>
      snapshot.unreadableLanes.isEmpty
          ? ObservationState.live
          : ObservationState.degraded;

  String _detailFor(CockpitSnapshot snapshot) {
    final unreadable = snapshot.unreadableLanes;
    if (unreadable.isEmpty) return '';
    return '这一屏读不到：${unreadable.join('、')}';
  }

  void _publish(CockpitObservation observation) {
    _observation = observation;
    _observations.add(observation);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed || _paused) return;
    _timer = Timer(delay, () {
      if (_disposed || _paused) return;
      // A failure inside the timer has nowhere to be rethrown to; the
      // observation channel is where it is reported.
      unawaited(refresh().catchError((_) {}));
    });
  }

  @override
  void pause() {
    if (_paused) return;
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    // Nothing to resume if nobody ever asked: a resumed feed that had never
    // been started would silently become a started one, which is the confusion
    // this lifecycle exists to prevent.
    if (!_observing) return;
    // Read immediately rather than waiting out an interval: whatever is on
    // screen was true when the app went away, which may have been a while ago.
    unawaited(refresh().catchError((_) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _updates.close();
    _pulses.close();
    _observations.close();
  }
}
