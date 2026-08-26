import 'dart:io';

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_mock_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_cockpit_page.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the cockpit to a file so the drawing itself can be looked at.
///
/// Text will not match the device (the test environment has no CJK font), so
/// these are read for geometry, layering and glow — where the moons sit, whether
/// the core's corona reaches the orbit, whether the deck crowds the map.
///
/// Off by default. Pixel comparisons are hostage to the renderer and the host's
/// fonts, and a suite that goes red on somebody else's machine for reasons that
/// are not about this code is worse than no reference at all. Turn it on
/// deliberately:
///
/// ```sh
/// EIDOLON_GOLDENS=1 flutter test --update-goldens test/constellation_golden_test.dart
/// EIDOLON_GOLDENS=1 flutter test test/constellation_golden_test.dart
/// ```
final bool _enabled = Platform.environment['EIDOLON_GOLDENS'] == '1';

Future<void> _open(WidgetTester tester, MockCockpitFeed feed) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: ConstellationCockpitPage(openFeed: () => feed),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('overview', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _open(tester, feed);
    await expectLater(
      find.byType(ConstellationCockpitPage),
      matchesGoldenFile('goldens/cockpit_overview.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !_enabled);

  testWidgets('live turn', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _open(tester, feed);
    for (var beat = 0; beat < 5; beat += 1) {
      feed.step();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(ConstellationCockpitPage),
      matchesGoldenFile('goldens/cockpit_live.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !_enabled);

  testWidgets('focused companion', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _open(tester, feed);
    feed.step();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is CompanionPlanet &&
            widget.planet.unit.id == 'companion-yanzhou',
      ),
    );
    // Three pumps: the camera animation starts in a post-frame callback, and a
    // ticker takes its first frame as time zero.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 900));
    await expectLater(
      find.byType(ConstellationCockpitPage),
      matchesGoldenFile('goldens/cockpit_focus.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !_enabled);
}
