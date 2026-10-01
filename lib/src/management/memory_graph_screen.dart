import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'memory_labels.dart';
import 'memory_detail_sheet.dart';
import 'refusal_notice.dart';

class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen({super.key, required this.load, this.scopeLabel});
  final String? scopeLabel;

  final Future<MemoryGraphView> Function(
      {String? cursor, required bool history}) load;

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> {
  MemoryGraphView? _graph;
  Object? _error;
  bool _history = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read({bool append = false}) async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final graph = await widget.load(
        cursor: append ? _graph?.nextCursor : null,
        history: _history,
      );
      if (!mounted) return;
      setState(() {
        _graph = append && _graph != null ? _mergePages(_graph!, graph) : graph;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    return Scaffold(
      key: const Key('memory-graph-screen'),
      appBar: AppBar(title: const Text('记忆关系图')),
      body: Column(children: [
        SwitchListTile(
          key: const Key('memory-graph-history'),
          title: const Text('查看历史关系'),
          subtitle: widget.scopeLabel == null ? null : Text(widget.scopeLabel!),
          value: _history,
          onChanged: _busy
              ? null
              : (value) {
                  setState(() {
                    _history = value;
                    _graph = null;
                  });
                  _read();
                },
        ),
        if (graph != null && graph.nodes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 16, runSpacing: 4, children: [
                Text('${graph.nodes.length} 个关联 · ${graph.edges.length} 条关系'),
                if (_history)
                  const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle, size: 8, color: Color(0xFF94A3B8)),
                    SizedBox(width: 6),
                    Text('已结束关系'),
                  ]),
              ]),
            ),
          ),
        Expanded(
            child: graph == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : RefusalNotice(
                            error: _error!, subject: '记忆关系图', onRetry: _read))
                : graph.nodes.isEmpty
                    ? const Center(child: Text('还没有形成关系记忆'))
                    : LayoutBuilder(builder: (context, bounds) {
                        final canvas = _GraphCanvas(graph: graph);
                        final relations = _RelationList(
                          graph: graph,
                          error: _error,
                          busy: _busy,
                          onLoadMore: () => _read(append: true),
                        );
                        if (bounds.maxWidth >= 600) {
                          return Row(children: [
                            Expanded(flex: 3, child: canvas),
                            Expanded(flex: 2, child: relations),
                          ]);
                        }
                        return Column(children: [
                          Expanded(flex: 3, child: canvas),
                          Expanded(flex: 2, child: relations),
                        ]);
                      })),
      ]),
    );
  }
}

MemoryGraphView _mergePages(MemoryGraphView previous, MemoryGraphView next) {
  final edges = {
    for (final edge in [...previous.edges, ...next.edges]) edge.edgeId: edge,
  }.values.toList();
  final labels = {
    for (final node in [...previous.nodes, ...next.nodes])
      node.nodeId: node.label,
  };
  final degrees = <String, int>{};
  for (final edge in edges) {
    degrees.update(edge.subject, (count) => count + 1, ifAbsent: () => 1);
    degrees.update(edge.object, (count) => count + 1, ifAbsent: () => 1);
  }
  return MemoryGraphView(
    contractVersion: next.contractVersion,
    edges: edges,
    nodes: [
      for (final node in degrees.entries)
        MemoryGraphNodeView(
            nodeId: node.key,
            label: labels[node.key] ?? node.key,
            degree: node.value),
    ],
    truncated: next.truncated,
    nextCursor: next.nextCursor,
    history: next.history,
  );
}

class _GraphCanvas extends StatelessWidget {
  const _GraphCanvas({required this.graph});
  final MemoryGraphView graph;

  @override
  Widget build(BuildContext context) {
    final rings = ((graph.nodes.length - 1) / 10).ceil();
    final side = math
        .max(500.0, 2 * (150 + math.max(0, rings - 1) * 145 + 80))
        .toDouble();
    return DecoratedBox(
      decoration: const BoxDecoration(
          gradient: RadialGradient(
        colors: [Color(0xFF132638), Color(0xFF071018)],
      )),
      child: InteractiveViewer(
        minScale: .55,
        maxScale: 12,
        boundaryMargin: const EdgeInsets.all(180),
        child: SizedBox.expand(
            child: FittedBox(
          child: CustomPaint(
            key: const Key('memory-graph-canvas'),
            size: Size.square(side),
            painter: _MemoryGraphPainter(graph,
                labelStyle: Theme.of(context).textTheme.bodySmall!),
          ),
        )),
      ),
    );
  }
}

class _RelationList extends StatelessWidget {
  const _RelationList(
      {required this.graph,
      required this.error,
      required this.busy,
      required this.onLoadMore});

