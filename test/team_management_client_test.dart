import 'dart:convert';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const configuration = TeamConfiguration(name: '朋友', inputDeviceId: 'input',
    members: [TeamMember(companionId: 'partner', outputDeviceId: 'output')]);

void main() {
  test('history pagination is explicit and owner is never client supplied', () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      expect(request.url.queryParameters, {'include_closed': 'true', 'limit': '2', 'after': 'run-z'});
      expect(request.headers['authorization'], 'Bearer session');
      return http.Response(jsonEncode({'starts': [], 'next_cursor': 'run-next'}), 200,
        headers: {'content-type': 'application/json'});
    }));
    final page = await client.fetchTeamRuns(Uri.parse('https://host.test'),
      accessToken: 'session', teamId: 'team-a', includeClosed: true, after: 'run-z', limit: 2);
    expect(page.nextCursor, 'run-next'); client.close();
  });

  test('team mutations send revisions and use authenticated generated routes', () async {
    final requests = <http.Request>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(request.method == 'DELETE'
          ? {'team_id': 'team-a'}
          : {'team_id': 'team-a', 'revision': 3,
             'configuration': configuration.toJson()}), 200, headers: {'content-type': 'application/json'});
    }));
    final base = Uri.parse('https://host.test');
    await client.saveTeam(base, accessToken: 'session', teamId: 'team-a',
        expectedRevision: 2, configuration: configuration);
    await client.deleteTeam(base, accessToken: 'session', teamId: 'team-a',
        expectedRevision: 3);
    expect(jsonDecode(requests.first.body)['expected_revision'], 2);
    expect(requests.last.url.queryParameters['expected_revision'], '3');
    expect(requests.every((r) => r.url.path == ManagementV1.teamsByTeamIdPath('team-a')), true);
    expect(requests.every((r) => r.headers['authorization'] == 'Bearer session'), true);
    expect(jsonDecode(requests.first.body).containsKey('owner_id'), false);
    client.close();
  });

  test('mismatched save response is not reported as success', () async {
    final client = ManagementClient(httpClient: MockClient((_) async => http.Response(
        jsonEncode({'team_id': 'other', 'revision': 1,
          'configuration': configuration.toJson()}), 200, headers: {'content-type': 'application/json'})));
    await expectLater(client.saveTeam(Uri.parse('https://host.test'),
        accessToken: 'session', teamId: 'team-a', expectedRevision: 0,
        configuration: configuration), throwsA(isA<ManagementRequestException>()));
    client.close();
  });
}
