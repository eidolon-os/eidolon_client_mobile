import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  _accountsTests();
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

void _accountsTests() {
  test('provider accounts use the generated paths and carry the bind fields', () async {
    final requests = <http.Request>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      Object body;
      if (path == ManagementV1.smarthomeProvidersPath) {
        body = {'providers': [{'kind': 'homeassistant', 'label': 'Home Assistant', 'fields': [
          {'name': 'url', 'label': '地址', 'kind': 'url', 'required': true, 'choices': []},
          {'name': 'token', 'label': '令牌', 'kind': 'secret', 'required': true, 'choices': []},
        ]}]};
      } else if (path == ManagementV1.smarthomeAccountsBindPath) {
        body = {'account_id': 'acc_1', 'kind': 'homeassistant', 'label': '家', 'status': 'connected',
                'last_seen_ms': 1, 'error': null, 'choices': []};
      } else if (path == ManagementV1.smarthomeAccountsByAccountIdSyncPath('acc_1')) {
        body = {'added': ['d1'], 'updated': [], 'orphaned': [], 'skipped': [], 'revision': 3};
      } else if (path == ManagementV1.smarthomeSnapshotPath) {
        body = {'registry': {'schema_version': 1, 'revision': 3, 'areas': [], 'devices': [], 'scenes': [], 'placements': []},
                'status': {'d1': {'online': true, 'state': {'on': true, 'level': 40}}}};
      } else if (path == ManagementV1.smarthomeAccountsByAccountIdUnbindPath('acc_1')) {
        body = {'removed': 'acc_1'};
      } else {
        body = {'accounts': []};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));
    final base = Uri.parse('https://host.test');
    final providers = await client.smartHomeProviders(base, accessToken: 's');
    expect(providers.providers.single.fields!.map((f) => f.name), ['url', 'token']);
    final bound = await client.smartHomeBind(base, accessToken: 's',
        request: const AccountBind(kind: 'homeassistant', fields: {'url': 'http://ha', 'token': 't'}));
    expect(bound.status, 'connected');
    final synced = await client.smartHomeSync(base, accessToken: 's', accountId: 'acc_1');
    expect(synced.added, ['d1']);
    final snapshot = await client.smartHomeSnapshot(base, accessToken: 's');
    expect(snapshot.status['d1']!.state['level'], 40);
    final removed = await client.smartHomeUnbind(base, accessToken: 's', accountId: 'acc_1');
    expect(removed.removed, 'acc_1');
    expect(jsonDecode(requests[1].body), {'fields': {'url': 'http://ha', 'token': 't'}, 'kind': 'homeassistant'});
    expect(requests.map((r) => r.method), ['GET', 'POST', 'POST', 'GET', 'POST']);
  });
}
