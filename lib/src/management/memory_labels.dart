/// Product language for a Memory room.
///
/// Rooms created by ingestion can contain session or request identifiers. They
/// are useful for tracing on the Host, but they are not categories a person can
/// recognise. Every Memory surface uses this one translation so a room does not
/// become friendly in the library and turn back into an ID in the timeline.
String memoryRoomLabel(String roomId) {
  final value = roomId.trim();
  final lower = value.toLowerCase();
  if (lower.startsWith('userconfirm')) return '你明确让它记住的';
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
