/// Product language for a Memory room.
///
/// Rooms created by ingestion can contain session or request identifiers. They
/// are useful for tracing on the Host, but they are not categories a person can
/// recognise. Every Memory surface uses this one translation so a room does not
/// become friendly in the library and turn back into an ID in the timeline.
///
/// The model names a fact's room by the convention in Memory's steward prompt
/// (`eidolon_memory/eidolon/memory/config/prompts/memory_steward.md`, "Room 命名
/// 规范"): a kind prefix and a free topic, as in `preference_music` or
/// `person_铁锤`. The kind becomes the category; a topic is kept only when a
/// person can read it. A slug nothing here knows is never shown as it is.
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
  final separator = lower.indexOf('_');
  final kind = separator < 0 ? lower : lower.substring(0, separator);
  final topic = separator < 0 ? '' : value.substring(separator + 1);
  final category = _roomKinds[kind];
  if (category != null) {
    if (lower == 'profile_core' || kind == 'emotion' || kind == 'privacy') {
      return category;
    }
    final readable = _readableTopic(topic);
    return readable == null ? category : '$category · $readable';
  }
  // Free text a person wrote or said, kept as it was.
  return _readableTopic(value) ?? '其他记忆';
}

const _roomKinds = <String, String>{
  'profile': '基本情况',
  'person': '人物',
  'pet': '宠物',
  'project': '项目',
  'emotion': '心情',
  'event': '经历',
  'preference': '偏好',
  'privacy': '封存的内容',
  'home': '家里的事',
  'household': '家里的事',
  'topic': '话题',
};

/// A topic a person can read: one with Chinese in it, its underscores as
/// spaces. An English slug or a date is the model's filing, not a name.
String? _readableTopic(String topic) {
  if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(topic)) return null;
  final words = topic
      .split('_')
      .where((w) => w.isNotEmpty && !RegExp(r'^\d+$').hasMatch(w))
      .join(' ')
      .trim();
  return words.isEmpty ? null : words;
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

/// Known instants in the person's local time; unknown dates stay unknown.
String memoryTimestampLabel(String? value, {bool includeTime = true}) {
  final when = value == null ? null : DateTime.tryParse(value)?.toLocal();
  if (when == null) return '未记录';
  final date = '${when.year}-${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')}';
  if (!includeTime) return date;
  return '$date ${when.hour.toString().padLeft(2, '0')}:'
      '${when.minute.toString().padLeft(2, '0')}';
}

/// filed_at on an old record can be an event date, so leave it neutral.
String memoryTimeSourceLabel(String? source) => switch (source) {
      'occurred_at' || 'valid_from' => '事件时间',
      'indexed_at' || 'created_at' => '记下时间',
      'updated_at' || 'last_modified' => '变更时间',
      _ => '记录日期',
    };
