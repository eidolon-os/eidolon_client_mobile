import '../../generated/management_v1.dart';

/// What has been done to this Owner's things lately, as they read it.
///
/// The Host records facts — an action, what it was done to, when, and what that
/// thing is called. **The sentence is composed here**, next to the rest of this
/// app's language, so a Host does not have to know Chinese to be able to say
/// that an Eidolon was put away.
///
/// It replaced a device-shaped model that read a route which no longer exists.
/// Devices arriving and leaving belong to the device line and had their producer
/// removed; what this reads is the governance record every change to a Companion
/// has been writing all along, in the same transaction as the change itself.
enum HostMomentKind {
  companionArrived,
  companionPutAway,
  companionBack,
  companionGone,
  answeringChanged,
  faceChanged,
  memoryCatalogued,
  ownerNamed,

  /// Something this app is too old to have a word for. It still happened.
  other,
}

/// Tolerant on purpose: a Host newer than this app records acts this version has
/// never heard of, and an unrecognised act is still an act. A history with holes
/// in it is worse than a history with an unfamiliar line in it.
HostMomentKind _kind(String action) => switch (action) {
      'companion.workspace.initialized' => HostMomentKind.companionArrived,
      // The archive is two facts in one transaction — the record says the
      // retirement happened, because it did — and `collapseMoments` is what
      // keeps that from being two lines in front of a person.
      'companion.retirement_begun' => HostMomentKind.companionPutAway,
      'companion.archived' => HostMomentKind.companionPutAway,
      'companion.restored' => HostMomentKind.companionBack,
      'companion.deleted' => HostMomentKind.companionGone,
      'owner.default_companion_changed' => HostMomentKind.answeringChanged,
      'companion.face_asset.activated' => HostMomentKind.faceChanged,
      'companion.face_asset.cleared' => HostMomentKind.faceChanged,
      'memory_realm.cataloged' => HostMomentKind.memoryCatalogued,
      'owner.created' => HostMomentKind.ownerNamed,
      'owner.updated' => HostMomentKind.ownerNamed,
      _ => HostMomentKind.other,
    };

class HostMoment {
  const HostMoment({
    required this.eventId,
    required this.occurredAt,
    required this.action,
    required this.subjectType,
    required this.subjectId,
    required this.subjectName,
    required this.outcome,
    this.detail = const {},
  });

  factory HostMoment.fromView(ActivityMomentView view) => HostMoment(
        eventId: view.eventId,
        occurredAt:
            DateTime.tryParse(view.occurredAt)?.toUtc() ?? DateTime.now().toUtc(),
        action: view.action,
        subjectType: view.subjectType,
        subjectId: view.subjectId,
        subjectName: view.subjectName ?? '',
        outcome: view.outcome,
        detail: view.detail ?? const {},
      );

  final String eventId;
  final DateTime occurredAt;

  /// The Host's own word for what happened. Kept as given, so a line this app
  /// cannot phrase can still be shown and still be recognised later.
  final String action;
  final String subjectType;

  /// Carried for the technical corner of a screen. It is never the name.
  final String subjectId;

  /// Empty when the Owner never named it, or when it no longer exists.
  final String subjectName;
  final String outcome;
  final Map<String, String> detail;

  HostMomentKind get kind => _kind(action);

  bool get succeeded => outcome == 'success';
}

class HostActivity {
  const HostActivity({required this.moments, this.nextCursor});

  factory HostActivity.fromView(ActivityView view) => HostActivity(
        moments: collapseMoments(
          (view.moments).map(HostMoment.fromView).toList(growable: false),
        ),
        nextCursor: view.nextCursor,
      );

  final List<HostMoment> moments;

  /// Stored and sent back for the page before this one. Null means this is as
  /// far back as the Host still holds — **not** that nothing happened before,
  /// and a screen must not say otherwise.
  final String? nextCursor;
}

/// One act, one line.
///
/// Putting an Eidolon away writes two facts in one transaction — it retires and
/// then it is archived — because the record has to say both happened. A person
/// did one thing, so they see one line. The retirement is dropped only when the
/// archive for the same Eidolon is right beside it; a retirement left on its own
/// is a real state and keeps its line.
List<HostMoment> collapseMoments(List<HostMoment> moments) {
  final kept = <HostMoment>[];
  for (var index = 0; index < moments.length; index += 1) {
    final moment = moments[index];
    if (moment.action != 'companion.retirement_begun') {
      kept.add(moment);
      continue;
    }
    // Newest first, so the archive sits *above* the retirement it finished.
    final archived = index > 0 &&
        moments[index - 1].action == 'companion.archived' &&
        moments[index - 1].subjectId == moment.subjectId;
    if (!archived) kept.add(moment);
  }
  return kept;
}

/// What happened, in words.
///
/// An Eidolon nobody named is 「一个 Eidolon」 rather than its identifier: an
/// identifier is what someone falls back to when nobody will tell them what a
/// thing is.
String hostMomentSentence(HostMoment moment) {
  // Always bracketed, named or not: 「」 ends the phrase in Chinese punctuation,
  // so the templates below need no spacing rules around a Latin name.
  final name = moment.subjectName.isNotEmpty
      ? '「${moment.subjectName}」'
      : (moment.subjectType == 'companion' ? '「还没起名的 Eidolon」' : '你');
  // Who took over, when the Host said. For "who answers now changed" the
  // subject is the Owner and the meaning is entirely in this field.
  final successor = moment.detail['companion_id_name'] ??
      moment.detail['replacement_companion_id_name'];
  return switch (moment.kind) {
    HostMomentKind.companionArrived => '$name来了',
    HostMomentKind.companionPutAway => successor == null
        ? '你把$name收了起来'
        : '你把$name收了起来，改由「$successor」回答',
    HostMomentKind.companionBack => '$name回来了',
    HostMomentKind.companionGone => '$name被删除了',
    HostMomentKind.answeringChanged => successor == null
        // The Host did not say who took over. Better to say that much than to
        // put the Owner's own name where a Companion's belongs.
        ? '没有指名的时候，改由另一个 Eidolon 回答'
        : '没有指名的时候，改由「$successor」回答',
    HostMomentKind.faceChanged => '$name换了一张脸',
    HostMomentKind.memoryCatalogued => '记忆的地方准备好了',
    HostMomentKind.ownerNamed => '这台主机认了你',
    // Said plainly rather than dressed up: this app does not know what happened,
    // and pretending to would be worse than admitting it.
    HostMomentKind.other => '$name有一次变动（${moment.action}）',
  };
}

/// When it happened, in this phone's own time.
///
/// Today and yesterday are said as such, because that is how someone asking
/// "did it happen?" holds time. Anything older gets a date.
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
