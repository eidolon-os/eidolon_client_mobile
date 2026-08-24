import 'dart:async';

import 'cockpit_feed.dart';
import 'cockpit_models.dart';

/// The star map, reading a real Host by polling one snapshot read.
///
/// Named for what it does, not for the surface it reads. It was
/// `LocalApiCockpitFeed`, which encoded the plane `/api/local/v1` — the Owner
/// product surface the convergence plan deletes — into a class name. It takes a
/// read function and owns no transport, so the name had no business claiming
/// one.
///
/// One read, repeated. There is no event stream yet — the Local API's events
/// lane has no producer, so subscribing to one would be pretending — and this
/// says so by never emitting a pulse rather than by inventing them from
/// snapshot diffs. A dart fired because two snapshots differed would claim a
/// direction and a moment that nobody observed.
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
  CockpitObservation _observation =
      const CockpitObservation(state: ObservationState.connecting);
  Timer? _timer;
  Duration _backoff = Duration.zero;
  var _paused = false;
  var _disposed = false;
  var _reading = false;

  @override
  CockpitSnapshot? get snapshot => _snapshot;

  @override
  CockpitObservation get observation => _observation;

  @override
  Stream<CockpitSnapshot> get updates => _updates.stream;

  /// Always empty, for now. See the class comment: a pulse is a moment somebody
  /// observed, and this feed has no source of moments.
  @override
  Stream<CockpitPulse> get pulses => _pulses.stream;

  @override
  Stream<CockpitObservation> get observations => _observations.stream;

  /// Start reading. Safe to call twice.
  void start() {
    if (_disposed || _paused) return;
    unawaited(refresh());
  }

  @override
  Future<void> refresh() async {
    if (_disposed || _reading) return;
    _reading = true;
    try {
      final snapshot = await read();
      if (_disposed) return;
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
