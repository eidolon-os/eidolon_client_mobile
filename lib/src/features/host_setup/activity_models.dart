/// What has happened on this Host lately, as its Owner reads it.
///
/// The Host answers in terms of what happened and who did it, not in the
/// wording a screen shows. The sentence is composed here, next to the rest of
/// this app's language, so the Host does not have to know Chinese to be able
/// to say a device arrived.
enum HostMomentKind {
  /// A device announced itself and is waiting to be accepted.
  deviceKnocked,
  deviceAccepted,
  deviceRemoved,

  /// Something this app is too old to have a word for. It still happened.
  other,
}

enum HostMomentActor { owner, device, host }

/// Tolerant on purpose: a Host newer than this app may record acts this
/// version has never heard of, and an unrecognised act is still an act. What
/// is refused is a malformed record, not an unfamiliar one.
HostMomentKind _kind(Object? value) => switch (value) {
      'device-knocked' => HostMomentKind.deviceKnocked,
      'device-accepted' => HostMomentKind.deviceAccepted,
      'device-removed' => HostMomentKind.deviceRemoved,
      _ => HostMomentKind.other,
    };

HostMomentActor _actor(Object? value) => switch (value) {
      'owner' => HostMomentActor.owner,
      'device' => HostMomentActor.device,
      _ => HostMomentActor.host,
    };

class HostMoment {
  const HostMoment({
    required this.eventId,
    required this.occurredAt,
    required this.kind,
    required this.actor,
    required this.deviceId,
    this.deviceName = '',
    this.deviceKind = '',
    this.reason = '',
    this.eventType = '',
  });

  factory HostMoment.fromJson(Map<String, dynamic> value) {
    final eventId = value['event_id'];
    final occurredAt = value['occurred_at'];
    final deviceId = value['device_id'];
    if (eventId is! String ||
        eventId.isEmpty ||
        occurredAt is! String ||
        deviceId is! String ||
        deviceId.isEmpty) {
      throw const FormatException('主机返回的记录不符合契约');
    }
    final at = DateTime.tryParse(occurredAt);
    if (at == null) {
      throw const FormatException('主机返回的记录没有可读的时间');
    }
    return HostMoment(
      eventId: eventId,
      occurredAt: at.toUtc(),
      kind: _kind(value['kind']),
      actor: _actor(value['actor']),
      deviceId: deviceId,
      deviceName: value['device_name'] is String
          ? value['device_name'] as String
          : '',
      deviceKind: value['device_kind'] is String
          ? value['device_kind'] as String
          : '',
      reason: value['reason'] is String ? value['reason'] as String : '',
      eventType: value['event_type'] is String
          ? value['event_type'] as String
          : '',
    );
  }

  final String eventId;
  final DateTime occurredAt;
  final HostMomentKind kind;
  final HostMomentActor actor;

  /// Carried for the technical corner of a screen. It is never the name.
  final String deviceId;

  /// Empty when the Host could not say what the device is called. It is left
  /// empty rather than filled with the identifier: an identifier is what
  /// someone falls back to when nobody will tell them what a thing is.
  final String deviceName;
  final String deviceKind;
  final String reason;
  final String eventType;
}

class HostActivity {
  const HostActivity({required this.coverage, required this.moments});

  factory HostActivity.fromJson(Map<String, dynamic> value) {
    final coverage = value['coverage'];
    final moments = value['moments'];
    if (coverage is! String || moments is! List) {
      throw const FormatException('主机返回的动态不符合契约');
    }
    return HostActivity(
      coverage: coverage,
      moments: moments
          .map((item) => HostMoment.fromJson(Map<String, dynamic>.from(
                item as Map,
              )))
          .toList(growable: false),
    );
  }

  /// What this record covers, said by the Host. Only device lifecycle today —
  /// this Host keeps no presence signal and no runtime telemetry, so a screen
  /// must not let a short list imply a quiet Host.
  final String coverage;
  final List<HostMoment> moments;
}

/// What happened, in one line.
///
/// The device is named. Where the Host could not name it, the sentence says
/// "一台设备" rather than reciting an identifier at someone.
String hostMomentSentence(HostMoment moment) {
  final name = moment.deviceName.isNotEmpty ? moment.deviceName : '一台设备';
  final byOwner = moment.actor == HostMomentActor.owner;
  return switch (moment.kind) {
    HostMomentKind.deviceKnocked => '$name 敲了门',
    HostMomentKind.deviceAccepted =>
      byOwner ? '你接受了 $name' : '$name 被接受了',
    HostMomentKind.deviceRemoved => byOwner ? '你移除了 $name' : '$name 被移除了',
    HostMomentKind.other => '$name 有一次变动',
  };
}

/// When it happened, in this phone's own time.
///
/// Today and yesterday are said as such, because that is how someone asking
/// "did it arrive?" holds time. Anything older gets a date.
String hostMomentTime(DateTime at, {required DateTime now}) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final clock = '${_two(local.hour)}:${_two(local.minute)}';
  final days = today.difference(day).inDays;
  if (days == 0) return '今天 $clock';
  if (days == 1) return '昨天 $clock';
  return '${local.month}月${local.day}日 $clock';
}

String _two(int number) => number.toString().padLeft(2, '0');

/// The rest of what is known about a moment, for people who want it.
String hostMomentDetail(HostMoment moment) {
  final parts = <String>[
    if (moment.kind == HostMomentKind.deviceKnocked) '等待你接受',
    if (moment.reason == 'owner-removed') '由你发起'
    else if (moment.reason.isNotEmpty) '原因：${moment.reason}',
    if (moment.deviceKind.isNotEmpty) moment.deviceKind,
    moment.deviceId,
  ];
  return parts.join(' · ');
}
