import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_graph_screen.dart';
import 'package:eidolon_client_mobile/src/management/memory_library_screen.dart';
import 'package:eidolon_client_mobile/src/management/memory_library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:eidolon_client_mobile/src/theme/eidolon_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'memory_copy_test.dart' as copies;
import 'memory_library_test.dart' as libraries;

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['EIDOLON_MEMORY_UI_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

ThemeData _theme() {
  final theme = EidolonTheme.dark();
  if (Platform.environment['EIDOLON_MEMORY_UI_FONT'] == null) return theme;
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'MemoryPreview'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'MemoryPreview'),
    appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.appBarTheme.titleTextStyle
            ?.copyWith(fontFamily: 'MemoryPreview')),
    listTileTheme: theme.listTileTheme.copyWith(
        titleTextStyle: theme.listTileTheme.titleTextStyle
            ?.copyWith(fontFamily: 'MemoryPreview'),
        subtitleTextStyle: theme.listTileTheme.subtitleTextStyle
            ?.copyWith(fontFamily: 'MemoryPreview')),
  );
}

void main() {
  setUpAll(() async {
    final font = Platform.environment['EIDOLON_MEMORY_UI_FONT'];
    if (font == null) return;
    final loader = FontLoader('MemoryPreview');
    loader.addFont(
        File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  test('room request uses the existing copy endpoint with scope and category',
      () async {
    Uri? asked;
    final client = ManagementClient(httpClient: MockClient((request) async {
      asked = request.url;
      return http.Response(jsonEncode(copies.copyWire()), 200,
          headers: {'content-type': 'application/json'});
    }));
    await client.fetchMemoryCopy(Uri.parse('https://host.invalid'),
        accessToken: 'session',
        companionId: 'c_b',
        wing: 'Wing_Life',
        room: '饮食');
    expect(asked?.path, '/api/management/v1/memory/export');
    expect(asked?.queryParameters,
        {'companion_id': 'c_b', 'wing': 'Wing_Life', 'room': '饮食'});
  });

  testWidgets(
      'category navigation preserves Companion and includes undated evidence',
      (tester) async {
    (String?, String?, String?)? asked;
    await tester.pumpWidget(MaterialApp(
        home: MemoryLibraryScreen(
      initialCompanionId: 'c_b',
      load: () async => libraries.library(),
      loadCopy: (companion, {String? wing, String? room}) async {
        asked = (companion, wing, room);
        return copies.copy(undated: 1, records: [
          {
            'entry_id': 'undated',
            'value': '不吃香菜',
            'recorded_at': '',
            'provenance': {'source_quote': '我不吃香菜。'},
          }
        ]);
      },
    )));
    await tester.pumpAndSettle();
    final room = find.byKey(const Key('memory-room-Wing_Life-饮食'));
    await tester.ensureVisible(room);
    await tester.pumpAndSettle();
    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(asked, ('c_b', 'Wing_Life', '饮食'));
    expect(find.text('这个伙伴能想起的'), findsOneWidget);
    expect(find.text('没有可用的时间'), findsOneWidget);
    expect(find.text('复制这一组'), findsOneWidget);
    await tester.tap(find.byKey(const Key('memory-copy-record-undated')));
    await tester.pumpAndSettle();
    expect(find.text('记忆依据'), findsOneWidget);
    expect(find.text('我不吃香菜。'), findsOneWidget);
    expect(find.text('首次记下：未记录'), findsOneWidget);
  });

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('graph fits $size with large text and opens validity details',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: MemoryGraphScreen(
              scopeLabel: '小忆能想起的',
              load: ({String? cursor, required bool history}) async =>
                  MemoryGraphView(
                contractVersion: '1',
                history: history,
                truncated: false,
                nodes: [
                  MemoryGraphNodeView(nodeId: '我', label: '我', degree: 1),
                  MemoryGraphNodeView(nodeId: '北京', label: '北京', degree: 1)
                ],
                edges: [
                  MemoryGraphEdgeView(
                      edgeId: 'residence',
                      subject: '我',
                      predicate: 'lives_in',
                      object: '北京',
                      confidence: .9,
                      recordedAt: '2026-09-01T00:00:00Z',
                      validFrom: '2015-01-01T00:00:00Z',
                      validTo: history ? '2026-09-02T00:00:00Z' : null)
                ],
              ),
            ),
          )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-graph-history')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, boundary,
          size.width < 600 ? 'graph-phone' : 'graph-landscape');
      await tester.tap(find.byKey(const Key('memory-graph-edge-residence')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('关系依据'), findsOneWidget);
      expect(find.textContaining('关系生效：'), findsOneWidget);
      expect(find.textContaining('关系结束：'), findsOneWidget);
      await _capture(tester, boundary,
          size.width < 600 ? 'relation-phone' : 'relation-landscape');
    });
  }

  testWidgets('library overview fits a narrow phone with large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!),
          home: MemoryLibraryPage(
              library: libraries.library(),
              onSearch: () {},
              onOpenToday: () {},
              onOpenGraph: () {},
              onExport: () {}),
        )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'library-narrow');
  });
}
