import '../protocol/eidolon_protocol.dart';

/// The device's selected operating mode, declared before acquiring a room.
enum ConversationMode {
  ptt(interactionModePtt, '按住说话', '按住时收音，松开发送'),
  halfDuplex(interactionModeHalfDuplex, '轮流说话', '自动收音，伙伴说话时暂停聆听'),
  fullDuplex(interactionModeFullDuplex, '自由对话', '自然交谈，可以随时打断伙伴');

  const ConversationMode(this.wireValue, this.label, this.description);
  final String wireValue;
  final String label;
  final String description;
}
