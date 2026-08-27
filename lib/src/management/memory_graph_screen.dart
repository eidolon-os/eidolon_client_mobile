import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'refusal_notice.dart';

class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen({super.key, required this.load});

  final Future<MemoryGraphView> Function() load;

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> {
  MemoryGraphView? _graph;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() => _error = null);
    try {
      final graph = await widget.load();
      if (!mounted) return;
      setState(() => _graph = graph);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    return Scaffold(
      key: const Key('memory-graph-screen'),
      appBar: AppBar(title: const Text('记忆关系图')),
      body: graph == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : RefusalNotice(
                      error: _error!,
                      subject: '记忆关系图',
                      onRetry: _read,
                    ),
            )
          : graph.nodes.isEmpty
              ? const Center(child: Text('还没有形成关系记忆'))
              : Column(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            colors: [Color(0xFF132638), Color(0xFF071018)],
                          ),
                        ),
                        child: InteractiveViewer(
                          minScale: 0.55,
                          maxScale: 2.8,
                          boundaryMargin: const EdgeInsets.all(180),
                          child: CustomPaint(
                            key: const Key('memory-graph-canvas'),
                            size: const Size(900, 680),
                            painter: _MemoryGraphPainter(graph),
                          ),
                        ),
                      ),
                    ),
                    _RelationList(graph: graph),
                  ],
                ),
    );
  }
}

class _RelationList extends StatelessWidget {
  const _RelationList({required this.graph});

  final MemoryGraphView graph;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 176,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          itemCount: graph.edges.length,
          separatorBuilder: (_, __) => const Divider(height: 12),
          itemBuilder: (_, index) {
            final edge = graph.edges[index];
            return Text(
              '${edge.subject}  · ${edge.predicate} ·  ${edge.object}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            );
          },
        ),
      );
}

class _MemoryGraphPainter extends CustomPainter {
  _MemoryGraphPainter(this.graph);

  final MemoryGraphView graph;

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
      canvas.drawLine(from, to, line);
      _label(canvas, edge.predicate, Offset.lerp(from, to, .5)!, 10,
          const Color(0xFFA9DCEF));
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
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 150);
    painter.paint(
        canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _MemoryGraphPainter oldDelegate) =>
      oldDelegate.graph != graph;
}
