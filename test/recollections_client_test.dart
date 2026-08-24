import 'dart:convert';

import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 你还记得…吗 — the read that moved off `/api/local/v1`.
///
/// This was the app's first memory feature and its last hand-written client
/// method. Both the old route and the method are gone, so what these tests hold
/// is that the generated client asks the migrated route, with the bounds the old
/// one carried, and names no subject.

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

Map<String, dynamic> answerWire({String query = '散步'}) => {
      'contract_version': '1',
      'query': query,
      'recollections': [
        {'text': '他喜欢在下午散步', 'remembered_at': '2026-08-16T09:30:00Z'},
        {'text': '没有时间的那一条', 'remembered_at': null},
      ],
    };

void main() {
  test('asks the management route and names no owner', () async {
    Uri? asked;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        asked = request.url;
        return _hostAnswer(answerWire());
      }),
    );

    final answer = await client.fetchRecollections(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      query: '散步',
    );

    expect(asked?.path, '/api/management/v1/memory/recollections');
    expect(asked?.queryParameters['q'], '散步');
    expect(asked?.queryParameters.containsKey('owner_id'), isFalse);
    expect(answer.query, '散步');
    expect(answer.recollections.first.text, '他喜欢在下午散步');
  });

  test('sends the limit it was given and no audience by default', () async {
    Uri? asked;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        asked = request.url;
        return _hostAnswer(answerWire());
      }),
    );

    await client.fetchRecollections(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      query: '散步',
      limit: 3,
    );

    expect(asked?.queryParameters.keys.toSet(), {'q', 'limit'});
    expect(asked?.queryParameters['limit'], '3');
  });

  test('can ask one companion in particular, as the library can', () async {
    Uri? asked;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        asked = request.url;
        return _hostAnswer(answerWire());
      }),
    );

    await client.fetchRecollections(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      query: '茶',
      companionId: 'c-a',
    );

    expect(asked?.queryParameters['companion_id'], 'c-a');
  });

  test('decodes what it remembers as UTF-8', () async {
    // A latin-1 decode would hand someone their own memory mangled.
    final client = ManagementClient(
      httpClient: MockClient((_) async => _hostAnswer(answerWire(query: '乌龙茶'))),
    );

    final answer = await client.fetchRecollections(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      query: '乌龙茶',
    );

    expect(answer.query, '乌龙茶');
  });
}
