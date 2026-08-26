import 'package:eidolon_client_mobile/src/features/constellation/cockpit_deck.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_mock_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_cockpit_page.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_nodes.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cockpit across the screens it will actually meet.
///
/// Landscape was the case that was broken and invisible: the header and the deck
/// took 217 of a landscape phone's 390dp of height, leaving the map a 173dp
/// letterbox where the moons came out fifteen pixels wide. Nothing threw, so
/// nothing failed — which is exactly why these are measurements rather than
/// screenshots.

class _Surface {
  const _Surface(this.name, this.size, this.textScale, this.minNode);

  final String name;
  final Size size;
  final double textScale;

  /// The smallest a node is allowed to get on this screen. A node below about
  /// 24dp is a dot you cannot read or reliably hit.
  final double minNode;
}

const _surfaces = <_Surface>[
  _Surface('手机竖屏 390x844', Size(1170, 2532), 1, 38),
  _Surface('手机横屏 844x390', Size(2532, 1170), 1, 38),
  _Surface('小屏竖屏 320x568', Size(960, 1704), 1, 28),
  _Surface('小屏横屏 568x320', Size(1704, 960), 1, 24),
  _Surface('平板竖屏 712x1067', Size(2136, 3200), 1, 60),
  _Surface('平板横屏 1067x712', Size(3200, 2136), 1, 55),
  _Surface('分屏 390x420', Size(1170, 1260), 1, 24),
  _Surface('折叠展开 673x841', Size(2019, 2523), 1, 50),
  _Surface('字号1.3 竖屏', Size(1170, 2532), 1.3, 38),
  _Surface('字号1.6 竖屏', Size(1170, 2532), 1.6, 38),
  _Surface('字号1.6 横屏', Size(2532, 1170), 1.6, 38),
];

Future<void> _open(
  WidgetTester tester,
  MockCockpitFeed feed, {
  required Size size,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 3;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: ConstellationCockpitPage(openFeed: () => feed),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Every core, planet and moon rect, and the stage they must stay inside.
({Rect stage, List<Rect> nodes}) _measure(WidgetTester tester) {
  final nodes = <Rect>[];
  for (final finder in <Finder>[
    find.byType(CompanionPlanet),
    find.byType(AssetMoon),
    find.byType(OwnerCore),
  ]) {
    for (final element in finder.evaluate()) {
      nodes.add(tester.getRect(find.byWidget(element.widget)));
    }
  }
  return (stage: tester.getRect(find.byType(ConstellationStage)), nodes: nodes);
}

void main() {
  for (final surface in _surfaces) {
    testWidgets('${surface.name}：地图在舞台内、节点可读、没有溢出', (tester) async {
      addTearDown(tester.view.reset);
      final feed = MockCockpitFeed(autoplay: false);
      addTearDown(feed.dispose);
      await _open(
        tester,
        feed,
        size: surface.size,
        textScale: surface.textScale,
      );

      final measured = _measure(tester);
      expect(measured.nodes, isNotEmpty);
      for (final node in measured.nodes) {
        expect(
          measured.stage.contains(node.topLeft) &&
              measured.stage.contains(node.bottomRight),
          isTrue,
          reason: '${surface.name}：$node 越出舞台 ${measured.stage}',
        );
        expect(
          node.width,
          greaterThanOrEqualTo(surface.minNode),
          reason: '${surface.name}：节点缩到 ${node.width.toStringAsFixed(1)}dp，'
              '读不了也点不准',
        );
      }
      // 任何 overflow 都会以异常形式冒出来；这一屏不允许有。
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('横屏把仪表搬到侧栏，竖屏放回底部背板', (tester) async {
    addTearDown(tester.view.reset);
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);

    await _open(tester, feed, size: const Size(1170, 2532));
    expect(find.byType(KernelDeck), findsOneWidget);
    expect(find.byType(CockpitRail), findsNothing);

    tester.view.physicalSize = const Size(2532, 1170);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(CockpitRail), findsOneWidget);
    expect(find.byType(KernelDeck), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('转屏后重新构图：轨道换向，地图还在舞台里', (tester) async {
    addTearDown(tester.view.reset);
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);

    await _open(tester, feed, size: const Size(1170, 2532));
    final portrait = _measure(tester);
    final portraitSpan = portrait.nodes.fold<Rect>(
      portrait.nodes.first,
      (box, node) => box.expandToInclude(node),
    );

    // 转到横屏，然后再转回来 —— 两次都必须重新构图，而不是留着上一次的镜头。
    for (final size in <Size>[const Size(2532, 1170), const Size(1170, 2532)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final measured = _measure(tester);
      for (final node in measured.nodes) {
        expect(
          measured.stage.contains(node.topLeft) &&
              measured.stage.contains(node.bottomRight),
          isTrue,
          reason: '$size：转屏后 $node 越出舞台 ${measured.stage}',
        );
      }
      if (size.width > size.height) {
        final span = measured.nodes.fold<Rect>(
          measured.nodes.first,
          (box, node) => box.expandToInclude(node),
        );
        // 竖屏的星图比宽更高，横屏必须反过来 —— 否则就是把竖版缩小塞进信箱。
        expect(portraitSpan.height / portraitSpan.width, greaterThan(1));
        expect(span.width / span.height, greaterThan(1));
      }
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
