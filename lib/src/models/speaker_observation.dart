/// One advisory turn result. This never selects a Person or a memory realm.
class SpeakerObservationView {
  const SpeakerObservationView(
      {required this.turnId,
      required this.status,
      required this.reason,
      required this.issuedAt,
      required this.expiresAt,
      this.displayName,
      this.sequence});
  final String turnId, status, reason;
  final int? sequence;
  final String? displayName;
  final double issuedAt, expiresAt;

  static SpeakerObservationView? parse(Map<String, dynamic> value,
      {required String? conversationId, required double now}) {
    if (conversationId == null ||
        value['conversation_id'] != conversationId ||
        value['schema_version'] != 1) {
      return null;
    }
    // A visible-person result must never occupy the speaker label.
    if ((value['subject_role'] ?? 'speaker') != 'speaker') return null;
    final modalities = value['modalities'];
    if (modalities != null &&
        (modalities is! List ||
            modalities.length != 1 ||
            modalities.first != 'voice')) {
      return null;
    }
    final sequence = value['sequence'];
    if (sequence != null && (sequence is! int || sequence < 1)) return null;
    final status = value['status'];
    final turn = value['turn_id'];
    final issued = value['issued_at'];
    final expires = value['expires_at'];
    final name = value['display_name'];
    if (!['identified', 'unknown', 'uncertain', 'unavailable']
            .contains(status) ||
        turn is! String ||
        turn.isEmpty ||
        turn.length > 128 ||
        issued is! num ||
        expires is! num ||
        !issued.isFinite ||
        !expires.isFinite ||
        expires <= now ||
        issued > now + 5 ||
        expires - issued > 10.1 ||
        expires <= issued ||
        value['reason'] is! String) {
      return null;
    }
    if (status == 'identified' &&
        (name is! String || name.isEmpty || name.length > 128)) {
      return null;
    }
    return SpeakerObservationView(
        turnId: turn,
        sequence: sequence as int?,
        status: status as String,
        reason: value['reason'] as String,
        issuedAt: issued.toDouble(),
        expiresAt: expires.toDouble(),
        displayName: status == 'identified' ? name as String : null);
  }

  String get label => switch (status) {
        'identified' => '刚才的声音：$displayName',
        'unknown' => '未识别到已录入用户',
        'uncertain' =>
          reason == 'no_enrolled_voices' ? '尚未录入用户声音' : '本句暂时无法确认身份',
        _ => reason == 'recognition_pending'
            ? '本句身份尚未确认，对话可以继续'
            : '声音识别暂不可用，对话可以继续',
      };
}

/// Session high-water mark survives display expiry, so old packets cannot
/// restore a name after the label has disappeared. Legacy senders use time.
class SpeakerObservationCursor {
  String? _session;
  int? _sequence;
  double _issuedAt = -1;

  bool accept(SpeakerObservationView value, {required String sessionId}) {
    if (_session != sessionId) {
      _session = sessionId;
      _sequence = null;
      _issuedAt = -1;
    }
    final sequence = value.sequence;
    if (sequence != null) {
      if (_sequence != null && sequence <= _sequence!) return false;
      _sequence = sequence;
    } else {
      if (_sequence != null || value.issuedAt <= _issuedAt) return false;
    }
    if (value.issuedAt > _issuedAt) _issuedAt = value.issuedAt;
    return true;
  }
}
