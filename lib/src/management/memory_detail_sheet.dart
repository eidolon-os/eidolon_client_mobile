import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'memory_labels.dart';

/// One presentation of a memory's evidence, shared by every way into memory.
Future<void> showMemoryDetail(
  BuildContext context, {
  required String content,
  MemoryProvenance? provenance,
  String? recordedAt,
  String? category,
  String? validFrom,
  String? validTo,
  String title = '记忆依据',
}) {
  FocusScope.of(context).unfocus();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .72,
      minChildSize: .35,
      maxChildSize: .94,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (category != null && category.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(category, style: Theme.of(context).textTheme.labelLarge),
          ],
          const SizedBox(height: 20),
          SelectableText(content),
          const Divider(height: 32),
          Text('首次记下：${memoryTimestampLabel(provenance?.learnedAt)}'),
          if (provenance?.lastModifiedAt != null)
            Text('最近变更：${memoryTimestampLabel(provenance?.lastModifiedAt)}'),
          if (provenance?.occurredAt != null)
            Text('事件时间：${memoryTimestampLabel(provenance?.occurredAt)}'),
          if (provenance?.learnedAt == null &&
              provenance?.occurredAt == null &&
              recordedAt != null)
            Text('记录中的时间：${memoryTimestampLabel(recordedAt)}'),
          if (validFrom != null)
            Text('关系生效：${memoryTimestampLabel(validFrom)}'),
          if (validTo != null) Text('关系结束：${memoryTimestampLabel(validTo)}'),
          const Divider(height: 32),
          Text('原话', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            (provenance?.sourceQuote ?? '').trim().isEmpty
                ? '这条记忆未保存原话'
                : provenance!.sourceQuote!,
          ),
        ],
      ),
    ),
  );
}
