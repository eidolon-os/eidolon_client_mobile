/// One advisory turn result. This never selects a Person or a memory realm.
class SpeakerObservationView {
  const SpeakerObservationView(
      {required this.turnId,
      required this.status,
      required this.reason,
      required this.issuedAt,
      required this.expiresAt,
      this.displayName});
  final String turnId, status, reason;
  final String? displayName;
  final double issuedAt, expiresAt;

  static SpeakerObservationView? parse(Map<String, dynamic> value,
      {required String? conversationId, required double now}) {
    if (conversationId == null ||
        value['conversation_id'] != conversationId ||
        value['schema_version'] != 1) {
      return null;
    }
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
        _ => '声音识别暂不可用，对话可以继续',
      };
}
