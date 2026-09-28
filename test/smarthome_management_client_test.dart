import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('registry mutations use the generated path and the current revision', () async {
    final requests = <http.Request>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({
        'schema_version': 1,
        'revision': requests.length,
        'areas': [],
        'devices': [],
        'scenes': [],
        'placements': [],
      }), 200, headers: {'content-type': 'application/json'});
    }));
    final base = Uri.parse('https://host.test');
    final first = await client.smartHomeRegistry(base, accessToken: 'session');
    final next = await client.smartHomeWrite(base,
      accessToken: 'session',
      method: 'POST',
      path: ManagementV1.smarthomeAreasPath,
      body: {
        'expected_revision': first.revision,
        'area': const Area(areaId: 'living', name: '客厅').toJson(),
      },
    );
    await client.smartHomeWrite(base,
      accessToken: 'session',
      method: 'DELETE',
      path: ManagementV1.smarthomeAreasByAreaIdPath('living'),
      expectedRevision: next.revision,
    );
    expect(requests.map((r) => r.method), ['GET', 'POST', 'DELETE']);
    expect(requests[1].url.path, ManagementV1.smarthomeAreasPath);
    expect(jsonDecode(requests[1].body)['expected_revision'], first.revision);
    expect(requests[2].url.queryParameters['expected_revision'], '${next.revision}');
    expect(requests.every((r) => r.headers['authorization'] == 'Bearer session'), isTrue);
  });
}
