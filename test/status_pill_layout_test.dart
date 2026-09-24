import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/theme/neon_components.dart';

void main() {
  testWidgets('host identity refusal wraps within its card at large text size',
      (tester) async {
    const message = '这个地址上的主机，不是这台手机配对过的那一台。它可能被重置过，也可能是另一台设备占用了这个地址。';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: MediaQuery(
                    data: const MediaQueryData(
                        textScaler: TextScaler.linear(1.6)),
                    child: const SizedBox(
                        width: 240, child: StatusPill(message)))))));
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
        tester.getSize(find.byType(StatusPill)).width, lessThanOrEqualTo(240));
  });
}
