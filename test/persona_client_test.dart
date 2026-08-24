import 'dart:convert';

import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 人格记录 — the read and the way back, after they moved off `/api/local/v1`.
///
/// Both were hand-written calls with their own parsed models. What is worth
/// holding here is the shape the migration chose: a `PUT` naming the chapter this
/// Eidolon should be, so a retry is not a second change.

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

Map<String, dynamic> historyWire() => {
      'contract_version': '1',
      'companion_id': 'c_1',
      'chapters': [
        {
          'chapter_id': 'g_2',
          'changed_at': '2026-08-14T02:00:00Z',
          'what_changed': '我发现你不喜欢被打断',
          'restored_from': null,
          'is_current': true,
        },
      ],
    };

void main() {
  test('reads the history from the management route', () async {
    Uri? asked;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        asked = request.url;
        return _hostAnswer(historyWire());
      }),
    );

    final history = await client.fetchPersonaHistory(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'c_1',
    );

    expect(asked?.path, '/api/management/v1/companions/c_1/persona-history');
    expect(asked?.queryParameters.containsKey('owner_id'), isFalse);
    expect(history.chapters.single.whatChanged, '我发现你不喜欢被打断');
  });

  test('going back is a PUT naming the chapter, not an event', () async {
    // So the same request twice leaves the same Eidolon: the Host answers a
    // repeat with the history rather than a conflict.
    http.Request? sent;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        sent = request;
        return _hostAnswer(historyWire());
      }),
    );

    await client.restorePersona(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'c_1',
      chapterId: 'g_1',
    );

    expect(sent?.method, 'PUT');
    expect(
      sent?.url.path,
      '/api/management/v1/companions/c_1/persona-restorations',
    );
    expect(jsonDecode(sent!.body), {'chapter_id': 'g_1'});
  });

  test('escapes a companion id into the path', () async {
    http.Request? sent;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        sent = request;
        return _hostAnswer(historyWire());
      }),
    );

    await client.fetchPersonaHistory(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'c_1/../other',
    );

    expect(sent!.url.toString(), contains('/companions/c_1%2F..%2Fother/'));
  });

  test('a refusal carries its status, so a screen can tell 409 from 503',
      () async {
    final client = ManagementClient(
      httpClient: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode({'detail': '这一章它从没有成为过'})),
          409,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      client.restorePersona(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'c_1',
        chapterId: 'g_never',
      ),
      throwsA(
        isA<ManagementRequestException>().having(
          (error) => error.statusCode,
          'statusCode',
          409,
        ),
      ),
    );
  });
}
