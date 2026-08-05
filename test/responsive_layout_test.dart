import 'package:eidolon_client_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpAtSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const MaterialApp(home: ClientPage()));
    await tester.pump();
  }

  testWidgets('uses two panes for Xiaomi Pad-sized landscape viewport',
      (tester) async {
    await pumpAtSize(tester, const Size(1280, 853));

    expect(find.byKey(const Key('tablet-layout')), findsOneWidget);
    expect(find.byKey(const Key('compact-layout')), findsNothing);
    expect(find.byKey(const Key('tablet-actions')), findsOneWidget);
    expect(find.text('发现并连接 Hub'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a scrolling column for tablet portrait viewport',
      (tester) async {
    await pumpAtSize(tester, const Size(800, 1280));

    expect(find.byKey(const Key('compact-layout')), findsOneWidget);
    expect(find.byKey(const Key('tablet-layout')), findsNothing);
    expect(find.byKey(const Key('compact-actions')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a scrolling column in a narrow workstation window',
      (tester) async {
    await pumpAtSize(tester, const Size(600, 700));

    expect(find.byKey(const Key('compact-layout')), findsOneWidget);
    expect(find.byKey(const Key('tablet-layout')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
