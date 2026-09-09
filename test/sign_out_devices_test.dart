import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

// The management API remains; its action has been removed from the monitor UI.
void main() {
  test('the client posts to the owner action and names no subject', () async {
    http.Request? sent;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode(
              {'contract_version': '1', 'revoked_at': '2026-08-24T21:04:00Z'})),
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
    expect(sent?.url.path,
        '/api/management/v1/owner/actions/revoke-runtime-sessions');
    expect(sent?.url.queryParameters, isEmpty);
    // Nothing to choose: the action is "all of them, now", and whose is the
    // session's business.
    expect(sent?.body, isEmpty);
    expect(answer.revokedAt, '2026-08-24T21:04:00Z');
  });
}
