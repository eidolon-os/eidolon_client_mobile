import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/models/speaker_observation.dart';

void main() {
  final packet = <String, dynamic>{
    'schema_version': 1,
    'conversation_id': 's',
    'turn_id': 't',
    'issued_at': 100.0,
    'expires_at': 110.0,
    'status': 'identified',
    'reason': 'voice_match',
    'confidence': 'controlled_trial',
    'display_name': '甲'
  };
  test('identification label does not depend on evaluation policy', () {
    final value =
        SpeakerObservationView.parse(packet, conversationId: 's', now: 101);
    expect(value!.label, '刚才的声音：甲');
    expect(
        SpeakerObservationView.parse({...packet, 'confidence': 'validated'},
                conversationId: 's', now: 101)!
            .label,
        value.label);
  });
  test('stale or foreign session evidence cannot supply a name', () {
    expect(
        SpeakerObservationView.parse(packet, conversationId: 'other', now: 101),
        isNull);
    expect(SpeakerObservationView.parse(packet, conversationId: 's', now: 111),
        isNull);
    expect(
        SpeakerObservationView.parse({...packet, 'display_name': ''},
            conversationId: 's', now: 101),
        isNull);
  });
  test('unknown does not inherit a supplied display name', () {
    final value = SpeakerObservationView.parse({...packet, 'status': 'unknown'},
        conversationId: 's', now: 101);
    expect(value!.displayName, isNull);
    expect(value.label, '未识别到已录入用户');
  });
  test('sequence accepts late evidence and rejects replay after display expiry',
      () {
    final cursor = SpeakerObservationCursor();
    SpeakerObservationView view(int sequence, double issued) =>
        SpeakerObservationView.parse({
          ...packet,
          'sequence': sequence,
          'issued_at': issued,
          'expires_at': issued + 10
        }, conversationId: 's', now: 102)!;
    expect(cursor.accept(view(1, 101), sessionId: 's'), isTrue);
    expect(cursor.accept(view(2, 100), sessionId: 's'), isTrue);
    expect(cursor.accept(view(2, 100), sessionId: 's'), isFalse);
    expect(cursor.accept(view(1, 101), sessionId: 's'), isFalse);
    expect(
        cursor.accept(
            SpeakerObservationView.parse(packet,
                conversationId: 's', now: 102)!,
            sessionId: 's'),
        isFalse);
    expect(cursor.accept(view(1, 101), sessionId: 'new-session'), isTrue);
  });
  test('invalid sequence is rejected and pending is not a dependency failure',
      () {
    for (final sequence in [0, -1, 1.5, '2']) {
      expect(
          SpeakerObservationView.parse({...packet, 'sequence': sequence},
              conversationId: 's', now: 101),
          isNull);
    }
    final pending = SpeakerObservationView.parse(
        {...packet, 'status': 'unavailable', 'reason': 'recognition_pending'},
        conversationId: 's', now: 101)!;
    expect(pending.label, '本句身份尚未确认，对话可以继续');
  });
}
