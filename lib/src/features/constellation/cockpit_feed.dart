import 'dart:async';

import 'cockpit_models.dart';

/// How the cockpit is doing at observing, as opposed to what it observed.
///
/// Kept apart from [CockpitSnapshot] on purpose. A transport failure is not a
/// fact about the domain, and the only way to express one through a
/// snapshot-shaped channel is to fabricate a snapshot that says "degraded" —
/// which is how a screen ends up claiming a Host is quiet when it is really a
/// screen that could not read one.
enum ObservationState {
  /// No successful read yet.
  connecting,

  /// Reading, and current.
  live,

  /// Something arrived, but not everything, or not recently.
  degraded,

  /// The stream is gone. What is on screen is a memory.
  lost,
}

class CockpitObservation {
  const CockpitObservation({
    required this.state,
    this.detail = '',
    this.lastReadAt,
    this.cursor,
  });

  final ObservationState state;

  /// Why, when the state is not [ObservationState.live]. Shown to the reader.
  final String detail;

  /// When the last successful read landed. Null means there has never been one,
  /// which is a different screen from "read a while ago".
  final DateTime? lastReadAt;

  /// The last event this feed has consumed, so a resumed stream can say where it
  /// left off instead of silently restarting from now.
  final String? cursor;

  bool get healthy => state == ObservationState.live;
}

/// Where the cockpit gets its facts.
///
/// The shape is the one the Local API contract requires (see
/// `docs/mission-control-local-api-contract.md`), not the one a mock finds
/// convenient. Four of its decisions are deliberate:
///
/// * [snapshot] is nullable, because a real adapter has no facts until its
///   first round trip, and handing over an empty snapshot instead would make
///   "not read yet" look like "nothing there".
/// * [observations] gives failure its own channel.
/// * [pause] / [resume] are in the interface because the consumer really calls
///   them — the page hangs them off `AppLifecycleState`.
/// * [refresh] must throw on failure. A refresh button that fails silently is
///   the worst kind of button.
abstract class CockpitFeed {
  /// The last read, or null before the first one lands.
  CockpitSnapshot? get snapshot;

  CockpitObservation get observation;

  /// Whole-snapshot replacements. The cockpit re-derives everything from these.
  Stream<CockpitSnapshot> get updates;

  /// Directed darts for events observed since the last snapshot. Separate from
  /// [updates] because a pulse is a moment, not a state: replaying a snapshot
  /// must never re-fire one.
  Stream<CockpitPulse> get pulses;

  /// Changes to how well this feed is observing. Errors on [updates] are for
  /// hard failures; this carries the graded story, including recovery.
  Stream<CockpitObservation> get observations;

  /// Read now. Throws when the read fails — callers surface it.
  Future<void> refresh();

  /// Stop consuming while nobody is looking. Must be safe to call twice.
  void pause();

  /// Start again, from [CockpitObservation.cursor] where the transport supports
  /// it. Must be safe to call twice.
  void resume();

  void dispose();
}
