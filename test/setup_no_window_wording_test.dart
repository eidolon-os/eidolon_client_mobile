// What the wizard says when a Host has no open Setup window.
//
// A Host with `claim_state=unclaimed` and zero Controller grants refused a
// phone, and the wizard reported "它可能已被认领" — the opposite of the truth —
// then offered guidance about revoking grants the Host did not have. The
// endpoint document says only that no window is open (`setup_session: null`);
// it never said which. So the wizard was guessing, and guessing wrong sent the
// operator to the heaviest recovery in the product.
//
// Two properties are pinned here: the no-window text must not assert anything
// about who owns the Host, and the claimed case must still be reachable — with
// its own wording, from the Host's own `already_claimed`.

import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
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

    // A window does not open by itself, not even on a brand-new Host
    // (ADR-0006). Someone reading only this sentence must not sit waiting.
    expect(firstSetupCodeGuidance, contains('不会自己打开'));
    expect(firstSetupCodeGuidance, contains('全新'));

    // Physical presence is the authority that mints one; a phone cannot.
    expect(firstSetupCodeGuidance, contains('主机旁边'));

    // The window expires, and the way back is the same command again — the
    // question a normal user hits second.
    expect(firstSetupCodeGuidance, contains('过期'));
  });

  test('the two guidances stay separate, because they answer different questions',
      () {
    // Merging them is what produced advice about revoking grants on a Host
    // that had none.
    expect(controllerResetGuidance, isNot(equals(firstSetupCodeGuidance)));

    // The claimed-Host text still owns the reset story.
    expect(controllerResetGuidance, contains('controller-reset'));

    // And the no-window text is not a prefix or suffix of it: neither is a
    // step in the other.
    expect(controllerResetGuidance, isNot(contains(firstSetupCodeGuidance)));
    expect(firstSetupCodeGuidance, isNot(contains(controllerResetGuidance)));
  });
}
