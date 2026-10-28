/// Display-only runtime feedback; never an identity or permission grant.
class MemoryScopeView {
  const MemoryScopeView(this.state, this.sequence, this.expiresAt);
  final String state;
  final int sequence;
  final double expiresAt;
  String get label => switch (state) {
        'active' => '本轮使用当前人物的个人记忆',
        'closing' => '正在停止已撤销的个人记忆访问',
        _ => '本轮不使用个人记忆',
      };
  static MemoryScopeView? parse(Map<String, dynamic> value,
      {required String? sessionId, required double now}) {
    final sequence = value['sequence'];
    final issued = value['issued_at'];
    final expires = value['expires_at'];
    final state = value['state'];
    if (value['schema_version'] != 1 ||
        sessionId == null ||
        value['session_id'] != sessionId ||
        sequence is! int ||
        sequence < 1 ||
        issued is! num ||
        expires is! num ||
        !issued.isFinite ||
        !expires.isFinite ||
        issued > now + 1 ||
        expires <= now ||
        expires - issued <= 0 ||
        expires - issued > 10 ||
        !['active', 'disabled', 'closing'].contains(state)) return null;
    if (state == 'active' &&
        (value['person_id'] is! String ||
            (value['person_id'] as String).isEmpty)) return null;
    return MemoryScopeView(state as String, sequence, expires.toDouble());
  }
}
