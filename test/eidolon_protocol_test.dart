import 'dart:convert';

import 'package:eidolon_client_mobile/src/protocol/eidolon_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses v1 command and builds matching result envelope', () {
    final command = ControlCommand.parse(jsonEncode({
      'v': 1,
      'kind': 'cmd',
      'id': 'command-1',
      'op': 'device.identify',
      'capability_version': 1,
      'payload': {'reason': 'test'},
    }));

    expect(command, isNotNull);
    expect(command!.op, 'device.identify');
    final result = jsonDecode(buildControlAck(
      command: command,
      deviceId: 'mobile-1',
      status: 'completed',
      code: 'OK',
      result: {'played': true},
    )) as Map<String, dynamic>;
    expect(result['kind'], 'result');
    expect(result['ref'], 'command-1');
    expect(result['result'], {'played': true});
  });

  test('marks commands beyond their TTL as expired', () {
    final command = ControlCommand.parse(jsonEncode({
      'v': 1,
      'kind': 'cmd',
      'id': 'old',
      'op': 'room.join',
      'ts': 1,
      'ttl_ms': 1,
      'payload': {},
    }));
    expect(command?.expired, isTrue);
  });
}
