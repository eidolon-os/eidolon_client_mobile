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

  group('roomJoinSessionIntent', () {
    test('defaults missing and unknown intent to a normal user session', () {
      expect(roomJoinSessionIntent(const {}), sessionIntentUserInitiated);
      expect(
        roomJoinSessionIntent(const {'session_intent': 'unexpected'}),
        sessionIntentUserInitiated,
      );
    });

    test('preserves an explicit proactive intent', () {
      expect(
        roomJoinSessionIntent(
          const {'session_intent': sessionIntentProactive},
        ),
        sessionIntentProactive,
      );
    });
  });

  group('the session-control request', () {
    // Found on hardware. This client sent `{schema_v, type}` and nothing else.
    // The Channel Provider reads three members — `schema_v`, `type` and
    // `conversation_id` — runs the last through `normalize_conversation_id`,
    // and returns null when that returns null, which it does for an absent
    // field. So the request was not malformed; it did not exist. The phone
    // published its microphone, the Provider subscribed to it, and no agent
    // was ever asked to answer. Nothing on either side logged a thing.
    //
    // These assertions are against the contract's own values, spelled out,
    // because the contract lives in another repository and is not transmitted:
    // deriving the expectation from this repo's constants would agree with
    // whatever this repo happens to say.
    test('carries the three members the Provider reads', () {
      final payload = sessionRequestPayload(
        type: sessionOpenType,
        conversationId: 'mobile-0123abcd-4567ef89-00000001',
      );

      expect(payload.keys.toSet(), <String>{
        'schema_v',
        'type',
        'conversation_id',
      });
      expect(payload['schema_v'], 1);
      expect(payload['type'], 'session_open');
      expect(payload['conversation_id'], 'mobile-0123abcd-4567ef89-00000001');
    });

    test('the close names the same conversation as the open', () {
      // `session_open` and `session_close` are statements of desired state
      // about one conversation, and the far end correlates them by this value.
      // A close carrying a fresh id would leave the open one running.
      const id = 'mobile-deadbeef-cafebabe-00000002';

      expect(
        sessionRequestPayload(type: sessionCloseType, conversationId: id)[
            'conversation_id'],
        sessionRequestPayload(type: sessionOpenType, conversationId: id)[
            'conversation_id'],
      );
    });

    test('an id the far end would drop is refused here instead', () {
      // `normalize_conversation_id` accepts 1..64 of [A-Za-z0-9-_.:] and
      // returns null otherwise — and a null there is dropped silently. So the
      // refusal has to happen on this side, where the cause is known.
      for (final bad in <String>[
        '',
        ' ',
        'has space',
        'slash/not-allowed',
        'zh-汉字',
        'x' * 65,
      ]) {
        expect(
          () => sessionRequestPayload(
            type: sessionOpenType,
            conversationId: bad,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'the Provider would drop ${bad.isEmpty ? '<empty>' : bad}',
        );
      }
      // The boundary the contract states, from the accepting side.
      expect(
        sessionRequestPayload(
          type: sessionOpenType,
          conversationId: 'x' * 64,
        )['conversation_id'],
        'x' * 64,
      );
    });

    test('only the two request types are requests', () {
      // `session_started` travels the other way on this topic. Sending it
      // would be this client answering its own question.
      expect(
        () => sessionRequestPayload(
          type: sessionStartedType,
          conversationId: 'mobile-1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
