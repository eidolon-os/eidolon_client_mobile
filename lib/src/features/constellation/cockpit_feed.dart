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
/// * [start] / [pause] / [resume] / [dispose] are in the interface because the
///   consumer really drives them — the page starts one when it mounts, hangs
///   pause/resume off `AppLifecycleState`, and disposes on the way out.
/// * [refresh] must throw on failure. A refresh button that fails silently is
///   the worst kind of button.
///
/// The lifecycle is the interface's business, not each implementation's private
/// habit. It was not, once: nothing here said "begin observing", so the mock
/// began inside its own constructor and the polled feed waited to be asked —
/// and the page, holding this type, had no way to ask. It showed a spinner
/// forever against a real Host while every test passed, because the mock was
/// driving itself. So: **a feed must not observe anything until [start]**, and
/// creating one must have no effect a reader could see. That way the mock and
/// the real transport wear the same lifecycle, and any consumer that forgets to
/// start one is starved by both.
abstract class CockpitFeed {
  /// Begin observing. Nothing arrives on any stream before this is called, and
  /// a feed that is never started reports nothing rather than inventing a
  /// quiet domain.
  ///
  /// Must be safe to call twice. The caller subscribes first and starts second:
  /// these streams are broadcast, so they do not keep an event for a listener
  /// who was not there yet.
  void start();

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
  /// it. Must be safe to call twice. Not a substitute for [start]: a feed that
  /// was never started has nothing to resume.
  void resume();

  /// Release the transport. Whoever created this feed calls it — and the
  /// consumer is the one that creates it, so that the observation cannot
  /// outlive the screen that wanted it.
  void dispose();
}
