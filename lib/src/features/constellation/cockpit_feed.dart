import 'dart:async';

import 'cockpit_models.dart';

/// Where the cockpit gets its facts.
///
/// Two implementations are expected: the mock world below, and — once the Local
/// API publishes `GET /api/local/v1/mission-control/snapshot` and its event
/// stream — a pinned adapter that fills exactly these structures. Keeping the
/// seam here is the point: the drawing must not learn anything about transport,
/// and the transport must not get a say in geometry.
abstract class CockpitFeed {
  CockpitSnapshot get snapshot;

  /// Whole-snapshot replacements. The cockpit re-derives everything from these.
  Stream<CockpitSnapshot> get updates;

  /// Directed darts for events observed since the last snapshot. Separate from
  /// [updates] because a pulse is a moment, not a state: replaying a snapshot
  /// must never re-fire one.
  Stream<CockpitPulse> get pulses;

  Future<void> refresh();

  void dispose();
}
