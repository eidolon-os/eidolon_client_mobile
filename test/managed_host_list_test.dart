import 'package:eidolon_client_mobile/src/features/setup/eidolon_app_shell.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _liveId = 'ehost-980046b6704894461dfb';
const _staleId = 'ehost-c8217384281c23284cc9';

ManagedHost _host(String hostId) => ManagedHost(
      hostId: hostId,
      hostPublicKey: 'p' * 43,
      hostFingerprint: 'sha256:${'f' * 43}',
      bleServiceUuid: '179e2e95-b1ee-5aa5-8dcf-7519b6c7ac52',
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: 'Eidolon-${hostId.substring(hostId.length - 6)}',
      claimedAt: DateTime.utc(2026, 8, 9),
    );

/// The entry sits at the bottom of a long detail page, which a ListView has not
/// built until it is scrolled into view.
Future<void> _tapForget(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.byKey(const Key('forget-managed-host')),
    // The list page is still mounted underneath, so the detail page's own
    // scrollable has to be named rather than found by type alone.
    find.byType(Scrollable).last,
    const Offset(0, -300),
  );
  await tester.tap(find.byKey(const Key('forget-managed-host')));
  await tester.pumpAndSettle();
}

void main() {
  group('no longer managing a Host from this phone', () {
    testWidgets('needs an explicit confirmation and then leaves the page',
        (tester) async {
      final registry = InMemoryHostRegistry([
        _host(_liveId),
        _host(_staleId),
      ]);
      await tester.pumpWidget(
        MaterialApp(home: EidolonAppShell(registry: registry)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Eidolon-461dfb'));
      await tester.pumpAndSettle();
      await _tapForget(tester);
      expect(find.byKey(const Key('confirm-forget-host')), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await registry.load()).length, 2);

      await _tapForget(tester);
      await tester.tap(find.byKey(const Key('confirm-forget-host-action')));
      await tester.pumpAndSettle();

      final remaining = await registry.load();
      expect(remaining.map((host) => host.hostId), [_staleId]);
      expect(find.byKey(const Key('managed-hosts-page')), findsOneWidget);
      expect(find.text('Eidolon-461dfb'), findsNothing);
    });

    testWidgets('an emptied list goes back to setting a Host up',
        (tester) async {
      final registry = InMemoryHostRegistry([_host(_liveId)]);
      await tester.pumpWidget(
        MaterialApp(home: EidolonAppShell(registry: registry)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Eidolon-461dfb'));
      await tester.pumpAndSettle();
      await _tapForget(tester);
      await tester.tap(find.byKey(const Key('confirm-forget-host-action')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('eidolon-welcome-page')), findsOneWidget);
    });
  });

  test('a removed Host does not come back when the list is reloaded', () async {
    final registry = InMemoryHostRegistry([_host(_liveId), _host(_staleId)]);

    await registry.remove(_staleId);
    await registry.remove(_staleId);

    expect((await registry.load()).map((host) => host.hostId), [_liveId]);
  });

  group('what this phone calls a Host', () {
    testWidgets('a new name is kept, and the Host is never asked', (
      tester,
    ) async {
      final registry = InMemoryHostRegistry([_host(_liveId)]);
      await tester.pumpWidget(
        MaterialApp(home: EidolonAppShell(registry: registry)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eidolon-461dfb'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rename-host')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('host-name-field')),
        '  书房那台  ',
      );
      await tester.tap(find.byKey(const Key('confirm-host-name')));
      await tester.pumpAndSettle();

      final saved = (await registry.load()).single;
      expect(saved.displayName, '书房那台');
      // Renaming is a note this phone keeps. Nothing about the Host itself —
      // its identity, its key, when it was claimed — moves with the name.
      expect(saved.hostId, _liveId);
      expect(saved.controllerId, 'ectrl-0123456789abcdefabcd');
      expect(saved.claimedAt, DateTime.utc(2026, 8, 9));
      expect(find.text('书房那台'), findsWidgets);
    });

    testWidgets('cancelling and clearing the box both leave it alone', (
      tester,
    ) async {
      final registry = InMemoryHostRegistry([_host(_liveId)]);
      await tester.pumpWidget(
        MaterialApp(home: EidolonAppShell(registry: registry)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eidolon-461dfb'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rename-host')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await registry.load()).single.displayName, 'Eidolon-461dfb');

      await tester.tap(find.byKey(const Key('rename-host')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('host-name-field')), '   ');
      await tester.tap(find.byKey(const Key('confirm-host-name')));
      await tester.pumpAndSettle();
      expect((await registry.load()).single.displayName, 'Eidolon-461dfb');
    });

    testWidgets('identifiers are still there, just not the headline', (
      tester,
    ) async {
      final registry = InMemoryHostRegistry([_host(_liveId)]);
      await tester.pumpWidget(
        MaterialApp(home: EidolonAppShell(registry: registry)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eidolon-461dfb'));
      await tester.pumpAndSettle();
      expect(find.text(_liveId), findsNothing);

      await tester.dragUntilVisible(
        find.byKey(const Key('host-technical-identity')),
        find.byType(Scrollable).last,
        const Offset(0, -300),
      );
      await tester.tap(find.byKey(const Key('host-technical-identity')));
      await tester.pumpAndSettle();
      expect(find.text(_liveId), findsOneWidget);
    });
  });
}
