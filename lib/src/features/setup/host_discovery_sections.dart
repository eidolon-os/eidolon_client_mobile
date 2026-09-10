import 'package:flutter/material.dart';

/// Both discovery entrances distinguish registration from live connectivity.
/// Callers must verify Host identity before placing a row in either group.
class HostDiscoverySections extends StatelessWidget {
  const HostDiscoverySections({
    super.key,
    required this.available,
    required this.added,
    this.unidentified = const [],
    this.identifying = false,
  });

  final List<Widget> available;
  final List<Widget> added;
  final List<Widget> unidentified;
  final bool identifying;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!identifying && added.isNotEmpty && available.isEmpty) ...[
            Text(unidentified.isEmpty
                ? '发现 ${added.length} 台已添加主机，未发现新的主机。'
                : '发现 ${added.length} 台已添加主机，另有 ${unidentified.length} 台暂未识别。'),
            const SizedBox(height: 12),
          ],
          if (available.isNotEmpty) ...[
            Text('可添加的主机', style: Theme.of(context).textTheme.titleMedium),
            ...available,
            const SizedBox(height: 12),
          ],
          if (added.isNotEmpty) ...[
            Text('已添加的主机', style: Theme.of(context).textTheme.titleMedium),
            ...added,
            const SizedBox(height: 12),
          ],
          if (unidentified.isNotEmpty) ...[
            Text(identifying ? '正在识别的主机' : '暂未识别的主机',
                style: Theme.of(context).textTheme.titleMedium),
            ...unidentified,
          ],
        ],
      );
}
