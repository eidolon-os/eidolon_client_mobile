// Setup windows govern adding a phone, independently of existing grants.

import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_trust.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the no-window guidance never guesses at ownership', () {
    // "可能" is the tell: a message that has to hedge is a message reporting
    // something it was not told.
    expect(firstSetupCodeGuidance, isNot(contains('可能')));
    expect(firstSetupCodeGuidance, isNot(contains('认领过')));
    expect(firstSetupCodeGuidance, isNot(contains('已被认领')));

    // And it must not reach for the revoke-everything command: on a Host with
    // no grants there is nothing to revoke, which is exactly the situation
    // this text is shown in.
    expect(firstSetupCodeGuidance, isNot(contains('controller-reset')));
  });

  test('the no-window guidance names the one action that opens a window', () {
    expect(firstSetupCodeGuidance, contains('commissioning-code'));
    expect(firstSetupCodeGuidance, contains('Setup 码'));

    expect(firstSetupCodeGuidance, contains('任意已授权管理手机邀请'));
  });

  test('a null expiry reads as no expiry, never as expired', () {
    // Every window a Host opens now carries no expiry (ADR-0007). Read as
    // "expired" it would turn each of them into a refusal — the same class of
    // mistake as reading "no open window" as "already claimed".
    final open = DevelopmentSetupSession.fromJsonValue(<String, dynamic>{
      'commissioning_id': 'b0758385-f10f-406f-902c-07efe0805d47',
      'expires_at': null,
    });

    expect(open.expiresAt, isNull);
    expect(open.isOpenAt(DateTime.utc(2099, 1, 1)), isTrue);
  });

  test('a timestamp still expires, because windows written before the rule do',
      () {
    final bounded = DevelopmentSetupSession.fromJsonValue(<String, dynamic>{
      'commissioning_id': 'b0758385-f10f-406f-902c-07efe0805d47',
      'expires_at': '2026-01-01T00:10:00Z',
    });

    expect(bounded.isOpenAt(DateTime.utc(2026, 1, 1, 0, 5)), isTrue);
    expect(bounded.isOpenAt(DateTime.utc(2026, 1, 1, 0, 10)), isFalse);
  });

  test('a present but unparseable expiry is still a malformed document', () {
    // Tolerating null must not become tolerating anything.
    expect(
      () => DevelopmentSetupSession.fromJsonValue(<String, dynamic>{
        'commissioning_id': 'b0758385-f10f-406f-902c-07efe0805d47',
        'expires_at': 'not a timestamp',
      }),
      throwsA(isA<SetupTrustException>()),
    );
  });

  test(
      'the two guidances stay separate, because they answer different questions',
      () {
    // Merging them is what produced advice about revoking grants on a Host
    // that had none.
    expect(controllerRecoveryGuidance, isNot(equals(firstSetupCodeGuidance)));

    // The claimed-Host text still owns the reset story.
    expect(controllerRecoveryGuidance, contains('controller-reset'));

    // And the no-window text is not a prefix or suffix of it: neither is a
    // step in the other.
    expect(controllerRecoveryGuidance, isNot(contains(firstSetupCodeGuidance)));
    expect(firstSetupCodeGuidance, isNot(contains(controllerRecoveryGuidance)));
  });
}

// 无期限窗口：null 必须读成「不过期」，不能读成「已过期」（ADR-0007）。
