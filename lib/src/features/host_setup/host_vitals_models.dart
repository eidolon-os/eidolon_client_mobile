/// How the machine holding this Eidolon is doing.
///
/// Already phrased and already judged by the Host: this side does no
/// arithmetic on bytes and applies no thresholds of its own. Doing either
/// here would put the same decision in two places, and the two would drift.
enum VitalConcern { none, watch, act }

class HostVital {
  const HostVital({
    required this.name,
    required this.reading,
    this.concern = VitalConcern.none,
    this.unavailableReason,
  });

  factory HostVital.fromJson(Map<String, dynamic> value) {
    final name = value['name'];
    final reading = value['reading'];
    if (name is! String || name.isEmpty || reading is! String) {
      throw const FormatException('主机返回的状态项不符合契约');
    }
    final reason = value['unavailable_reason'];
    return HostVital(
      name: name,
      reading: reading,
      concern: switch (value['concern']) {
        'watch' => VitalConcern.watch,
        'act' => VitalConcern.act,
        _ => VitalConcern.none,
      },
      unavailableReason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }

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

  factory HostVitals.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'local.host-vitals' ||
        value['contract_version'] != '1') {
      throw const FormatException('主机返回了无效的状态');
    }
    final raw = value['vitals'];
    if (raw is! List) {
      throw const FormatException('主机返回了无效的状态');
    }
    return HostVitals(
      observedAt: DateTime.tryParse('${value['observed_at']}')?.toUtc(),
      vitals: raw
          .map((item) =>
              HostVital.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(growable: false),
    );
  }

  final DateTime? observedAt;
  final List<HostVital> vitals;

  /// Anything the Host said is worth acting on, in the order it said it.
  List<HostVital> get needingAttention =>
      vitals.where((vital) => vital.concern != VitalConcern.none).toList();
}
