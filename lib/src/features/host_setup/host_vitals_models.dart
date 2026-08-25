import '../../generated/management_v1.dart';

/// How the machine holding this Eidolon is doing.
///
/// Already phrased and already judged by the Host: this side does no
/// arithmetic on bytes and applies no thresholds of its own. Doing either
/// here would put the same decision in two places, and the two would drift.
///
/// Built from the generated view rather than from a map. What is hand-written
/// here is the part the wire has no words for — a concern is an enum this app
/// switches on, and "which of these needs attention" is a question a screen
/// asks — while the shape of the answer stays generated from the one contract.
enum VitalConcern { none, watch, act }

class HostVital {
  const HostVital({
    required this.name,
    required this.reading,
    this.concern = VitalConcern.none,
    this.unavailableReason,
  });

  factory HostVital.fromView(VitalView view) => HostVital(
        name: view.name,
        reading: view.reading,
        // A concern this version has never heard of reads as "none" rather
        // than throwing: a Host that grows a fourth level should not blank the
        // screen that was showing the other three.
        concern: switch (view.concern) {
          'watch' => VitalConcern.watch,
          'act' => VitalConcern.act,
          _ => VitalConcern.none,
        },
        unavailableReason: (view.unavailableReason ?? '').isEmpty
            ? null
            : view.unavailableReason,
      );

  final String name;
  final String reading;
  final VitalConcern concern;

  /// Why there is no reading. Present only when the Host could not take one —
  /// which is a third state, not a bad reading and not a good one.
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;
}

class HostVitals {
  const HostVitals({required this.observedAt, required this.vitals});

  factory HostVitals.fromView(HostVitalsView view) => HostVitals(
        observedAt: DateTime.tryParse(view.observedAt)?.toUtc(),
        vitals: (view.vitals ?? const <VitalView>[])
            .map(HostVital.fromView)
            .toList(growable: false),
      );

  final DateTime? observedAt;
  final List<HostVital> vitals;

  /// Anything the Host said is worth acting on, in the order it said it.
  List<HostVital> get needingAttention =>
      vitals.where((vital) => vital.concern != VitalConcern.none).toList();
}
