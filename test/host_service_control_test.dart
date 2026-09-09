import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'support/monitor_fixtures.dart';

void main() {
  test(
      'monitor reads authenticated snapshot including integer JSON percentages',
      () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/management/v1/host/monitor');
      expect(request.headers['authorization'], 'Bearer session');
      final json = monitorSnapshot().toJson();
      (json['cpu'] as Map<String, dynamic>)['usage_percent'] = 42;
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final value = await client.fetchHostMonitor(Uri.parse('https://host:9002'),
        accessToken: 'session');
    expect(value.cpu.usagePercent, 42.0);
    expect(value.services!.single.processes!.single.sourcePath,
        '/opt/eidolon/hub/server.py');
  });

  test('service mutation client still carries the observed revision', () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/management/v1/host/services/hub/restart');
      expect(jsonDecode(request.body)['expected_revision'], 4);
      return http.Response(
          jsonEncode({
            'service_id': 'hub',
            'operation': 'restart',
            'enabled': true,
            'revision': 5
          }),
          200);
    }));
    final result = await client.changeHostService(
        Uri.parse('https://host:9002'),
        accessToken: 'session',
        serviceId: 'hub',
        operation: 'restart',
        expectedRevision: 4);
    expect(result.revision, 5);
  });
}
