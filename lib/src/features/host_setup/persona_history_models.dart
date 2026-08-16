/// One thing this Eidolon has been.
///
/// There is no version number and no hash here, because there is none in what
/// the Host sends: those are how a Companion is built, and what a person
/// wonders is when it changed and what changed.
class PersonaChapter {
  const PersonaChapter({
    required this.chapterId,
    required this.changedAt,
    required this.whatChanged,
    required this.restoredFrom,
    required this.isCurrent,
  });

  factory PersonaChapter.fromJson(Map<String, dynamic> value) {
    final chapterId = value['chapter_id'];
    final changedAt = value['changed_at'];
    final whatChanged = value['what_changed'];
    final restoredFrom = value['restored_from'];
    final isCurrent = value['is_current'];
    if (chapterId is! String ||
        chapterId.isEmpty ||
        changedAt is! String ||
        whatChanged is! String ||
        (restoredFrom != null && restoredFrom is! int) ||
        isCurrent is! bool) {
      throw const FormatException('主机返回了无法识别的人格记录');
    }
    final moment = DateTime.tryParse(changedAt);
    if (moment == null) {
      throw const FormatException('人格记录缺少可解析的时间');
    }
    return PersonaChapter(
      chapterId: chapterId,
      changedAt: moment.toUtc(),
      whatChanged: whatChanged.trim(),
      restoredFrom: restoredFrom as int?,
      isCurrent: isCurrent,
    );
  }

  final String chapterId;
  final DateTime changedAt;

  /// What changed, in the words recorded with the change. Empty when nothing
  /// was written down — and it stays empty. A sentence about who your Eidolon
  /// became is not something this screen may compose on its behalf.
  final String whatChanged;

  /// Set when this chapter exists because someone went back to an earlier one.
  final int? restoredFrom;
  final bool isCurrent;
}

class PersonaHistory {
  const PersonaHistory({required this.companionId, required this.chapters});

  factory PersonaHistory.fromJson(Map<String, dynamic> value) {
    final companionId = value['companion_id'];
    final chapters = value['chapters'];
    if (companionId is! String || companionId.isEmpty || chapters is! List) {
      throw const FormatException('主机返回了无法识别的人格历史');
    }
    return PersonaHistory(
      companionId: companionId,
      chapters: chapters
          .map(
            (chapter) =>
                PersonaChapter.fromJson(Map<String, dynamic>.from(chapter as Map)),
          )
          .toList(growable: false),
    );
  }

  final String companionId;

  /// Newest first, as the Host orders them.
  final List<PersonaChapter> chapters;

  PersonaChapter? get current =>
      chapters.where((chapter) => chapter.isCurrent).firstOrNull;
}
