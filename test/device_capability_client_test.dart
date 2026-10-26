import 'dart:convert';

import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  _refusalCases();

  test('a knob command travels as one bounded capability request', () async {
    late http.Request seen;
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode({
          'device_id': '10:51:db:7e:24:44:aa:bb:cc:dd:ee:ff:00:11',
          'op': 'volume.set',
          'capability_version': 1,
          'status': 'done',
          'completed': true,
          'result': {'volume': 30},
          'code': '',
          'message': '',
        }),
        200,
      );
    }));

    final receipt = await client.setDeviceCapability(
      Uri.parse('https://local.test'),
      accessToken: 'token',
      deviceId: '10:51:db:7e:24:44:aa:bb:cc:dd:ee:ff:00:11',
      op: 'volume.set',
      payload: {'volume': 30},
      requestId: 'gesture-1',
    );

    expect(seen.method, 'POST');
    expect(
      seen.url.path,
      '/api/management/v1/devices/'
      '${Uri.encodeComponent('10:51:db:7e:24:44:aa:bb:cc:dd:ee:ff:00:11')}'
      '/capabilities/volume.set',
    );
    expect(seen.headers['Authorization'], 'Bearer token');
    expect(jsonDecode(seen.body), {
      'capability_version': 1,
      'payload': {'volume': 30},
      'request_id': 'gesture-1',
    });
    expect(receipt.completed, isTrue);
    expect(receipt.status, 'done');
  });

  test('a refusal is reported as unfinished rather than thrown away', () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      return http.Response(
        jsonEncode({
          'device_id': 'box-3',
          'op': 'display.brightness',
          'capability_version': 1,
          'status': 'failed',
          'completed': false,
          'code': 'INVALID_BRIGHTNESS',
          'message': 'device could not apply that value',
        }),
        200,
      );
    }));

    final receipt = await client.setDeviceCapability(
      Uri.parse('https://local.test'),
      accessToken: 'token',
      deviceId: 'box-3',
      op: 'display.brightness',
      payload: {'brightness': 80},
      requestId: 'gesture-2',
    );

    expect(receipt.completed, isFalse);
    expect(receipt.message, 'device could not apply that value');
  });
}

void _refusalCases() {
  test('a 409 with no declaration is not reported as someone else editing', () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      return http.Response(
        jsonEncode({
          'detail': {
            'kind': 'conflict',
            'reason': 'no declaration for volume.set.v1 on device box-3',
            'code': 'CAPABILITY_NOT_DECLARED',
            'retryable': false,
          },
        }),
        409,
      );
    }));

    Object? caught;
    try {
      await client.setDeviceCapability(
        Uri.parse('https://local.test'),
        accessToken: 'token',
        deviceId: 'box-3',
        op: 'volume.set',
        payload: {'volume': 40},
        requestId: 'gesture-3',
      );
    } catch (error) {
      caught = error;
    }

    expect(caught, isA<ManagementRequestException>());
    expect((caught! as ManagementRequestException).code, 'CAPABILITY_NOT_DECLARED');
  });
}
