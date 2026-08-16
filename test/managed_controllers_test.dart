import 'package:eidolon_client_mobile/src/features/host_setup/controller_grant_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/managed_controllers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _thisPhone = 'ectrl-0123456789abcdefabcd';
const _otherPhone = 'ectrl-fedcba9876543210dcba';

ControllerGrant _grant(String controllerId, String name) =>
    ControllerGrant.fromJson({
      'controller_id': controllerId,
      'public_key': 'p' * 43,
      'public_key_fingerprint': 'sha256:${'f' * 43}',
      'role': 'owner',
      'display_name': name,
      'platform': 'android',
      'reset_epoch': 1,
      'created_at': '2026-08-12T08:10:00Z',
      'revoked_at': null,
    });

Future<void> _open(
  WidgetTester tester, {
  required Future<List<ControllerGrant>> Function() load,
  Future<ControllerInvitation> Function()? invite,
  Future<void> Function(String controllerId)? revoke,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ManagedControllersPage(
        thisControllerId: _thisPhone,
        loadControllers: load,
        invite: invite ??
            () async => throw StateError('must not invite'),
        revoke: revoke ?? (_) async => throw StateError('must not revoke'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows every phone that holds the Host, and which one is here',
      (tester) async {
    // Their names come from the phones themselves and can repeat, so the one
    // being held has to be marked rather than inferred.
    await _open(
      tester,
      load: () async => [
        _grant(_thisPhone, 'Pad'),
        _grant(_otherPhone, 'Pad'),
      ],
    );

    expect(find.byKey(const Key('controller-$_thisPhone')), findsOneWidget);
    expect(find.byKey(const Key('controller-$_otherPhone')), findsOneWidget);
    expect(find.text('这台手机'), findsOneWidget);
  });

  testWidgets('an invitation shows the one-time code and when it lapses',
      (tester) async {
    var invited = 0;
    await _open(
      tester,
      load: () async => [_grant(_thisPhone, 'Pad')],
      invite: () async {
        invited += 1;
        return ControllerInvitation.fromJson({
          'setup_code': '482913',
          'expires_at': '2026-08-13T09:30:00Z',
          'host_id': 'ehost-980046b6704894461dfb',
          'commissioning_id': 'session-1',
          'issued_at': '2026-08-13T09:20:00Z',
        });
      },
    );

    await tester.tap(find.byKey(const Key('invite-controller')));
    await tester.pumpAndSettle();

    expect(invited, 1);
    expect(find.byKey(const Key('controller-invitation')), findsOneWidget);
    expect(find.text('482913'), findsOneWidget);
  });

  testWidgets('revoking another phone is confirmed, then the list is re-read',
      (tester) async {
    var loads = 0;
    String? revoked;
    await _open(
      tester,
      load: () async {
        loads += 1;
        return loads == 1
            ? [_grant(_thisPhone, 'Pad'), _grant(_otherPhone, '旧手机')]
            : [_grant(_thisPhone, 'Pad')];
      },
      revoke: (controllerId) async => revoked = controllerId,
    );

    await tester.tap(find.byKey(const Key('revoke-$_otherPhone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-controller-revocation')),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(revoked, isNull);

    await tester.tap(find.byKey(const Key('revoke-$_otherPhone')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('confirm-controller-revocation-action')));
    await tester.pumpAndSettle();

    expect(revoked, _otherPhone);
    // The Host is the authority on who holds it, so the list is re-read rather
    // than edited here.
    expect(loads, 2);
    expect(find.byKey(const Key('controller-$_otherPhone')), findsNothing);
  });

  testWidgets('revoking this phone says what it costs, and says it differently '
      'when it is the last one', (tester) async {
    await _open(
      tester,
      load: () async => [_grant(_thisPhone, 'Pad')],
      revoke: (_) async {},
    );

    await tester.tap(find.byKey(const Key('revoke-$_thisPhone')));
    await tester.pumpAndSettle();

    final dialog = tester.widget<AlertDialog>(
      find.byKey(const Key('confirm-controller-revocation')),
    );
    final content = (dialog.content! as Text).data!;
    expect(content, contains('这台手机将立即失去管理'));
    // Nothing else holds it, so there is no one left to invite this phone back.
    expect(content, contains('没有任何手机能管理它'));
  });

  testWidgets('a Host that refuses says so instead of emptying the list',
      (tester) async {
    await _open(
      tester,
      load: () async => throw StateError('主机拒绝了这次请求'),
    );

    expect(find.byKey(const Key('controllers-error')), findsOneWidget);
    expect(find.byKey(const Key('controllers-empty')), findsNothing);
  });
}
