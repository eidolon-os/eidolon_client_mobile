import 'package:eidolon_client_mobile/src/theme/eidolon_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'the last button of a page stays above the navigation gesture area',
      (tester) async {
    tester.view.physicalSize = const Size(1240, 2772);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 120, bottom: 154);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => EidolonBackdrop(child: child!),
      home: Scaffold(
        body: ListView(
          // An explicit padding, as most pages here use: it replaces the
          // inset a ListView would otherwise take from MediaQuery.
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 2600),
            FilledButton(onPressed: () {}, child: const Text('添加设备')),
          ],
        ),
      ),
    ));
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byType(FilledButton));
    expect(button.bottom, lessThanOrEqualTo(2772 - 154));
  });
}
