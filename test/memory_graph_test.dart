import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_graph_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _graphWire({bool empty = false}) => {
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
      'truncated': false,
    };

void main() {
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
    );

    expect(asked?.path, '/api/management/v1/memory/graph');
    expect(asked?.queryParameters['companion_id'], 'companion-a');
    expect(graph.edges.single.object, '乌龙茶');
  });

  testWidgets('renders the graph canvas and a readable relation list',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryGraphScreen(
          load: () async => MemoryGraphView.fromJson(_graphWire()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-graph-canvas')), findsOneWidget);
    expect(find.text('我  · likes ·  乌龙茶'), findsOneWidget);
  });

  testWidgets('distinguishes an empty graph from an unavailable graph',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryGraphScreen(
          load: () async => MemoryGraphView.fromJson(_graphWire(empty: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有形成关系记忆'), findsOneWidget);
    expect(find.textContaining('读不到'), findsNothing);
  });
}
