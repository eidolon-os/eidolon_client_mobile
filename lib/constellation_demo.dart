import 'package:flutter/material.dart';

import 'src/features/constellation/cockpit_mock_feed.dart';
import 'src/features/constellation/constellation_cockpit_page.dart';

/// A run target for the constellation cockpit on its own:
///
/// ```sh
/// flutter run -t lib/constellation_demo.dart
/// ```
///
/// It exists because this screen is being built before the Owner-scoped Mission
/// Control projection it will eventually read, and because a constellation can
/// only be judged in motion. Nothing in the product navigation points here: the
/// cockpit is not wired into the app until it has a real feed, so a demo cannot
/// be mistaken for a Host's word.
void main() => runApp(const ConstellationDemoApp());

class ConstellationDemoApp extends StatelessWidget {
  const ConstellationDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Eidolon 星图',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00EAFF),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF060210),
          useMaterial3: true,
        ),
        // The one place the staged world is constructed. Nothing in the product
        // navigation reaches this page, and the page itself has no fallback.
        home: ConstellationCockpitPage(feed: MockCockpitFeed()),
      );
}
