/// One thing an Eidolon remembers, as its Owner reads it.
///
/// A sentence and, when the Host knows it, when it was laid down. What memory
/// stores carries more — which wing it lives in, how it was scored, what found
/// it — and none of that is what a person asked.
class Recollection {
  const Recollection({required this.text, this.rememberedAt});

  factory Recollection.fromJson(Map<String, dynamic> value) {
    final text = value['text'];
    if (text is! String) {
      throw const FormatException('主机返回的记忆不符合契约');
    }
    final rememberedAt = value['remembered_at'];
    return Recollection(
      text: text,
      rememberedAt: rememberedAt is String && rememberedAt.isNotEmpty
          ? DateTime.tryParse(rememberedAt)?.toUtc()
          : null,
    );
  }

  final String text;
  final DateTime? rememberedAt;
}

class Recollections {
  const Recollections({required this.query, required this.items});

  factory Recollections.fromJson(Map<String, dynamic> value) {
    final query = value['query'];
    final items = value['recollections'];
    if (query is! String || items is! List) {
      throw const FormatException('主机返回的记忆不符合契约');
    }
    return Recollections(
      query: query,
      items: items
          .map((item) => Recollection.fromJson(
                Map<String, dynamic>.from(item as Map),
              ))
          .toList(growable: false),
    );
  }

  final String query;
  final List<Recollection> items;
}
