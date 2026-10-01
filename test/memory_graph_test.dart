import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_graph_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _graphWire({bool empty = false, bool truncated = false}) => {
      'contract_version': '1',
      'nodes': empty
          ? []
          : [
              {'node_id': '我', 'label': '我', 'degree': 1},
              {'node_id': '乌龙茶', 'label': '乌龙茶', 'degree': 1},
            ],
      'edges': empty
          ? []
          : [
              {
                'edge_id': 'stmt-1',
                'subject': '我',
                'predicate': 'likes',
                'object': '乌龙茶',
                'confidence': 0.94,
                'recorded_at': '2026-08-28T08:00:00Z',
              },
            ],
      'truncated': truncated,
    };

void main() {
  testWidgets('expands cursor pages and distinguishes ended relations',
      (tester) async {
    final asked = <(String?, bool)>[];
    await tester.pumpWidget(MaterialApp(home: MemoryGraphScreen(
      load: ({String? cursor, required bool history}) async {
        asked.add((cursor, history));
        final wire = _graphWire(truncated: cursor == null && !history);
        wire['history'] = history;
        wire['next_cursor'] = cursor == null && !history ? 'next-page' : null;
        if (cursor != null) {
          wire['edges'] = [
            {
              'edge_id': 'stmt-2',
              'subject': '我',
              'predicate': 'likes',
              'object': '咖啡',
              'confidence': 0.9,
              'recorded_at': '2026-08-27T08:00:00Z',
            }
          ];
          wire['nodes'] = [
            {'node_id': '咖啡', 'label': '咖啡', 'degree': 1}
          ];
        }
        if (history) {
          (wire['edges'] as List).first['valid_to'] = '2026-09-01T00:00:00Z';
        }
        return MemoryGraphView.fromJson(wire);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-graph-load-more')));
    await tester.pumpAndSettle();
    expect(asked, [(null, false), ('next-page', false)]);
    expect(find.textContaining('乌龙茶'), findsOneWidget);
    expect(find.textContaining('咖啡'), findsOneWidget);
    expect(find.byKey(const Key('memory-graph-load-more')), findsNothing);
    await tester.tap(find.byKey(const Key('memory-graph-history')));
    await tester.pumpAndSettle();
    expect(asked.last, (null, true));
    expect(find.textContaining('至 2026-09-01'), findsOneWidget);
    expect(find.textContaining('咖啡'), findsNothing);
  });

  testWidgets('a failed next page preserves loaded relations and can retry',
      (tester) async {
    var failed = false;
    await tester.pumpWidget(MaterialApp(home: MemoryGraphScreen(
      load: ({String? cursor, required bool history}) async {
        if (cursor != null && !failed) {
          failed = true;
          throw StateError('offline');
        }
        return MemoryGraphView.fromJson({
          ..._graphWire(truncated: cursor == null),
          'next_cursor': cursor == null ? 'next-page' : null,
        });
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-graph-load-more')));
    await tester.pumpAndSettle();
    expect(find.textContaining('乌龙茶'), findsOneWidget);
    expect(find.textContaining('已展开的关系仍然保留'), findsOneWidget);
    await tester.tap(find.byKey(const Key('memory-graph-load-more')));
    await tester.pumpAndSettle();
    expect(find.textContaining('乌龙茶'), findsOneWidget);
    expect(find.byKey(const Key('memory-graph-load-more')), findsNothing);
  });

  test('client sends the selected Companion to the graph endpoint', () async {
    Uri? asked;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        asked = request.url;
        return http.Response(
          jsonEncode(_graphWire()),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    final graph = await client.fetchMemoryGraph(
      Uri.parse('https://host.invalid'),
      accessToken: 'session-token',
      companionId: 'companion-a',
      cursor: 'next-page',
      history: true,
    );

    expect(asked?.path, '/api/management/v1/memory/graph');
    expect(asked?.queryParameters['companion_id'], 'companion-a');
    expect(asked?.queryParameters['cursor'], 'next-page');
    expect(asked?.queryParameters['history'], 'true');
    expect(graph.edges.single.object, '乌龙茶');
  });

  testWidgets('renders the graph canvas and a readable relation list',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryGraphScreen(
          load: ({String? cursor, required bool history}) async =>
              MemoryGraphView.fromJson(_graphWire()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-graph-canvas')), findsOneWidget);
    expect(find.text('我  · 喜欢 ·  乌龙茶'), findsOneWidget);
  });

  testWidgets('distinguishes an empty graph from an unavailable graph',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryGraphScreen(
          load: ({String? cursor, required bool history}) async =>
              MemoryGraphView.fromJson(_graphWire(empty: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有形成关系记忆'), findsOneWidget);
    expect(find.textContaining('读不到'), findsNothing);
  });

  testWidgets('says the relations in words and says when the graph is partial',
      (tester) async {
    // 「我 · likes · 乌龙茶」 was the database's vocabulary; and a bounded graph
    // shown without saying so reads as everything it knows.
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryGraphScreen(
          load: ({String? cursor, required bool history}) async =>
              MemoryGraphView.fromJson(_graphWire(truncated: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('喜欢'), findsOneWidget);
    expect(find.textContaining('likes'), findsNothing);
    expect(find.byKey(const Key('memory-graph-truncated')), findsOneWidget);
  });
}
