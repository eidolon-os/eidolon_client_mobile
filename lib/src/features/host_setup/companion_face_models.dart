/// What is known about an Eidolon's face, without carrying the face.
///
/// A screen asks this before deciding whether a photograph is worth fetching,
/// and asks it again to find out whether the one it holds is still current.
/// [sha256] is what makes the second question answerable without moving a
/// second photograph across to compare.
class CompanionFaceState {
  const CompanionFaceState({
    required this.companionId,
    required this.hasFace,
    this.sha256,
    this.updatedAt,
  });

  factory CompanionFaceState.fromJson(Map<String, dynamic> value) {
    final companionId = value['companion_id'];
    final hasFace = value['has_face'];
    if (companionId is! String || companionId.isEmpty || hasFace is! bool) {
      throw const FormatException('主机返回的「脸」状态不符合契约');
    }
    final sha256 = value['sha256'];
    final updatedAt = value['updated_at'];
    return CompanionFaceState(
      companionId: companionId,
      hasFace: hasFace,
      sha256: sha256 is String && sha256.isNotEmpty ? sha256 : null,
      updatedAt: updatedAt is String && updatedAt.isNotEmpty ? updatedAt : null,
    );
  }

  final String companionId;
  final bool hasFace;
  final String? sha256;
  final String? updatedAt;

  /// Whether a copy identified by [heldSha256] is the face the Host now has.
  bool matches(String? heldSha256) =>
      hasFace && heldSha256 != null && heldSha256 == sha256;
}
