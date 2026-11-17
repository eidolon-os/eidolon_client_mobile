import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/tool_fixtures.dart';

/// The tool switches travel as the management contract says: generated paths,
/// a change set carrying only what changed, and the revision it was made on.

final _host = Uri.parse('https://local.test');

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  final overview = FakeToolPolicies();

  test('the Owner\'s switches: read, and a change carrying null for 恢复默认',
      () async {
    final seen = <http.Request>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen.add(request);
      return _json((await overview.overview()).toJson()..['revision'] = 4);
    }));

    final read = await client.fetchTools(_host, accessToken: 't');
    expect(read.tools.map((t) => t.key), contains('music.play'));
    final changed = await client.changeTools(_host,
        accessToken: 't',
        change: const ToolPolicyChange(
            expectedRevision: 3,
            changes: {'get_weather': false, 'music.play': null}));

    expect(seen.map((r) => '${r.method} ${r.url.path}'), [
      'GET /api/management/v1/tools',
      'PUT /api/management/v1/tools',
    ]);
    expect(seen.last.headers['Authorization'], 'Bearer t');
    // null is sent, not dropped: it is what removes an override.
    expect(jsonDecode(seen.last.body), {
      'expected_revision': 3,
      'changes': {'get_weather': false, 'music.play': null},
    });
    expect(changed.revision, 4);
  });

  test('one Companion\'s switches, 「允许操控身体」 among them', () async {
    final seen = <http.Request>[];
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen.add(request);
      return _json((await overview.companion(companionA)).toJson());
    }));

    await client.fetchCompanionTools(_host,
        accessToken: 't', companionId: companionA);
    final changed = await client.changeCompanionTools(_host,
        accessToken: 't',
        companionId: companionA,
        change: const ToolPolicyChange(
            expectedRevision: 2, allowBodyControl: false));

    expect(seen.map((r) => '${r.method} ${r.url.path}'), [
      'GET /api/management/v1/companions/$companionA/tools',
      'PUT /api/management/v1/companions/$companionA/tools',
    ]);
    expect(jsonDecode(seen.last.body),
        {'expected_revision': 2, 'allow_body_control': false});
    expect(changed.companionId, companionA);
  });

  test('one device, by an identifier that needs escaping', () async {
    const device = '10:51:db:7e:24:44';
    late http.Request seen;
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen = request;
      return _json(deviceTools(device, tools: [
        deviceRow('motion.nod', reasons: ['output_not_allowed:motion'])
      ]).toJson());
    }));

    final view = await client.fetchDeviceTools(_host,
        accessToken: 't', deviceId: device);
    expect(seen.method, 'GET');
    expect(seen.url.path,
        '/api/management/v1/devices/${Uri.encodeComponent(device)}/tools');
    expect(view.tools.single.reasons, ['output_not_allowed:motion']);
    expect(view.restriction, isNull);
  });

  test('a stale revision is a conflict a screen answers by reading again',
      () async {
    final client = ManagementClient(
        httpClient: MockClient((_) async => _json({
              'detail': {
                'kind': 'conflict',
                'code': 'tool_policy_changed',
                'reason': 'the tool policy was changed meanwhile',
              }
            }, 409)));

    final failure = await client
        .changeTools(_host,
            accessToken: 't',
            change: const ToolPolicyChange(
                expectedRevision: 1, changes: {'get_time': false}))
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(failure, isA<ManagementRequestException>());
    final refusal = failure! as ManagementRequestException;
    expect(refusal.someoneElseChangedIt, isTrue);
    expect(refusal.code, 'tool_policy_changed');
  });
}