  final MemoryGraphView graph;
  final Object? error;
  final bool busy;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) => ListView.builder(
        key: const Key('memory-graph-relations'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        itemCount: graph.edges.length + 1,
        itemBuilder: (context, index) {
          if (index == graph.edges.length) {
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (graph.truncated)
                    Padding(
                      key: const Key('memory-graph-truncated'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(graph.nextCursor == null
                          ? '关系太多，这里只画出了一部分'
                          : '还有关系未展开'),
                    ),
                  if (error != null) const Text('更多关系暂时无法读取，已展开的关系仍然保留'),
                  if (graph.nextCursor != null)
                    TextButton(
                      key: const Key('memory-graph-load-more'),
                      onPressed: busy ? null : onLoadMore,
                      child: Text(busy ? '正在展开…' : '继续展开'),
                    ),
                ]);
          }
          final edge = graph.edges[index];
          return ListTile(
            key: Key('memory-graph-edge-${edge.edgeId}'),
            contentPadding: EdgeInsets.zero,
            title: Text(
                '${edge.subject}  · ${memoryPredicateLabel(edge.predicate)} ·  ${edge.object}'),
            subtitle: Text([
              if (edge.validTo != null) '已结束',
              if (edge.validFrom != null)
                '自 ${memoryTimestampLabel(edge.validFrom, includeTime: false)} 起',
              if (edge.validTo != null)
                '至 ${memoryTimestampLabel(edge.validTo, includeTime: false)}',
            ].join(' · ')),
            trailing: const Icon(Icons.info_outline, size: 20),
            onTap: () => showMemoryDetail(
              context,
              title: '关系依据',
              content:
                  '${edge.subject} ${memoryPredicateLabel(edge.predicate)} ${edge.object}',
              category: edge.validTo == null ? '当前关系' : '已结束的关系',
              provenance: MemoryProvenance(learnedAt: edge.recordedAt),
              validFrom: edge.validFrom,
              validTo: edge.validTo,
            ),
          );
        },
      );
}

class _MemoryGraphPainter extends CustomPainter {
  _MemoryGraphPainter(this.graph, {required this.labelStyle});

  final MemoryGraphView graph;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final nodes = [...graph.nodes]
      ..sort((a, b) => b.degree.compareTo(a.degree));
    final center = Offset(size.width / 2, size.height / 2);
    final positions = <String, Offset>{};
    for (var index = 0; index < nodes.length; index++) {
      if (index == 0) {
        positions[nodes[index].nodeId] = center;
        continue;
      }
      final ring = 1 + ((index - 1) / 10).floor();
      final ringStart = 1 + (ring - 1) * 10;
      final inRing = index - ringStart;
      final count = math.min(10, nodes.length - ringStart);
      final angle = -math.pi / 2 + (2 * math.pi * inRing / count);
      final radius = 150.0 + (ring - 1) * 145;
      positions[nodes[index].nodeId] =
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    }

    final line = Paint()
      ..color = const Color(0xFF63D4FF).withValues(alpha: 0.32)
      ..strokeWidth = 1.4;
    for (final edge in graph.edges) {
      final from = positions[edge.subject];
      final to = positions[edge.object];
      if (from == null || to == null) continue;
      line.color = edge.validTo == null
          ? const Color(0xFF63D4FF).withValues(alpha: .32)
          : const Color(0xFF94A3B8).withValues(alpha: .6);
      canvas.drawLine(from, to, line);
      if (graph.edges.length <= 24) {
        _label(canvas, memoryPredicateLabel(edge.predicate),
            Offset.lerp(from, to, .5)!, 10, const Color(0xFFA9DCEF));
      }
    }

    for (final node in nodes) {
      final point = positions[node.nodeId]!;
      final radius = 18.0 + math.min(15, node.degree * 1.8);
      canvas.drawCircle(
        point,
        radius + 7,
        Paint()..color = const Color(0xFF2ED7C5).withValues(alpha: .14),
      );
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFF47E3C5), Color(0xFF3187D8)],
          ).createShader(Rect.fromCircle(center: point, radius: radius)),
      );
      _label(
          canvas, node.label, point + Offset(0, radius + 15), 12, Colors.white);
    }
  }

  void _label(
    Canvas canvas,
    String text,
    Offset center,
    double size,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.length > 16 ? '${text.substring(0, 16)}…' : text,
        style: labelStyle.copyWith(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 150);
    painter.paint(
        canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _MemoryGraphPainter oldDelegate) =>
      oldDelegate.graph != graph || oldDelegate.labelStyle != labelStyle;
}
