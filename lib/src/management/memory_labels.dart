/// Product language for a Memory room.
///
/// Rooms created by ingestion can contain session or request identifiers. They
/// are useful for tracing on the Host, but they are not categories a person can
/// recognise. Every Memory surface uses this one translation so a room does not
/// become friendly in the library and turn back into an ID in the timeline.
String memoryRoomLabel(String roomId) {
  final value = roomId.trim();
  final lower = value.toLowerCase();
  if (lower.startsWith('userconfirm')) return '已整理的记录';
  if (lower.startsWith('turn:') || lower.startsWith('conversation:')) {
    return '对话中记下的';
  }
  if (value.isEmpty || value == '?') return '未分类记忆';
  if (value.contains('/') ||
      value.contains(':') ||
      RegExp(r'[0-9a-f]{12,}', caseSensitive: false).hasMatch(value)) {
    return '其他记忆';
  }
  return value;
}

/// Product language for the backend's compact memory-type token.
String memoryTypeLabel(String memoryType) {
  switch (memoryType.trim().toLowerCase()) {
    case 'preference':
      return '偏好';
    case 'profile':
      return '个人信息';
    case 'interaction':
      return '相处方式';
    case 'relationship':
      return '重要关系';
    case 'emotion':
      return '情绪';
    case 'event':
      return '经历';
    case 'work':
      return '工作与学习';
    case 'goal':
      return '目标';
    case 'health':
      return '健康';
    case 'fact':
      return '事实';
    default:
      return memoryType.trim().isEmpty ? '' : '其他';
  }
}

/// Product language for a relation in the memory graph.
///
/// The Host's graph speaks a fixed ontology (`eidolon_memory_contracts.kg`
/// `KgPredicate`) in English tokens; a person reading 「我 · likes · 乌龙茶」 is
/// reading the database. Unknown tokens — a newer Host — fall back to the token
/// itself rather than disappearing.
String memoryPredicateLabel(String predicate) {
  const labels = <String, String>{
    'child_of': '是…的孩子',
    'parent_of': '是…的父母',
    'partner_of': '的伴侣是',
    'sibling_of': '的兄弟姐妹是',
    'friend_of': '的朋友是',
    'colleague_of': '的同事是',
    'works_at': '在…工作',
    'lives_in': '住在',
    'studies_at': '在…上学',
    'holds_role': '担任',
    'born_in': '出生在',
    'likes': '喜欢',
    'dislikes': '不喜欢',
    'prefers': '更喜欢',
    'does': '会做',
    'practices': '经常',
    'owns': '拥有',
    'uses': '使用',
    'promised': '答应过',
    'committed_to': '承诺',
    'planned_to': '打算',
    'has_state': '现在',
    'has_emotion': '感到',
    'has_concern': '在意',
    'worried_about': '担心',
    'struggles_with': '正为…困扰',
    'has_health_condition': '健康状况',
    'takes_medication': '在服用',
    'has_symptom': '有症状',
    'attended': '参加过',
    'experienced': '经历过',
    'achieved': '做到了',
  };
  return labels[predicate.trim()] ?? predicate;
}
