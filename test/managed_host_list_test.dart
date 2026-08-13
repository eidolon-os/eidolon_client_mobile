import 'package:eidolon_client_mobile/src/features/setup/eidolon_app_shell.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _liveId = 'ehost-980046b6704894461dfb';
const _staleId = 'ehost-c8217384281c23284cc9';
final _now = DateTime.utc(2026, 8, 13, 14);

ManagedHost _host(String hostId, {DateTime? lastConnectedAt}) => ManagedHost(
      hostId: hostId,
      hostPublicKey: 'p' * 43,
      hostFingerprint: 'sha256:${'f' * 43}',
      bleServiceUuid: '179e2e95-b1ee-5aa5-8dcf-7519b6c7ac52',
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: 'Eidolon-${hostId.substring(hostId.length - 6)}',
      claimedAt: DateTime.utc(2026, 8, 9),
      lastConnectedAt: lastConnectedAt,
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
  group('what the list says about a saved Host', () {
    test('separates the one still answering from what a reinstall left', () {
      // Reinstalling a Host mints it a new identity, so one machine can leave
      // several entries behind. Their names come from those identities, so they
      // read almost identically — this line is what tells them apart.
      final live = _host(_liveId, lastConnectedAt: _now.subtract(
        const Duration(minutes: 5),
      ));
      final lastWeek = _host(_staleId, lastConnectedAt: DateTime.utc(2026, 8, 9));
      final longGone = _host(_staleId, lastConnectedAt: DateTime.utc(2026, 6, 9));

      expect(hostReachabilityLine(live, now: _now), '刚刚连接过');
      expect(hostReachabilityLine(lastWeek, now: _now), '4 天前连接过');
      expect(hostReachabilityLine(longGone, now: _now), '上次连接 2026-06-09');
    });

    test('says there is no record rather than implying the Host is gone', () {
      // Entries saved before the App kept this record were all reachable once,
      // or they could not have been claimed. Claiming otherwise would be a
      // guess dressed as a fact.
      final line = hostReachabilityLine(_host(_staleId), now: _now);

      expect(line, contains('尚未记录过连接'));
      expect(line, contains('2026-08-09'));
    });
  });

  group('forgetting a Host on this phone', () {
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
}
