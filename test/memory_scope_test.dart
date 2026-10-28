import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/models/memory_scope.dart';

void main() {
  final payload = <String, dynamic>{
    'schema_version': 1,
    'session_id': 's',
    'sequence': 1,
    'state': 'active',
    'person_id': 'p',
    'issued_at': 100.0,
    'expires_at': 110.0
  };
  test('memory display requires current session and fresh explicit binding',
      () {
    expect(MemoryScopeView.parse(payload, sessionId: 's', now: 101)?.label,
        '本轮允许查询当前人物的个人记忆');
    expect(
        MemoryScopeView.parse(payload, sessionId: 'other', now: 101), isNull);
    expect(MemoryScopeView.parse(payload, sessionId: 's', now: 111), isNull);
    expect(
        MemoryScopeView.parse({...payload, 'person_id': null},
            sessionId: 's', now: 101),
        isNull);
    expect(
        MemoryScopeView.parse(
                {...payload, 'state': 'disabled', 'person_id': null},
                sessionId: 's', now: 101)
            ?.label,
        '本轮不使用个人记忆');
  });
}
