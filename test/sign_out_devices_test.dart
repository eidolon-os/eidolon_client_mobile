import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_runtime_status_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'support/setup_fixtures.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 让所有设备重新登录 — the action for a device that is out of someone's hands.
///
/// Two things this must never get wrong, and both are about scope rather than
/// mechanics: it has to say that management access is untouched (someone could
/// reasonably fear this locks them out of the app they are pressing it in), and
/// it must not report success when the Host could not do it — a person would
/// then believe a missing phone had been cut off.

ManagedHost _host() => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: '客厅主机',
      claimedAt: DateTime.utc(2026, 8, 5),
    );

HostProductConnection _connection() => HostProductConnection(
      endpoint: const LocalApiEndpoint(
        instanceName: 'eidolon-local-api',
        baseUrl: 'https://192.168.1.26:9002',
        ipAddress: '192.168.1.26',
        contractVersion: '1',
      ),
      overview: HostOverview.fromJson({
        'contract_version': '1',
        'status': 'running',
        'mode': 'production',
        'descriptor': {
          'contract_version': '1',
          'host_id': validHostId,
          'host_public_key': validHostPublicKey,
          'host_public_key_fingerprint': validHostPublicKeyFingerprint,
          'ble_service_uuid': validBleServiceUuid,
        },
        'state': {
          'reset_epoch': 2,
          'claim_state': 'claimed',
          'network_state': 'connected',
          'workspace_state': 'ready',
          'recovery_state': 'normal',
          'updated_at': '2026-08-11T00:00:00Z',
        },
      }),
      controllerId: 'ectrl-0123456789abcdefabcd',
      ownerId: 'owner-1',
      sessionExpiresAt: DateTime.utc(2026, 8, 11, 1),
    );

Future<void> _pump(
  WidgetTester tester, {
  Future<RevokedSessionsView> Function()? revoke,
  String? hold,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: HostRuntimeStatusPage(
        host: _host(),
        connection: _connection(),
        revokeRuntimeSessions: revoke,
        sessionRevokeHold: hold,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

RevokedSessionsView _revoked() => RevokedSessionsView.fromJson(const {
      'contract_version': '1',
      'revoked_at': '2026-08-24T21:04:00Z',
    });

void main() {
  _heldBackTests();
  test('the client posts to the owner action and names no subject', () async {
    http.Request? sent;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'contract_version': '1', 'revoked_at': '2026-08-24T21:04:00Z'})),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    final answer = await client.revokeRuntimeSessions(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
    );

    expect(sent?.method, 'POST');
    expect(sent?.url.path, '/api/management/v1/owner/actions/revoke-runtime-sessions');
    expect(sent?.url.queryParameters, isEmpty);
    // Nothing to choose: the action is "all of them, now", and whose is the
    // session's business.
    expect(sent?.body, isEmpty);
    expect(answer.revokedAt, '2026-08-24T21:04:00Z');
  });

  testWidgets('the action is absent when the Host has not offered it',
      (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('sign-out-devices')), findsNothing);
  });

  testWidgets('it asks first, and says what it does not touch', (tester) async {
    // The sentence that keeps someone from fearing this logs them out of the app
    // they are pressing it in.
    var asked = 0;
    await _pump(tester, revoke: () async {
      asked++;
      return _revoked();
    });

    await tester.tap(find.byKey(const Key('sign-out-devices')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('confirm-sign-out-devices')), findsOneWidget);
    expect(find.textContaining('不会影响任何手机对这台主机的管理权限'), findsOneWidget);
    expect(asked, 0, reason: 'nothing may happen before the person says yes');
  });

  testWidgets('cancelling does nothing at all', (tester) async {
    var asked = 0;
    await _pump(tester, revoke: () async {
      asked++;
      return _revoked();
    });
    await tester.tap(find.byKey(const Key('sign-out-devices')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(asked, 0);
    expect(find.byKey(const Key('sign-out-devices-outcome')), findsNothing);
  });

  testWidgets('confirming reports when it happened', (tester) async {
    await _pump(tester, revoke: () async => _revoked());
    await tester.tap(find.byKey(const Key('sign-out-devices')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('confirm-sign-out-devices-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign-out-devices-outcome')), findsOneWidget);
    expect(find.textContaining('让所有设备重新登录'), findsWidgets);
  });

  testWidgets('a Host that could not do it does not report success',
      (tester) async {
    // Otherwise someone believes a missing phone has been cut off.
    await _pump(
      tester,
      revoke: () => Future.error(
        const ManagementRequestException(
          '做不了',
          statusCode: 503,
          refusal: Refusal(
            kind: 'not_configured',
            reason: 'revocation_kv not configured on agent',
            retryable: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('sign-out-devices')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sign-out-devices-action')));
    await tester.pumpAndSettle();

    expect(find.text('这台主机现在做不了这件事，设备仍然在线'), findsOneWidget);
  });
}

void _heldBackTests() {
  testWidgets('a Host that cannot sign devices out says so, and does not offer',
      (tester) async {
    // The clearest case for holding back rather than hiding or offering: this
    // ends every device's session, and a Host missing the Agent credential
    // cannot do it. Hiding leaves somebody hunting for the control; offering it
    // promises something that will fail on contact.
    await _pump(tester, revoke: () async => _revoked(), hold: '主机未配置');

    expect(find.byKey(const Key('sign-out-devices-held')), findsOneWidget);
    expect(find.byKey(const Key('sign-out-devices')), findsNothing);
    expect(find.text('主机未配置'), findsOneWidget);
    // The name of the action stays visible, so the person can see what it is
    // they cannot do here rather than wondering whether it exists.
    expect(find.text('让所有设备重新登录'), findsOneWidget);
  });

  testWidgets('a Host that can do it is offered it', (tester) async {
    await _pump(tester, revoke: () async => _revoked());

    expect(find.byKey(const Key('sign-out-devices')), findsOneWidget);
    expect(find.byKey(const Key('sign-out-devices-held')), findsNothing);
  });
}
