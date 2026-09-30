import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/forget_sheet.dart';
import 'package:eidolon_client_mobile/src/management/memory_day_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('token expiring while confirmation is open is not submitted', (tester) async {
    var clock = DateTime.utc(2026, 9, 30, 12);
    var confirms = 0;
    await tester.pumpWidget(MaterialApp(home: ForgetSheet(
      now: () => clock,
      preview: (_) async => ForgetProposalView.fromJson({
        'contract_version': '1', 'status': 'preview', 'target': 'tea',
        'entries': [{'entry_id': 'one', 'preview': 'tea', 'score': 1.0}],
        'needs_confirmation': true, 'confirmation_token': 'expired-token',
        'expires_at': clock.add(const Duration(seconds: 30)).millisecondsSinceEpoch ~/ 1000,
        'detail': '',
      }),
      confirm: (_) async {
        confirms++;
        return ForgetResultView.fromJson({
          'contract_version': '1', 'request_id': 'r1', 'target': 'tea',
          'entry_count': 1, 'status': 'applied',
        });
      },
    )));
    await tester.enterText(find.byKey(const Key('forget-target-field')), 'tea');
    await tester.tap(find.byKey(const Key('forget-preview-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-confirm-button')));
    await tester.pumpAndSettle();
    clock = clock.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    await tester.tap(find.byKey(const Key('forget-decision-confirm')));
    await tester.pumpAndSettle();
    expect(confirms, 0);
  });

  testWidgets('incomplete empty scan retains its uncertainty', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MemoryDayPage(
      entries: const [], undatedCount: 0, truncated: true, today: DateTime(2026, 9, 30),
    )));
    expect(find.text('还没有记下什么'), findsNothing);
    expect(find.text('主机这次没有读完全部记忆，这里可能不完整'), findsOneWidget);
  });
}
